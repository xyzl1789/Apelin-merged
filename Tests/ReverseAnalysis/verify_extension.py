#!/usr/bin/env python3
"""用真实 JSONL 与 SCM_RIGHTS 验收原生扩展，不安装、不调用主应用。"""
import array
import hashlib
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "Tests/ReverseAnalysis"))
from build_native import CACHE, environment
from verify_native import guarded, require

EXTENSION = ROOT / "Extensions/AgentTools/ReverseAnalysis"
RUNTIME = Path(os.environ.get("RA_RUNTIME", str(CACHE / "formal"))).resolve()
if not RUNTIME.is_relative_to(ROOT):
    raise RuntimeError("测试运行目录必须位于项目内")
(RUNTIME / "tmp").mkdir(exist_ok=True)
RESULTS = CACHE / "results"
NATIVE_ROOT = os.environ["APELIN_PROJECT_ROOT"]
ALL_PIDS = set()


def native(path):
    return NATIVE_ROOT + "/" + str(path.relative_to(ROOT))


def gone(pid):
    try:
        os.killpg(pid, 0)
        return False
    except ProcessLookupError:
        return True
    except PermissionError:
        # Darwin 回收进程组的瞬间可能返回 EPERM；仍视为存活，继续等到 ESRCH。
        return False


def wait_until(predicate, seconds=3):
    deadline = time.monotonic() + seconds
    while not predicate():
        require(time.monotonic() < deadline, "等待条件超时")
        time.sleep(0.005)


