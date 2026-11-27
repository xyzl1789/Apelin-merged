#!/usr/bin/env python3
"""对自有样本验收原生函数分析、Ghidra 反编译和进程生命周期。"""
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import threading
import time

from build_native import CACHE, ROOT, environment

DRIVER = CACHE / "reverse-native"
RESULTS = CACHE / "results"
NAMES = ("fixture_value", "fixture_branch", "fixture_caller")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def guarded(label, argv, env, timeout=30, cancel=None):
    """对真实原生进程设置时限，取消时终止并回收整个进程组。"""
    output_path = RESULTS / (label + ".out")
    error_path = RESULTS / (label + ".stderr")
    started = time.monotonic()
    status = "finished"
    with output_path.open("wb") as output, error_path.open("wb") as errors:
        child = subprocess.Popen(argv, cwd=ROOT, env=env, stdout=output,
                                 stderr=errors, start_new_session=True)
        try:
            while child.poll() is None:
                if cancel is not None and cancel.is_set():
                    status = "cancelled"
                    break
                if time.monotonic() - started >= timeout:
                    status = "timeout"
                    break
                time.sleep(0.01)
        finally:
            if child.poll() is None:
                try:
                    os.killpg(child.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            child.wait()
    try:
        os.killpg(child.pid, 0)
        group_gone = False
    except ProcessLookupError:
        group_gone = True
    result = {"status": status, "returncode": child.returncode,
              "seconds": round(time.monotonic() - started, 4),
              "process_group_gone": group_gone,
              "stdout": output_path.read_text(errors="replace"),
              "stderr": error_path.read_text(errors="replace")}
    return result


def query(label, sample, command, env):
    result = guarded(label, ["./" + str(DRIVER.relative_to(ROOT)),
                            str(sample.relative_to(ROOT)), command], env)
    require(result["status"] == "finished" and result["returncode"] == 0,
            label + " 运行失败：" + result["stderr"][-1000:])
    require(result["process_group_gone"], label + " 存在未回收进程")
    try:
        data = json.loads(result["stdout"])
    except ValueError as error:
        raise AssertionError(label + " 没有返回有效 JSON") from error
    return data, result["seconds"]


def check_arch(arch, env):
    sample = CACHE / ("fixture-" + arch)
    functions, duration = query(arch + "-functions", sample, "aflj", env)
    named = {item["name"]: item for item in functions}
    expected_names = {"sym._" + name for name in NAMES}
    require(expected_names <= named.keys(), arch + " 缺少已知函数")
    branch, graph_time = query(arch + "-cfg", sample, "agfj @ sym._fixture_branch", env)
    blocks = branch[0]["blocks"]
    addresses = {block["addr"] for block in blocks}
    edges = [(block["addr"], block[k]) for block in blocks for k in ("jump", "fail") if k in block]
    require(len(blocks) >= 4, arch + " 未识别条件基本块")
    require(any("jump" in block and "fail" in block for block in blocks), arch + " 缺少条件分支")
    require(all(target in addresses for _, target in edges), arch + " CFG 边指向未知基本块")
    incoming, _ = query(arch + "-incoming", sample, "axtj @ sym._fixture_value", env)
    callers = {ref.get("fcn_name") for ref in incoming if ref["type"] == "CALL"}
    require({"main", "sym._fixture_caller", "sym._fixture_branch"} <= callers, arch + " 入向调用不完整")
    outgoing, _ = query(arch + "-outgoing", sample, "axffj @ sym._fixture_caller", env)
    callees = {ref["ref"] for ref in outgoing if ref["type"] == "CALL"}
    require(callees == {named["sym._fixture_value"]["addr"], named["sym._fixture_branch"]["addr"]}, arch + " 出向调用不匹配")
    code = []
    decompile_times = []
    for name in NAMES:
        data, elapsed = query(arch + "-decompile-" + name, sample, "pdgj @ sym._" + name, env)
        text = data.get("code", "")
        require("return" in text and "{" in text, arch + " 缺少 C 伪代码")
        require(data.get("annotations") and data.get("pcode_ops"), arch + " 缺少 Ghidra 注解或 P-code")
        require("goto 0x" not in text and "__asm" not in text, arch + " 结果退化为汇编包装")
        if name == "fixture_value":
            require(re.search(r"\*\s*3\s*\+\s*7", text) is not None, arch + " 算术语义不符")
        if name == "fixture_branch":
            require(text.count("if (") >= 2, arch + " 未恢复两层条件分支")
        code.append(text)
        decompile_times.append(elapsed)
    pseudocode_path = RESULTS / (arch + "-pseudocode.c")
    # 只规范化符号中的点号，保留反编译器推断的类型、表达式和控制流。
    pseudocode_path.write_text("#include <stdint.h>\n" + "\n".join(code).replace("sym._", ""))
    return {"arch": arch, "function_count": len(functions),
            "known_functions": sorted(expected_names), "blocks": len(blocks),
            "edges": len(edges), "incoming_callers": sorted(callers),
            "outgoing_call_count": len(callees), "functions_seconds": duration,
            "cfg_seconds": graph_time, "decompile_seconds": decompile_times,
            "pseudocode": str(pseudocode_path.relative_to(ROOT))}


def compile_roundtrip(arch, env):
    output = "build/reverse-analysis/results/roundtrip-" + arch
    result = guarded(arch + "-roundtrip-build", ["reverse-cc", "-arch", arch, "-O1", "-fwrapv",
        "build/reverse-analysis/results/" + arch + "-pseudocode.c",
        "Tests/ReverseAnalysis/roundtrip.c", "-o", output], env, timeout=60)
    require(result["returncode"] == 0, arch + " 伪代码回编译失败：" + result["stderr"][-1500:])
    result = guarded(arch + "-roundtrip-run", ["./" + output], env)
    require(result["returncode"] == 0, arch + " 伪代码运行与已知逻辑不符")
    return json.loads(result["stdout"])


def main():
    RESULTS.mkdir(parents=True, exist_ok=True)
    (CACHE / "home").mkdir(exist_ok=True)
    env = environment()
    root = env["APELIN_PROJECT_ROOT"]
    env.update({"R2_NOPLUGINS": "1", "HOME": root + "/build/reverse-analysis/home",
                "SLEIGHHOME": root + "/build/reverse-analysis/r2ghidra_sleigh-6.2.6-source/r2ghidra_sleigh-6.2.6"})
    inputs = [ROOT / "Tests/ReverseAnalysis/fixture.c", CACHE / "fixture-arm64", CACHE / "fixture-arm64e"]
    before = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    report = {"engine_sha256": digest(DRIVER), "inputs_before": before,
              "architectures": [], "lifecycle": {}}
    for arch in ("arm64", "arm64e"):
        result = check_arch(arch, env)
        result["roundtrip"] = compile_roundtrip(arch, env)
        report["architectures"].append(result)
        print(arch + "：函数、CFG、双向调用与真 C 反编译通过，伪代码回编译对照通过", flush=True)
    # 重复真实 Ghidra 工作直到测试终止，不依靠外部 sleep 或假工作进程。
    argv = ["./" + str(DRIVER.relative_to(ROOT)), "build/reverse-analysis/fixture-arm64", "100000pdgj @ sym._fixture_branch"]
    timeout = guarded("lifecycle-timeout", argv, env, timeout=0.5)
    require(timeout["status"] == "timeout" and timeout["process_group_gone"], "超时没有终止并回收原生进程组")
    event = threading.Event()
    timer = threading.Timer(0.5, event.set)
    timer.start()
    try:
        cancel = guarded("lifecycle-cancel", argv, env, cancel=event)
    finally:
        timer.cancel()
        timer.join()
    require(cancel["status"] == "cancelled" and cancel["process_group_gone"], "取消没有终止并回收原生进程组")
    for name, result in (("timeout", timeout), ("cancel", cancel)):
        require(result["seconds"] < 2, name + " 回收时间超限")
        report["lifecycle"][name] = {k: result[k] for k in ("status", "returncode", "seconds", "process_group_gone")}
    after = {str(path.relative_to(ROOT)): digest(path) for path in inputs}
    require(before == after, "输入文件在分析过程中被修改")
    report["inputs_after"] = after
    report["input_unchanged"] = True
    report["passed"] = True
    (RESULTS / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("超时、主动取消、进程回收和输入 SHA-256 不变全部通过", flush=True)


if __name__ == "__main__":
    main()
