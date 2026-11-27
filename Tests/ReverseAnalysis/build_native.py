#!/usr/bin/env python3
"""构建隔离的 iOS 原生逆向分析实验，不安装软件包。"""
import argparse
import os
from pathlib import Path
import signal
import shutil
import subprocess
import time

ROOT = Path(__file__).resolve().parents[2]
CACHE = ROOT / "build" / "reverse-analysis"
R2 = CACHE / "radare2-6.2.6-source" / "radare2-6.2.6"
GHIDRA = CACHE / "r2ghidra-6.2.6-source" / "r2ghidra-6.2.6"
TOOLS = ROOT / "Tests" / "ReverseAnalysis"


def environment():
    env = os.environ.copy()
    real_root = env.get("APELIN_PROJECT_ROOT")
    if not real_root:
        raise RuntimeError("必须在已准备工具链的项目环境中运行")
    env["APELIN_REVERSE_AR"] = shutil.which("ar") or ""
    if not env["APELIN_REVERSE_AR"]:
        raise RuntimeError("当前工具链缺少归档器 ar")
    env["PATH"] = real_root + "/Tests/ReverseAnalysis/bin:" + env["PATH"]
    env["APELIN_REVERSE_ENTITLEMENTS"] = real_root + "/Tests/ReverseAnalysis/Tool.entitlements"
    env["APELIN_REVERSE_PATCH"] = real_root + "/build/reverse-analysis/patch_ng-1.19.1-source/patch_ng-1.19.1/patch_ng.py"
    env.update({"CC": "reverse-cc", "CXX": "reverse-cxx", "HOST_CC": "reverse-cc", "HOSTCC": "reverse-cc", "CC_FOR_BUILD": "reverse-cc", "WANT_ZYDIS": "0", "CAPSTONE_ARCHS": "arm aarch64", "PYTHON": "python3"})
    env["CFLAGS"] = "-O2 -arch arm64 -miphoneos-version-min=16.0 -fPIC"
    env["CXXFLAGS"] = "-O2 -arch arm64 -miphoneos-version-min=16.0 -stdlib=libc++ -fPIC"
    env["LDFLAGS"] = "-arch arm64 -miphoneos-version-min=16.0"
    return env


def run(label, argv, cwd, env, timeout=1200):
    if not cwd.resolve().is_relative_to(ROOT.resolve()):
        raise RuntimeError("工作目录不在项目内")
    log = CACHE / (label + ".log")
    start = time.monotonic()
    with log.open("wb") as output:
        child = subprocess.Popen(argv, cwd=cwd, env=env, stdout=output, stderr=subprocess.STDOUT, start_new_session=True)
        try:
            code = child.wait(timeout=timeout)
        except BaseException:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
            raise
    elapsed = time.monotonic() - start
    print(f"{label}：退出码 {code}，用时 {elapsed:.1f} 秒；日志 {log.relative_to(ROOT)}", flush=True)
    if code:
        print(log.read_text(errors="replace")[-7000:], flush=True)
        raise RuntimeError(f"{label} 未通过")


def configure(env):
    args = ["sh", "configure", "--prefix=/usr", "--host=arm64-apple-darwin", "--target=arm64-apple-darwin", "--with-ostype=darwin", "--with-compiler=clang", "--with-libr", "--without-gpl", "--without-qjs", "--without-zydis", "--without-gperf", "--without-zip", "--disable-debugger", "--disable-network"]
    run("configure-radare2", args, R2, env, 180)
    # 只选择本实验需要的 Mach-O、ARM 和只读文件插件。
    plugins = ["bin_demangle.cxx", "bin_demangle.objc", "bin_demangle.swift", "anal.null", "anal.autoname", "arch.arm", "arch.arm_cs", "arch.null", "esil.null", "esil.dummy", "bin.null", "bin.mach0", "bin.mach064", "bp.arm", "bp.null", "core.agD", "core.pseudo", "core.prj", "debug.esil", "debug.io", "fs.posix", "fs.fatmacho", "io.default", "io.mmap", "io.malloc", "io.sparse", "asm.null"]
    (R2 / "plugins.cfg").write_text('STATIC="\n' + "\n".join(plugins) + '\n"\nSHARED=""\n')
    run("configure-plugins", ["sh", "configure-plugins"], R2, env, 60)


def engine(env, jobs):
    # 上游 macOS 规则借 xcrun 寻找归档器；本机工具链已把这些工具放入 PATH。
    for relative in ("shlr/Makefile", "libr/Makefile"):
        path = R2 / relative
        original = path.read_text()
        updated = original.replace("xcrun libtool -static", "libtool -static").replace("xcrun ranlib ", "ranlib ")
        if updated != original:
            path.write_text(updated)
    syscall_make = R2 / "libr/syscall/d/Makefile"
    original = syscall_make.read_text()
    updated = original.replace("$(SDB) -r -r $(shell pwd)", "$(SDB) -r -r .")
    if updated != original:
        syscall_make.write_text(updated)
    engine_env = env.copy()
    engine_env["LDFLAGS"] += " -Wl,-export_dynamic"
    run("build-radare2", ["make", f"-j{jobs}", "blob", "CC=reverse-cc", "HOST_CC=reverse-cc", "HOSTCC=reverse-cc", "AR=reverse-ar", "CAPSTONE_ARCHS=arm aarch64"], R2, engine_env)
    run("version-radare2", ["./binr/blob/radare2", "-v"], R2, env, 20)


