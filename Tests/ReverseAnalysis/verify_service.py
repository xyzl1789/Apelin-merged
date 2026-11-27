#!/usr/bin/env python3
"""在真实原生引擎上验收固定接口、缓存、回编译与异常清理。"""
import json
import os
from pathlib import Path
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import threading
import time
from unittest.mock import patch

from analysis_service import AnalysisService, AnalysisError, Worker, DRIVER, MAX_FILE, sha256
from build_native import CACHE, ROOT, environment
from verify_native import guarded, require

RESULTS = CACHE / "results"
ALL_PIDS = []


def gone(pid):
    try:
        os.killpg(pid, 0)
        return False
    except ProcessLookupError:
        return True


def request(arch="arm64", op="functions", **extra):
    return {"op": op, "path": "build/reverse-analysis/fixture-" + arch, "arch": arch, **extra}


def ok(service, value, **options):
    response = service.call(value, **options)
    require(response["ok"], "请求失败：" + str(response))
    return response


def rejected(service, value, code, **options):
    response = service.call(value, **options)
    require(not response["ok"] and response["error"]["code"] == code,
            "错误分类不符：" + str(response) + "，应为 " + code)
    return response


def remember(service):
    ALL_PIDS.extend(service.started_pids)
    require(all(gone(pid) for pid in service.started_pids), "会话关闭后有残留进程组")
    require(not service.folder.exists(), "宿主关闭后临时快照未清理")


def features():
    reports = []
    service = AnalysisService()
    try:
        for arch in ("arm64", "arm64e"):
            first = ok(service, request(arch))
            warm = ok(service, request(arch))
            pid = first["meta"]["pid"]
            require(not first["meta"]["cache_hit"] and warm["meta"]["cache_hit"], "缓存命中不符")
            require(pid == warm["meta"]["pid"] and warm["meta"]["analysis_runs"] == 1, "没有复用同一分析状态")
            functions = first["data"]["functions"]
            named = {item["name"]: item["address"] for item in functions}
            pages = []
            offset = 0
            while offset is not None:
                page = ok(service, request(arch, offset=offset, limit=2))["data"]
                pages.extend(page["functions"])
                offset = page["next_offset"]
            require(pages == functions, "函数分页重复或遗漏")
            branch = named["sym._fixture_branch"]
            graph = ok(service, request(arch, "cfg", address=branch))
            blocks = graph["data"][0]["blocks"]
            addresses = {item["addr"] for item in blocks}
            edges = [(item["addr"], item[field]) for item in blocks for field in ("jump", "fail") if field in item]
            require(len(blocks) == 6 and len(edges) == 7 and all(target in addresses for _, target in edges), "CFG 不符")
            incoming = ok(service, request(arch, "refs", address=named["sym._fixture_value"], direction="in"))["data"]
            outgoing = ok(service, request(arch, "refs", address=named["sym._fixture_caller"], direction="out"))["data"]
            callers = {item["fcn_name"] for item in incoming if item["type"] == "CALL"}
            callees = {item["ref"] for item in outgoing if item["type"] == "CALL"}
            require(callers == {"main", "sym._fixture_branch", "sym._fixture_caller"}, "入向引用不符")
            require(callees == {named["sym._fixture_branch"], named["sym._fixture_value"]}, "出向引用不符")
            code = []
            decompile_times = []
            for name in ("fixture_value", "fixture_branch", "fixture_caller"):
                result = ok(service, request(arch, "decompile", address=named["sym._" + name]))
                require(result["meta"]["pid"] == pid, "四项操作没有共用同一会话")
                require(result["data"].get("annotations") and result["data"].get("pcode_ops"), "缺少真实反编译注解")
                code.append(result["data"]["code"])
                decompile_times.append(result["meta"]["elapsed_ms"])
            source = RESULTS / ("session-" + arch + "-pseudocode.c")
            source.write_text("#include <stdint.h>\n" + "\n".join(code).replace("sym._", ""))
            output = "build/reverse-analysis/results/session-roundtrip-" + arch
            built = guarded("session-" + arch + "-roundtrip-build", ["reverse-cc", "-arch", arch, "-O1", "-fwrapv",
                str(source.relative_to(ROOT)), "Tests/ReverseAnalysis/roundtrip.c", "-o", output], environment(), timeout=60)
            require(built["returncode"] == 0, "新接口伪代码回编译失败")
            ran = guarded("session-" + arch + "-roundtrip-run", ["./" + output], environment())
            require(ran["returncode"] == 0, "新接口伪代码结果不符")
            reports.append({"arch": arch, "functions": len(functions), "blocks": len(blocks), "edges": len(edges),
                "incoming_callers": len(callers), "outgoing_calls": len(callees), "same_pid": True,
                "analysis_runs": 1, "cold_functions_ms": first["meta"]["elapsed_ms"],
                "warm_functions_ms": warm["meta"]["elapsed_ms"], "decompile_ms": decompile_times,
                "roundtrip": json.loads(ran["stdout"])})
    finally:
        service.close()
    remember(service)
    return reports