class Client:
    def __init__(self, idle=60, frame_limit=1048576, negotiate=True, runtime=RUNTIME):
        self.socket, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_DGRAM)
        env = os.environ.copy()
        env.update({"TMPDIR": native(RUNTIME / "tmp"), "APELIN_TOOL_ATTACHMENT_FD": "3"})
        self.stderr = bytearray()
        self.buffer = bytearray()
        self.counter = 0
        self.closed = False
        self.proc = subprocess.Popen(["./" + str((runtime / "xyzl-reverse-analysis").relative_to(ROOT)), "--idle-seconds", str(idle)],
            cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
            pass_fds=tuple({3, child.fileno()}), preexec_fn=lambda: os.dup2(child.fileno(), 3), start_new_session=True)
        child.close()
        self.thread = threading.Thread(target=self.read_diagnostics, daemon=True)
        self.thread.start()
        if negotiate:
            self.send({"type": "hello", "requestID": "hello", "supportedVersions": [1], "maxFrameBytes": frame_limit})
            hello = self.receive()
            require(hello["type"] == "hello" and hello["maxConcurrentCalls"] == 1, "正式握手失败：" + str(hello))
            self.hello = hello

    def read_diagnostics(self):
        while True:
            data = self.proc.stderr.read(8192)
            if not data:
                return
            self.stderr.extend(data)

    @property
    def pids(self):
        return set(map(int, re.findall(rb"pid=(\d+)", self.stderr)))

    def send(self, value):
        frame = {"protocolVersion": 1, **value}
        data = json.dumps(frame, ensure_ascii=False).encode() + b"\n"
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def receive(self, timeout=10):
        deadline = time.monotonic() + timeout
        while b"\n" not in self.buffer:
            left = deadline - time.monotonic()
            require(left > 0 and select.select([self.proc.stdout], [], [], max(0, left))[0], "原生扩展响应超时")
            data = os.read(self.proc.stdout.fileno(), 8192)
            require(data, "扩展意外退出：" + self.stderr.decode(errors="replace")[-3000:])
            self.buffer.extend(data)
        line, _, remaining = self.buffer.partition(b"\n")
        self.buffer = bytearray(remaining)
        value = json.loads(line)
        require(value.get("protocolVersion") == 1, "响应版本错误")
        return value

    def start(self, tool="analyze_functions", arch="arm64", attachments=None, **extra):
        self.counter += 1
        identifier = "c" + str(self.counter)
        fixture_arch = arch if arch in ("arm64", "arm64e") else "arm64"
        args = {"binary": native(CACHE / ("fixture-" + fixture_arch)), "arch": arch, **extra}
        frame = {"type": "call", "requestID": identifier, "tool": tool, "args": args}
        if attachments is not None:
            frame["attachments"] = attachments
        self.send(frame)
        return identifier

    def call(self, tool="analyze_functions", arch="arm64", **extra):
        identifier = self.start(tool, arch, **extra)
        response = self.receive()
        require(response.get("requestID") == identifier and response["type"] == "result", "调用失败：" + str(response))
        return json.loads(response["content"][0]["text"])

    def reject(self, code, tool="analyze_functions", **extra):
        identifier = self.start(tool, **extra)
        response = self.receive()
        require(response.get("requestID") == identifier and response.get("error", {}).get("code") == code, "错误分类不符：" + str(response))
        return response

    def attach(self, identifier, descriptors):
        self.socket.sendmsg([identifier.encode()], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", descriptors))])

    def close(self, abrupt=False):
        if self.closed:
            return
        self.closed = True
        if abrupt:
            self.proc.kill()
        else:
            self.proc.stdin.close()
        try:
            self.proc.wait(timeout=4)
        except subprocess.TimeoutExpired:
            self.proc.kill()
            self.proc.wait()
            raise AssertionError("宿主退出后扩展未及时停止")
        self.thread.join(timeout=1)
        self.socket.close()
        ALL_PIDS.update(self.pids)
        wait_until(lambda: all(gone(pid) for pid in self.pids))
        require(not list((RUNTIME / "tmp").iterdir()), "快照未清理")

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def features():
    descriptor = guarded("formal-describe", ["./" + str((RUNTIME / "xyzl-reverse-analysis").relative_to(ROOT)), "--describe"], environment())
    require(descriptor["returncode"] == 0, "--describe 执行失败")
    require(json.loads(descriptor["stdout"]) == json.loads((EXTENSION / "Descriptors.json").read_text()), "描述符与编译产物漂移")
    reports = []
    with Client() as client:
        for arch in ("arm64", "arm64e"):
            first = client.call(arch=arch)
            warm = client.call(arch=arch)
            pid = first["meta"]["pid"]
            require(not first["meta"]["cache_hit"] and warm["meta"]["cache_hit"] and warm["meta"]["pid"] == pid, "未复用会话")
            functions = first["data"]["functions"]
            named = {item["name"]: item["address"] for item in functions}
            pages, offset = [], 0
            while offset is not None:
                page = client.call(arch=arch, offset=offset, limit=2)["data"]
                pages.extend(page["functions"])
                offset = page["next_offset"]
            require(pages == functions, "分页重复或缺项")
            graph = client.call("analyze_cfg", arch, address=named["sym._fixture_branch"])["data"]
            blocks = graph[0]["blocks"]
            addresses = {item["addr"] for item in blocks}
            edges = [(item["addr"], item[key]) for item in blocks for key in ("jump", "fail") if key in item]
            require(len(blocks) == 6 and len(edges) == 7 and all(target in addresses for _, target in edges), "CFG 不符")
            incoming = client.call("analyze_references", arch, address=named["sym._fixture_value"], direction="in")["data"]
            outgoing = client.call("analyze_references", arch, address=named["sym._fixture_caller"], direction="out")["data"]
            require({item["fcn_name"] for item in incoming if item["type"] == "CALL"} == {"main", "sym._fixture_branch", "sym._fixture_caller"}, "入向调用不符")
            require({item["ref"] for item in outgoing if item["type"] == "CALL"} == {named["sym._fixture_value"], named["sym._fixture_branch"]}, "出向调用不符")
            code = []
            for name in ("fixture_value", "fixture_branch", "fixture_caller"):
                result = client.call("decompile_function", arch, address=named["sym._" + name])
                require(result["meta"]["pid"] == pid and result["data"].get("annotations") and result["data"].get("pcode_ops"), "伪代码缺少原生证据或未复用会话")
                code.append(result["data"]["code"])
            source = RESULTS / ("formal-" + arch + "-pseudocode.c")
            source.write_text("#include <stdint.h>\n" + "\n".join(code).replace("sym._", ""))
            output = "build/reverse-analysis/results/formal-roundtrip-" + arch
            built = guarded("formal-" + arch + "-roundtrip-build", ["reverse-cc", "-arch", arch, "-O1", "-fwrapv", str(source.relative_to(ROOT)), "Tests/ReverseAnalysis/roundtrip.c", "-o", output], environment(), timeout=60)
            require(built["returncode"] == 0, "正式协议伪代码回编译失败")
            ran = guarded("formal-" + arch + "-roundtrip-run", ["./" + output], environment())
            require(ran["returncode"] == 0, "正式协议伪代码语义不符")
            reports.append({"arch": arch, "functions": len(functions), "blocks": 6, "edges": 7, "incoming_callers": 3, "outgoing_calls": 2, "same_pid": True, "roundtrip": json.loads(ran["stdout"])})
    return reports


def boundaries():
    count = 0
    with Client(negotiate=False) as client:
        client.reject("notNegotiated")
        client.send({"type": "hello", "requestID": "bad-version", "supportedVersions": [2, 3]})
        require(client.receive()["error"]["code"] == "protocolVersionMismatch", "版本拒绝不符")
        client.send({"type": "hello", "requestID": "ok", "supportedVersions": [2, 1]})
        require(client.receive()["type"] == "hello", "最高共同版本协商失败")
        client.send({"type": "hello", "requestID": "again"})
        require(client.receive()["error"]["code"] == "badFrame", "重复握手未拒绝")
        cases = [("unknownTool", "unknown", {}), ("invalidArguments", "analyze_functions", {"command": "!id"}),
            ("invalidArguments", "analyze_functions", {"limit": True}), ("invalidArguments", "analyze_functions", {"limit": 501}),
            ("invalidArguments", "analyze_functions", {"offset": -1}), ("invalidArguments", "analyze_functions", {"arch": None}),
            ("invalidArguments", "analyze_functions", {"timeout_seconds": True}), ("invalidArguments", "analyze_functions", {"timeout_seconds": 61}),
            ("invalidArguments", "analyze_functions", {"binary": "relative"}), ("invalidArguments", "analyze_functions", {"binary": "/no/such/file"}),
            ("invalidArguments", "analyze_functions", {"binary": "x\x00y"}), ("invalidArguments", "analyze_cfg", {"address": "0x1;!id"}),
            ("invalidArguments", "analyze_cfg", {"address": "sym._main"}), ("invalidArguments", "analyze_cfg", {"address": "0x10000000000000000"}),
            ("invalidArguments", "analyze_cfg", {"address": "0x1"}), ("invalidArguments", "analyze_references", {"address": "0x1", "direction": "both"})]
        for code, tool, args in cases:
            client.reject(code, tool, **args)
            count += 1
        # 以下为真实输入副本，提前拒绝不能依靠引擎碰巧崩溃。
        with tempfile.TemporaryDirectory(prefix="formal-invalid-", dir=CACHE) as folder:
            folder = Path(folder)
            junk = folder / "junk"; junk.write_bytes(b"not-a-macho" * 10)
            client.reject("invalidArguments", binary=native(junk))
            malformed = folder / "malformed"; data = bytearray((CACHE / "fixture-arm64").read_bytes())
            struct.pack_into("<I", data, 20, 0xffffffff); malformed.write_bytes(data)
            client.reject("invalidArguments", binary=native(malformed))
            oversized = folder / "oversized"
            with oversized.open("wb") as stream:
                stream.truncate(32 * 1024 * 1024 + 1)
            client.reject("invalidArguments", binary=native(oversized))
            client.reject("invalidArguments", binary=native(CACHE / "fixture-arm64e"))
            count += 4
        client.proc.stdin.write(b"x" * (1048576 + 1) + b"\n"); client.proc.stdin.flush()
        require(client.receive()["error"]["code"] == "frameTooLarge", "超长帧未拒绝")
        client.proc.stdin.write(b"not-json\n"); client.proc.stdin.flush()
        require(client.receive()["error"]["code"] == "badFrame", "无效 JSON 未隔离")
        client.send({"type": "call", "protocolVersion": 2, "requestID": "wrong"})
        require(client.receive()["error"]["code"] == "protocolVersionMismatch", "后续帧版本不符未拒绝")
        client.call()
    return {"argument_rejections": count, "version_negotiation": True, "oversized_frame": True, "bad_json_recovery": True}


def attachments():
    with Client() as client:
        with (CACHE / "fixture-arm64").open("rb") as source:
            client.attach("binary-1", [source.fileno()])
            identifier = client.start(binary="descriptor-only", attachments=[{"id": "binary-1", "argument": "binary", "byteCount": os.fstat(source.fileno()).st_size}])
            response = client.receive()
            require(response["type"] == "result" and response["requestID"] == identifier, "SCM_RIGHTS 附件未替代路径")
            client.attach("bad-size", [source.fileno()])
            client.reject("attachmentRejected", attachments=[{"id": "bad-size", "argument": "binary", "byteCount": 1}])
            client.attach("two-fds", [source.fileno(), source.fileno()])
            client.reject("attachmentRejected", attachments=[{"id": "two-fds", "argument": "binary"}])
        client.reject("attachmentRejected", attachments=[{"id": "missing", "argument": "binary"}])
        client.reject("attachmentRejected", attachments=[{"id": "not-bound", "argument": "other"}])
        client.reject("attachmentRejected", attachments=[{"id": "many" + str(i), "argument": "binary"} for i in range(9)])
    return {"scm_rights_binary": True, "size_mismatch": True, "multiple_descriptors": True, "missing_descriptor": True, "argument_binding": True, "reference_limit": True}


def lifecycle(folder):
    with Client(idle=1) as client:
        first = client.call(); pid = first["meta"]["pid"]
        wait_until(lambda: gone(pid), seconds=3)
        rebuilt = client.call()
        require(rebuilt["meta"]["pid"] != pid and not rebuilt["meta"]["cache_hit"], "后台空闲回收没有重建会话")
        dead = rebuilt["meta"]["pid"]; os.kill(dead, signal.SIGKILL)
        time.sleep(0.05)
        recovered = client.call()
        require(recovered["meta"]["pid"] != dead and gone(dead), "死亡工作进程未重建")
        changed = folder / "changed"
        shutil.copyfile(CACHE / "fixture-arm64", changed)
        old = client.call(binary=native(changed))
        metadata = changed.stat(); data = bytearray(changed.read_bytes()); data[-1] ^= 1; changed.write_bytes(data)
        os.utime(changed, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        new = client.call(binary=native(changed))
        require(old["meta"]["sha256"] != new["meta"]["sha256"] and not new["meta"]["cache_hit"], "同大小同 mtime 内容变化未失效")
        client.call(arch="arm64e")
        require(gone(old["meta"]["pid"]), "LRU 淘汰未回收进程组")
    with Client(frame_limit=512) as client:
        client.reject("resultTooLarge")
        wait_until(lambda: bool(client.pids) and all(gone(pid) for pid in client.pids))
    with Client() as client:
        identifier = client.start(attachments=[{"id": "await-cancel", "argument": "binary"}])
        client.send({"type": "call", "requestID": identifier, "tool": "analyze_functions", "args": {"binary": "unused", "arch": "arm64"}})
        require(client.receive()["error"]["code"] == "duplicateRequest", "重复请求未拒绝")
        client.send({"type": "call", "requestID": "busy", "tool": "analyze_functions", "args": {"binary": "unused", "arch": "arm64"}})
        require(client.receive()["error"]["code"] == "busy", "并发超限未拒绝")
        start = time.monotonic(); client.send({"type": "cancel", "requestID": identifier})
        require(client.receive()["error"]["code"] == "cancelled" and time.monotonic() - start < 2, "附件等待取消未在宽限内结束")
        client.reject("timeout", timeout_seconds=0.001)
        before_pids = set(client.pids)
        identifier = client.start()
        wait_until(lambda: bool(client.pids - before_pids))
        client.send({"type": "cancel", "requestID": identifier})
        require(client.receive().get("error", {}).get("code") == "cancelled", "初始化期间取消失败")
        wait_until(lambda: all(gone(pid) for pid in client.pids - before_pids))
        first = client.call()
        branch = next(item["address"] for item in first["data"]["functions"] if item["name"] == "sym._fixture_branch")
        before = len(client.stderr); identifier = client.start("decompile_function", address=branch)
        marker = "逆向反编译开始".encode()
        wait_until(lambda: marker in client.stderr[before:])
        start = time.monotonic(); client.send({"type": "cancel", "requestID": identifier})
        response = client.receive()
        require(response.get("error", {}).get("code") == "cancelled" and time.monotonic() - start < 2, "真实反编译期间取消失败：" + str(response))
        wait_until(lambda: gone(first["meta"]["pid"]))
        warmed = client.call()
        before = len(client.stderr)
        client.start("decompile_function", address=branch, timeout_seconds=0.02)
        response = client.receive()
        require(response.get("error", {}).get("code") == "timeout" and marker in client.stderr[before:], "真实反编译期间超时未被验证：" + str(response))
        wait_until(lambda: gone(warmed["meta"]["pid"]))
        client.call()
    with Client() as client:
        client.start(); wait_until(lambda: bool(client.pids))
    with Client() as client:
        first = client.call()
        branch = next(item["address"] for item in first["data"]["functions"] if item["name"] == "sym._fixture_branch")
        before = len(client.stderr); client.start("decompile_function", address=branch)
        wait_until(lambda: "逆向反编译开始".encode() in client.stderr[before:]); client.close(abrupt=True)
    return {"background_idle_reaping": True, "dead_worker_recovery": True, "same_size_mtime_invalidation": True, "lru_reaping": True,
        "negotiated_output_limit": True, "duplicate_request": True, "busy": True, "attachment_wait_cancel": True, "initialization_timeout": True,
        "initialization_cancel": True, "live_decompile_cancel": True, "live_decompile_timeout": True,
        "stdin_eof_cleanup": True, "extension_sigkill_parent_watch": True}


def component_faults(folder):
    runtime = folder / "fault-runtime"
    shutil.copytree(RUNTIME, runtime, ignore=shutil.ignore_patterns("tmp"))
    with Client(runtime=runtime) as client:
        first = client.call()
        with (runtime / "xyzl-reverse-worker").open("ab") as engine:
            engine.write(b"changed-engine")
        rejected = client.reject("toolFailed", arch="arm64e")
        require("分析引擎已变化" in rejected["error"]["message"], "新建进程没有拒绝引擎变化")
        require(not gone(first["meta"]["pid"]), "引擎拒绝测试没有保留对照会话")
    shutil.copyfile(RUNTIME / "xyzl-reverse-worker", runtime / "xyzl-reverse-worker")
    with Client(runtime=runtime) as client:
        client.call()
        index = runtime / "data-sha256.json"
        index.write_bytes(index.read_bytes() + b"\n")
        rejected = client.reject("toolFailed", arch="arm64e")
        require("语言数据清单已变化" in rejected["error"]["message"], "新建进程没有拒绝数据清单变化")
    shutil.copyfile(RUNTIME / "data-sha256.json", runtime / "data-sha256.json")
    for mode, message in ((1, "分析诊断超出限额"), (2, "分析响应超出限额")):
        built = guarded("formal-fault-" + str(mode), ["reverse-cc", "-arch", "arm64", "-O1", "-DFAULT_MODE=" + str(mode),
            "Tests/ReverseAnalysis/extension_fault_worker.c", "-o", str((runtime / "xyzl-reverse-worker").relative_to(ROOT))], environment(), timeout=60)
        require(built["returncode"] == 0, "故障注入程序编译失败")
        with Client(runtime=runtime) as client:
            rejected = client.reject("resultTooLarge")
            require(message in rejected["error"]["message"], "故障输出未被正确识别：" + str(rejected))
            wait_until(lambda: bool(client.pids) and all(gone(pid) for pid in client.pids))
    return {"engine_change_rejected": True, "data_index_change_rejected": True,
            "diagnostic_limit_reaped": True, "internal_frame_limit_reaped": True}


def main():
    paths = [CACHE / "fixture-arm64", CACHE / "fixture-arm64e", ROOT / "Tests/ReverseAnalysis/fixture.c"]
    original = {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}
    report = {"features": features(), "boundaries": boundaries(), "attachments": attachments()}
    with tempfile.TemporaryDirectory(prefix="formal-check-", dir=CACHE) as folder:
        report["lifecycle"] = lifecycle(Path(folder))
        report["component_faults"] = component_faults(Path(folder))
    require(original == {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}, "输入文件发生变化")
    require(all(gone(pid) for pid in ALL_PIDS), "仍有残留工作进程组")
    report.update({"input_unchanged": True, "all_process_groups_reaped": True, "worker_groups_checked": len(ALL_PIDS),
        "scope": "真实原生扩展与协议测试宿主；未执行 Swift ToolHostClient、未安装或发现扩展",
        "runtime": str(RUNTIME.relative_to(ROOT))})
    report_name = os.environ.get("RA_REPORT_NAME", "formal-extension-report.json")
    require(Path(report_name).name == report_name and report_name.endswith(".json"), "测试报告名非法")
    (RESULTS / report_name).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