def plugin(env, jobs):
    src = GHIDRA / "src"
    headers = os.path.relpath(R2 / "libr" / "include", src)
    sdb = os.path.relpath(R2 / "subprojects" / "sdb" / "include", src)
    (GHIDRA / "config.mk").write_text("CXX=reverse-cxx\nVERSION=6.2.6\nR2_USER_PLUGINS=reverse-analysis\nR2_LIBR_PLUGINS=reverse-analysis\nR2_CFLAGS=-I" + headers + " -I" + sdb + "\nR2_LDFLAGS=-Wl,-undefined,dynamic_lookup\n")
    (GHIDRA / "config.h").write_text('#ifndef R2GHIDRA_CONFIG_H\n#define R2GHIDRA_CONFIG_H 1\n#define R2GHIDRA_VERSION "6.2.6"\n#endif\n')
    plugin_env = env.copy()
    plugin_env["LDFLAGS"] += " -Wl,-install_name,@rpath/core_ghidra.dylib"
    run("build-r2ghidra", ["make", f"-j{jobs}", "R2_LIBEXT=dylib", "core_ghidra.dylib"], src, plugin_env)


def static_driver(env, jobs):
    # dylib 在本机被拒绝映射时，把同一套已构建的反编译源码静态链入独立工具。
    run("archive-radare2", ["make", "-C", "libr", "libr.a", "AR=reverse-ar"], R2, env, 120)
    src = GHIDRA / "src"
    includes = ["-I" + os.path.relpath(R2 / "libr/include", src), "-I" + os.path.relpath(R2 / "subprojects/sdb/include", src)]
    for name in ("core", "anal"):
        run("static-" + name + "-plugin", ["reverse-cc", "-O2", "-arch", "arm64", "-DR2_PLUGIN_INCORE=1", *includes, "-c", name + "_ghidra_plugin.c", "-o", name + "_ghidra_static.o"], src, env, 60)
    objects = [p for p in src.glob("*.o") if not p.name.endswith("_plugin.o")]
    objects += list((GHIDRA / "subprojects/ghidra-native/src/decompiler").glob("*.o"))
    objects = sorted(set(objects))
    if len(objects) < 40:
        raise RuntimeError("Ghidra 原生对象不完整，请先构建插件")
    driver = CACHE / "driver.o"
    includes = ["-I" + os.path.relpath(R2 / "libr/include", ROOT), "-I" + os.path.relpath(R2 / "subprojects/sdb/include", ROOT)]
    run("compile-driver", ["reverse-cc", "-arch", "arm64", "-O2", *includes, "-c", "Tests/ReverseAnalysis/driver.c", "-o", str(driver.relative_to(ROOT))], ROOT, env, 60)
    inputs = [driver, *objects, GHIDRA / "subprojects/zlib/libz.a", R2 / "libr/libr.a"]
    run("link-static-driver", ["reverse-cxx", "-arch", "arm64", "-miphoneos-version-min=16.0", "-o", "build/reverse-analysis/reverse-native", *[str(p.relative_to(ROOT)) for p in inputs]], ROOT, env, 120)


def session_driver(env):
    src = GHIDRA / "src"
    objects = sorted({p for p in src.glob("*.o") if not p.name.endswith("_plugin.o")} |
                     set((GHIDRA / "subprojects/ghidra-native/src/decompiler").glob("*.o")))
    if len(objects) < 40 or not (R2 / "libr/libr.a").is_file():
        raise RuntimeError("请先完成 static 阶段")
    includes = ["-I" + os.path.relpath(R2 / "libr/include", ROOT),
                "-I" + os.path.relpath(R2 / "subprojects/sdb/include", ROOT)]
    obj = CACHE / "session-driver.o"
    run("compile-session-driver", ["reverse-cc", "-arch", "arm64", "-O2", "-Wall", "-Wextra",
        *includes, "-c", "Tests/ReverseAnalysis/session_driver.c", "-o", str(obj.relative_to(ROOT))], ROOT, env, 60)
    inputs = [obj, *objects, GHIDRA / "subprojects/zlib/libz.a", R2 / "libr/libr.a"]
    run("link-session-driver", ["reverse-cxx", "-arch", "arm64", "-o",
        "build/reverse-analysis/reverse-session-native", *[str(p.relative_to(ROOT)) for p in inputs]], ROOT, env, 120)


def fixture(env):
    for arch in ("arm64", "arm64e"):
        output = "build/reverse-analysis/fixture-" + arch
        run("build-fixture-" + arch, ["reverse-cc", "-arch", arch, "-miphoneos-version-min=16.0", "-O1", "-fno-optimize-sibling-calls", "Tests/ReverseAnalysis/fixture.c", "-o", output], ROOT, env, 60)
        run("run-fixture-" + arch, ["./" + output], ROOT, env, 20)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("stage", choices=["configure", "engine", "plugin", "static", "session", "fixture", "all"])
    parser.add_argument("--jobs", type=int, default=2, choices=range(1, 5))
    args = parser.parse_args()
    if not R2.is_dir() or not GHIDRA.is_dir():
        raise RuntimeError("请先运行 fetch_sources.py")
    for wrapper in (TOOLS / "bin").iterdir():
        wrapper.chmod(0o755)
    env = environment()
    for name, action in [("configure", lambda: configure(env)), ("engine", lambda: engine(env, args.jobs)), ("plugin", lambda: plugin(env, args.jobs)), ("static", lambda: static_driver(env, args.jobs)), ("session", lambda: session_driver(env)), ("fixture", lambda: fixture(env))]:
        if args.stage in (name, "all"):
            action()


if __name__ == "__main__":
    main()