def boundaries(folder):
    base = request()
    count = 0
    service = AnalysisService()
    try:
        cases = [([], "invalid_request"), ({}, "unknown_operation"),
            ({**base, "op": "command", "command": "!id"}, "unknown_operation"),
            ({**base, "command": "aflj"}, "invalid_request"),
            ({**base, "limit": True}, "invalid_request"),
            ({**base, "limit": 501}, "invalid_request"),
            ({**base, "offset": -1}, "invalid_request"),
            ({**base, "arch": "x86_64"}, "invalid_request"),
            ({**base, "path": "../fixture"}, "path_denied"),
            ({**base, "path": "/etc/passwd"}, "path_denied"),
            ({**base, "path": "build/\x00fixture"}, "path_denied"),
            ({**base, "path": "."}, "path_denied"),
            ({**base, "path": "build/reverse-analysis/missing"}, "path_denied"),
            (request(op="cfg", address="0x10000400c;!id"), "invalid_address"),
            (request(op="cfg", address="sym._fixture_branch"), "invalid_address"),
            (request(op="cfg", address="0x10000000000000000"), "invalid_address"),
            (request(op="cfg", address=4294983692), "invalid_address"),
            (request(op="refs", address="0x100004000", direction="both"), "invalid_request"),
            ({**base, "arch": "arm64e"}, "arch_mismatch")]
        inside = folder / "inside-link"
        inside.symlink_to(os.path.relpath(CACHE / "fixture-arm64", folder))
        outside = folder / "outside-link"
        outside.symlink_to("/etc/passwd")
        linked_folder = folder / "directory-link"
        linked_folder.symlink_to("..", target_is_directory=True)
        for path in (inside, outside, linked_folder / "fixture-arm64"):
            cases.append(({**base, "path": str(path.relative_to(ROOT))}, "path_denied"))
        junk = folder / "junk"
        junk.write_bytes(b"not-a-macho" * 16)
        cases.append(({**base, "path": str(junk.relative_to(ROOT))}, "invalid_binary"))
        malformed = folder / "malformed"
        data = bytearray((CACHE / "fixture-arm64").read_bytes())
        struct.pack_into("<I", data, 20, 0xFFFFFFFF)
        malformed.write_bytes(data)
        cases.append(({**base, "path": str(malformed.relative_to(ROOT))}, "invalid_binary"))
        encrypted = folder / "encrypted"
        data = bytearray((CACHE / "fixture-arm64").read_bytes())
        position = 32
        found = False
        for _ in range(struct.unpack_from("<I", data, 16)[0]):
            cmd, size = struct.unpack_from("<II", data, position)
            if cmd == 0x2C:
                struct.pack_into("<I", data, position + 16, 1)
                found = True
                break
            position += size
        require(found, "样本缺少加密标志命令")
        encrypted.write_bytes(data)
        cases.append(({**base, "path": str(encrypted.relative_to(ROOT))}, "invalid_binary"))
        oversized = folder / "oversized"
        with oversized.open("wb") as stream:
            stream.truncate(MAX_FILE + 1)
        cases.append(({**base, "path": str(oversized.relative_to(ROOT))}, "input_limit"))
        for value, code in cases:
            rejected(service, value, code)
            count += 1
        require(not service.started_pids, "无效参数在拒绝前启动了引擎")
        rejected(service, request(op="cfg", address="0x1"), "function_not_found")
        require(not service.sessions, "函数不存在后的会话没有清理")
        count += 1
    finally:
        service.close()
    remember(service)
    return count


