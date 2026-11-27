#!/usr/bin/env python3
"""本地联调构建：只生成并签名原生程序，不打包、不安装。"""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(ROOT / "Tests/ReverseAnalysis"))
from build_native import CACHE, GHIDRA, R2, environment, run

EXTENSION = ROOT / "Extensions/AgentTools/ReverseAnalysis"
OUTPUT = CACHE / "formal"


def preflight_worker():
    """本机首次执行会改写少量 Mach-O 元数据；运行后再核对连续两次稳定性。
    这只处理本地联调构建，不让协议服务静默接受运行中被改写的组件。
    """
    runtime = os.environ["APELIN_PROJECT_ROOT"] + "/build/reverse-analysis/formal"
    env = {"RA_PARENT_PID": str(os.getpid()), "R2_NOPLUGINS": "1", "HOME": "/dev/null",
           "LC_ALL": "C", "SLEIGHHOME": runtime + "/sleigh"}
    with (CACHE / "fixture-arm64").open("rb") as sample:
        # 此构建脚本没有其他 fd 4 使用者；子进程只继承只读样本。
        saved = os.dup(4) if _descriptor_open(4) else None
        os.dup2(sample.fileno(), 4)
        try:
            child = subprocess.Popen(["./build/reverse-analysis/formal/xyzl-reverse-worker", "/dev/fd/4"],
                cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                pass_fds=(4,), start_new_session=True)
            try:
                output, diagnostic = child.communicate(b"functions 0 100\n", timeout=15)
            except BaseException:
                os.killpg(child.pid, signal.SIGKILL); child.wait(); raise
        finally:
            if saved is not None:
                os.dup2(saved, 4); os.close(saved)
            elif sample.fileno() != 4:
                os.close(4)
    (OUTPUT / "preflight.stderr").write_bytes(diagnostic)
    frames = []
    while output:
        if len(output) < 4:
            raise RuntimeError("工作进程预检帧不完整")
        length = struct.unpack("!I", output[:4])[0]
        if not 0 < length <= 1048576 or len(output) < length + 4:
            raise RuntimeError("工作进程预检帧越界")
        frames.append(json.loads(output[4:4 + length])); output = output[4 + length:]
    if child.returncode or len(frames) != 2 or not all(frame.get("ok") for frame in frames):
        raise RuntimeError("真实工作进程预检失败")
    return hashlib.sha256((OUTPUT / "xyzl-reverse-worker").read_bytes()).hexdigest()


def _descriptor_open(fd):
    try:
        os.fstat(fd)
        return True
    except OSError:
        return False


def main():
    env = environment()
    OUTPUT.mkdir(parents=True, exist_ok=True)
    (OUTPUT / "tmp").mkdir(exist_ok=True)
    descriptors = (EXTENSION / "Descriptors.json").read_bytes()
    json.loads(descriptors)
    (OUTPUT / "Descriptors.inc").write_text("static const unsigned char RADescriptors[] = {" + ",".join(map(str, descriptors)) + "};\n")
    includes = ["-I" + str(OUTPUT.relative_to(ROOT)), "-I" + str((EXTENSION / "Sources").relative_to(ROOT))]
    flags = ["-arch", "arm64", "-O2", "-miphoneos-version-min=16.0", "-Wall", "-Wextra", "-Werror", "-Wno-deprecated-declarations"]
    sources = [str((EXTENSION / "Sources" / name).relative_to(ROOT)) for name in ("Analysis.m", "Server.m", "main.m")]
    run("formal-server-build", ["reverse-cc", *flags, "-fobjc-arc", "-fblocks", *includes, *sources,
        "-framework", "Foundation", "-o", str((OUTPUT / "xyzl-reverse-analysis").relative_to(ROOT))], ROOT, env, 120)
    objects = sorted({p for p in (GHIDRA / "src").glob("*.o") if not p.name.endswith("_plugin.o")} |
                     set((GHIDRA / "subprojects/ghidra-native/src/decompiler").glob("*.o")))
    if len(objects) < 40 or not (R2 / "libr/libr.a").is_file():
        raise RuntimeError("请先完成隔离试验的原生 static 构建")
    includes = ["-I" + str((R2 / "libr/include").relative_to(ROOT)), "-I" + str((R2 / "subprojects/sdb/include").relative_to(ROOT))]
    obj = OUTPUT / "worker.o"
    run("formal-worker-compile", ["reverse-cc", *flags, *includes, "-c", str((EXTENSION / "Sources/Worker.c").relative_to(ROOT)),
        "-o", str(obj.relative_to(ROOT))], ROOT, env, 60)
    inputs = [obj, *objects, GHIDRA / "subprojects/zlib/libz.a", R2 / "libr/libr.a"]
    run("formal-worker-link", ["reverse-cxx", "-arch", "arm64", "-o", str((OUTPUT / "xyzl-reverse-worker").relative_to(ROOT)),
        *[str(p.relative_to(ROOT)) for p in inputs]], ROOT, env, 120)
    sleigh = CACHE / "r2ghidra_sleigh-6.2.6-source/r2ghidra_sleigh-6.2.6"
    target = OUTPUT / "sleigh"
    target.mkdir(exist_ok=True)
    hashes = {}
    for source in sorted(sleigh.iterdir()):
        if source.name.startswith("AARCH64") or source.name == "AppleSilicon.ldefs":
            shutil.copyfile(source, target / source.name)
            hashes[source.name] = hashlib.sha256(source.read_bytes()).hexdigest()
    if len(hashes) < 8:
        raise RuntimeError("ARM64 SLEIGH 数据不完整")
    (OUTPUT / "data-sha256.json").write_text(json.dumps(hashes, sort_keys=True, indent=2) + "\n")
    first = preflight_worker()
    second = preflight_worker()
    if first != second:
        raise RuntimeError("连续执行后分析引擎仍在变化，不能固定缓存摘要")
    (OUTPUT / "preflight.json").write_text(json.dumps({"worker_sha256": second, "consecutive_runs_stable": True}, indent=2) + "\n")
    print("独立原生协议程序已构建并签名；只供本机联调，尚未生成发行包。", flush=True)


if __name__ == "__main__":
    main()