def cache_checks(folder):
    changed = folder / "changed"
    shutil.copyfile(CACHE / "fixture-arm64", changed)
    value = {**request(), "path": str(changed.relative_to(ROOT))}
    service = AnalysisService(max_sessions=1)
    try:
        first = ok(service, value)
        alias = ok(service, request())
        require(alias["meta"]["cache_hit"] and alias["meta"]["pid"] == first["meta"]["pid"], "相同内容别名未复用")
        metadata = changed.stat()
        with changed.open("r+b") as stream:
            stream.seek(-1, 2)
            byte = stream.read(1)
            stream.seek(-1, 2)
            stream.write(bytes([byte[0] ^ 1]))
        os.utime(changed, ns=(metadata.st_atime_ns, metadata.st_mtime_ns))
        second = ok(service, value)
        require(not second["meta"]["cache_hit"] and first["meta"]["sha256"] != second["meta"]["sha256"], "同大小同 mtime 的内容变化没有失效")
        require(gone(first["meta"]["pid"]), "LRU 淘汰后进程残留")
        require(len(service.sessions) == 1 and len(list(service.folder.glob("*.macho"))) == 1, "缓存或快照超额")
        ok(service, request("arm64e"))
        require(gone(second["meta"]["pid"]), "跨架构淘汰后进程残留")
        warm = ok(service, request("arm64e"))
        pid = warm["meta"]["pid"]
        os.kill(pid, signal.SIGKILL)
        next(iter(service.sessions.values())).proc.wait()
        recovered = ok(service, request("arm64e"))
        require(not recovered["meta"]["cache_hit"] and recovered["meta"]["pid"] != pid, "死亡进程被错误复用")
        # 每个工作进程最多完成 128 个请求，避免无限增长的引擎状态。
        worker = next(iter(service.sessions.values()))
        for _ in range(128 - worker.requests):
            ok(service, request("arm64e"))
        rotated = ok(service, request("arm64e"))
        require(rotated["meta"]["pid"] != recovered["meta"]["pid"] and gone(recovered["meta"]["pid"]), "请求次数上限未轮换")
        service.idle_seconds = 0.01
        time.sleep(0.02)
        service.expire()
        require(not service.sessions and not list(service.folder.iterdir()), "空闲清理未清除进程和快照")
    finally:
        service.close()
    remember(service)
    # 对真实样本副本，在第一次读取后修改内容；只固定竞争时机，不伪造引擎结果。
    racing = folder / "racing"
    shutil.copyfile(CACHE / "fixture-arm64", racing)
    original_read = os.read
    fired = False
    inode = racing.stat().st_ino
    def mutate_after_read(fd, length):
        nonlocal fired
        result = original_read(fd, length)
        if not fired and os.fstat(fd).st_ino == inode:
            fired = True
            with racing.open("ab") as stream:
                stream.write(b"changed")
        return result
    service = AnalysisService()
    try:
        with patch("analysis_service.os.read", side_effect=mutate_after_read):
            rejected(service, {**request(), "path": str(racing.relative_to(ROOT))}, "input_changed")
        require(fired and not service.started_pids and not list(service.folder.iterdir()), "读取竞争未在引擎前拒绝并清理")
    finally:
        service.close()
    remember(service)
    return {"same_content_alias": True, "same_size_mtime_invalidation": True, "lru_reaped": True,
        "arch_separation": True, "dead_worker_recovery": True, "request_rotation": True,
        "idle_expiry": True, "input_changed_during_snapshot": True}


def host_controls(folder):
    service = AnalysisService()
    try:
        # 替换为另一个真实项目文件，验证版本变化在启动进程前拒绝。
        with patch("analysis_service.DRIVER", CACHE / "fixture-arm64"):
            rejected(service, request(), "engine_changed")
        require(not service.started_pids and not list(service.folder.iterdir()), "引擎变化后有残留")
        event = threading.Event()
        returned = []
        service.lock.acquire()
        thread = threading.Thread(target=lambda: returned.append(service.call(request(), cancel=event)))
        try:
            thread.start()
            time.sleep(0.03)
            event.set()
            thread.join(timeout=1)
            require(not thread.is_alive() and returned[0]["error"]["code"] == "cancelled", "等待会话锁时无法取消")
        finally:
            service.lock.release()
            thread.join(timeout=2)
        require(not service.started_pids, "已取消的排队请求仍启动了引擎")
    finally:
        service.close()
    rejected(service, request(), "closed")
    remember(service)
    return {"engine_change_rejected": True, "queued_request_cancelled": True, "closed_host_rejected": True}


def lifecycle():
    report = {}
    for mode in ("timeout", "cancelled", "output_limit", "startup_cancelled"):
        service = AnalysisService()
        event = threading.Event()
        timer = None
        try:
            options = {}
            if mode == "startup_cancelled":
                timer = threading.Timer(0.02, event.set)
                class CancelOnSpawn(list):
                    def append(self, pid):
                        super().append(pid)
                        timer.start()
                service.started_pids = CancelOnSpawn()
                options["cancel"] = event
                value = request()
            else:
                listing = ok(service, request())
                branch = next(item["address"] for item in listing["data"]["functions"] if item["name"] == "sym._fixture_branch")
                value = request(op="decompile", address=branch)
                if mode == "timeout":
                    options["timeout"] = 0.02
                elif mode == "cancelled":
                    timer = threading.Timer(0.02, event.set)
                    timer.start()
                    options["cancel"] = event
                else:
                    options["output_limit"] = 32
            started = time.monotonic()
            rejected(service, value, "cancelled" if mode == "startup_cancelled" else mode, **options)
            elapsed = time.monotonic() - started
            require(elapsed < 2 and not service.sessions, "异常请求没有及时清理")
            require(service.started_pids and all(gone(pid) for pid in service.started_pids), "异常请求有进程组残留")
            require(not list(service.folder.iterdir()), "异常请求有快照残留")
            report[mode] = {"seconds": round(elapsed, 4), "process_groups_gone": True, "snapshots_removed": True}
        finally:
            if timer is not None:
                timer.cancel()
                timer.join()
            service.close()
        remember(service)
    return report


def native_protocol():
    service = AnalysisService()
    worker = None
    rejected_count = 0
    try:
        worker = Worker(CACHE / "fixture-arm64", service.env, time.monotonic() + 15, None, ALL_PIDS.append)
        for command in ("!id", "functions;!id", "cfg 0x10000400c;!id", "cfg sym._fixture_branch",
                        "functions extra", "x" * 120, "cfg 0x1\x00", "cfg 0x10000000000000000"):
            try:
                worker.query(command, time.monotonic() + 5, None)
                raise AssertionError("原生入口接受了非法命令")
            except AnalysisError as error:
                require(error.code == "invalid_request", "原生错误分类不符")
                rejected_count += 1
        require(len(worker.query("functions", time.monotonic() + 5, None)) == 5, "拒绝非法请求后协议失步")
    finally:
        if worker is not None:
            worker.close()
        service.close()
    remember(service)
    return rejected_count


def jsonl_cli():
    lines = "\n".join([json.dumps(request()), "{broken", json.dumps(request())]) + "\n"
    ran = subprocess.run([sys.executable, "Tests/ReverseAnalysis/analysis_service.py"], cwd=ROOT,
                         input=lines, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    require(ran.returncode == 0, "JSONL 演示宿主失败")
    values = [json.loads(line) for line in ran.stdout.splitlines()]
    require(len(values) == 3 and values[0]["ok"] and not values[1]["ok"] and values[2]["ok"], "JSONL 错误隔离失败")
    pid = values[0]["meta"]["pid"]
    require(values[2]["meta"]["pid"] == pid and gone(pid), "JSONL 未复用或 EOF 没有清理")
    ALL_PIDS.append(pid)
    return {"valid_invalid_valid": True, "same_pid": True, "eof_reaped": True}


def main():
    RESULTS.mkdir(parents=True, exist_ok=True)
    inputs = [ROOT / "Tests/ReverseAnalysis/fixture.c", CACHE / "fixture-arm64", CACHE / "fixture-arm64e"]
    before = {str(path.relative_to(ROOT)): sha256(path) for path in inputs}
    report = {"engine_sha256": sha256(DRIVER), "inputs_before": before}
    report["architectures"] = features()
    print("两个架构：四项能力、同进程复用、分页和伪代码回编译通过", flush=True)
    with tempfile.TemporaryDirectory(prefix="service-acceptance-", dir=CACHE) as directory:
        folder = Path(directory)
        report["rejected_host_cases"] = boundaries(folder)
        report["cache"] = cache_checks(folder)
        report["host_controls"] = host_controls(folder)
    report["lifecycle"] = lifecycle()
    report["rejected_native_cases"] = native_protocol()
    report["jsonl"] = jsonl_cli()
    after = {str(path.relative_to(ROOT)): sha256(path) for path in inputs}
    require(before == after, "原始输入发生变化")
    require(all(gone(pid) for pid in ALL_PIDS), "验收结束后有残留进程组")
    report.update({"inputs_after": after, "input_unchanged": True, "all_process_groups_gone": True,
                   "started_processes": len(ALL_PIDS), "passed": True})
    (RESULTS / "session-report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
    print("固定接口、缓存失效、超时取消、限额、异常回收和输入不变全部通过", flush=True)


if __name__ == "__main__":
    main()
