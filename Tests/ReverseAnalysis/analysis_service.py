#!/usr/bin/env python3
"""隔离的固定操作宿主原型；不注册 AI 工具，不执行任意引擎命令。"""
from collections import OrderedDict
import hashlib
import json
import math
import os
from pathlib import Path
import re
import selectors
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time

from build_native import CACHE, ROOT, environment

MAX_FILE = 32 * 1024 * 1024
MAX_FRAME = 1024 * 1024
MAX_REPLY = 256 * 1024
DRIVER = CACHE / "reverse-session-native"
ERRORS = {
    "invalid_request": "请求字段或类型不合法", "unknown_operation": "不支持该操作",
    "invalid_address": "地址必须是完整的十六进制函数入口", "path_denied": "只允许项目内的普通文件且路径不能含符号链接",
    "invalid_binary": "只支持未加密的 ARM64 薄 Mach-O", "arch_mismatch": "请求架构与样本不匹配",
    "input_changed": "读取期间样本发生变化，请重试", "input_limit": "样本超出大小限额",
    "timeout": "分析超时，已回收工作进程", "cancelled": "分析已取消，已回收工作进程",
    "output_limit": "结果或诊断超出限额，已回收工作进程", "worker_exited": "分析进程意外结束",
    "protocol_error": "分析进程返回无效响应", "function_not_found": "未发现该地址对应的函数入口",
    "engine_error": "原生引擎未能完成分析", "engine_changed": "分析程序已变化，请新建宿主会话", "closed": "宿主已关闭",
}


class AnalysisError(Exception):
    def __init__(self, code):
        self.code = code
        super().__init__(ERRORS.get(code, ERRORS["engine_error"]))


def check(deadline, cancel):
    if cancel is not None and cancel.is_set():
        raise AnalysisError("cancelled")
    if time.monotonic() >= deadline:
        raise AnalysisError("timeout")


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(256 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


class Worker:
    def __init__(self, snapshot, env, deadline, cancel, on_spawn):
        self.proc = None
        self.selector = selectors.DefaultSelector()
        self.diagnostic_bytes = 0
        self.requests = 0
        self.last_used = time.monotonic()
        try:
            self.proc = subprocess.Popen(
                ["./" + str(DRIVER.relative_to(ROOT)), str(snapshot.relative_to(ROOT))],
                cwd=ROOT, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, bufsize=0, start_new_session=True)
            on_spawn(self.proc.pid)
            for stream in (self.proc.stdout, self.proc.stderr):
                os.set_blocking(stream.fileno(), False)
                self.selector.register(stream, selectors.EVENT_READ)
            ready = self.receive(deadline, cancel)
            if ready != {"ready": True, "analysis_runs": 1}:
                raise AnalysisError("protocol_error")
        except BaseException:
            self.close()
            raise

    def read_exact(self, size, deadline, cancel):
        result = bytearray()
        while len(result) < size:
            check(deadline, cancel)
            for key, _ in self.selector.select(min(0.02, max(0, deadline - time.monotonic()))):
                stream = key.fileobj
                try:
                    data = os.read(stream.fileno(), min(8192, size - len(result))
                                   if stream is self.proc.stdout else 8192)
                except BlockingIOError:
                    continue
                if not data:
                    self.selector.unregister(stream)
                    if stream is self.proc.stdout:
                        raise AnalysisError("worker_exited")
                    continue
                if stream is self.proc.stdout:
                    result.extend(data)
                else:
                    self.diagnostic_bytes += len(data)
                    if self.diagnostic_bytes > MAX_FRAME:
                        raise AnalysisError("output_limit")
            if self.proc.poll() is not None and not result:
                raise AnalysisError("worker_exited")
        return bytes(result)

    def receive(self, deadline, cancel):
        length = struct.unpack("!I", self.read_exact(4, deadline, cancel))[0]
        if not 0 < length <= MAX_FRAME:
            raise AnalysisError("output_limit")
        try:
            value = json.loads(self.read_exact(length, deadline, cancel))
        except (ValueError, UnicodeError) as error:
            raise AnalysisError("protocol_error") from error
        if not isinstance(value, dict) or type(value.get("ok")) is not bool:
            raise AnalysisError("protocol_error")
        if not value["ok"]:
            code = value.get("error")
            raise AnalysisError(code if code in ERRORS else "engine_error")
        if "data" not in value:
            raise AnalysisError("protocol_error")
        return value["data"]

    def query(self, command, deadline, cancel):
        check(deadline, cancel)
        try:
            self.proc.stdin.write(command.encode("ascii") + b"\n")
            self.proc.stdin.flush()
        except (BrokenPipeError, OSError) as error:
            raise AnalysisError("worker_exited") from error
        data = self.receive(deadline, cancel)
        self.requests += 1
        self.last_used = time.monotonic()
        return data

    def close(self):
        if self.proc is not None:
            # 即使进程组长已退出，也要回收仍属于该组的子进程。
            try:
                os.killpg(self.proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            self.proc.wait()
            for stream in (self.proc.stdin, self.proc.stdout, self.proc.stderr):
                if stream is not None:
                    stream.close()
        self.selector.close()


class AnalysisService:
    """串行处理固定请求，最多保留两个会话；取消由调用宿主持有 Event。"""
    def __init__(self, max_sessions=2, idle_seconds=60):
        if type(max_sessions) is not int or not 1 <= max_sessions <= 2:
            raise ValueError("会话数必须在 1～2 之间")
        if not isinstance(idle_seconds, (float, int)) or idle_seconds <= 0:
            raise ValueError("空闲时限必须为正数")
        self.env = environment()
        root = self.env["APELIN_PROJECT_ROOT"]
        self.env.update({"R2_NOPLUGINS": "1", "HOME": root + "/build/reverse-analysis/home",
                         "SLEIGHHOME": root + "/build/reverse-analysis/r2ghidra_sleigh-6.2.6-source/r2ghidra_sleigh-6.2.6"})
        self.engine_digest = sha256(DRIVER)
        self.temp = tempfile.TemporaryDirectory(prefix="sessions-", dir=CACHE)
        self.folder = Path(self.temp.name)
        self.sessions = OrderedDict()
        self.max_sessions = max_sessions
        self.idle_seconds = idle_seconds
        self.lock = threading.RLock()
        self.closed = False
        self.started_pids = []

    def validate(self, request):
        if type(request) is not dict:
            raise AnalysisError("invalid_request")
        op = request.get("op")
        if not isinstance(op, str) or op not in {"functions", "cfg", "refs", "decompile"}:
            raise AnalysisError("unknown_operation")
        required = {"op", "path", "arch"}
        optional = {"offset", "limit"} if op == "functions" else {"address"}
        if op == "refs":
            required.add("direction")
        if not required <= request.keys() or request.keys() - required - optional:
            raise AnalysisError("invalid_request")
        if request.get("arch") not in ("arm64", "arm64e"):
            raise AnalysisError("invalid_request")
        if op == "functions":
            offset, limit = request.get("offset", 0), request.get("limit", 100)
            if type(offset) is not int or offset < 0 or type(limit) is not int or not 1 <= limit <= 500:
                raise AnalysisError("invalid_request")
            command = "functions"
        else:
            address = request.get("address")
            if not isinstance(address, str) or re.fullmatch(r"0x[0-9a-fA-F]{1,16}", address) is None:
                raise AnalysisError("invalid_address")
            if op == "refs" and request["direction"] not in ("in", "out"):
                raise AnalysisError("invalid_request")
            native_op = "refs_" + request["direction"] if op == "refs" else op
            command = native_op + " " + hex(int(address, 16))
        path = request["path"]
        if not isinstance(path, str) or not path or "\x00" in path or Path(path).is_absolute() or ".." in Path(path).parts:
            raise AnalysisError("path_denied")
        try:
            resolved = (ROOT / path).resolve(strict=True)
            if not resolved.is_relative_to(ROOT.resolve()) or not resolved.is_file():
                raise AnalysisError("path_denied")
        except (OSError, RuntimeError, ValueError) as error:
            raise AnalysisError("path_denied") from error
        return command

    def snapshot(self, path, arch, deadline, cancel):
        """逐组件不跟随链接打开；复制后比较身份，内容摘要每次重算。"""
        directory = os.open(ROOT, os.O_RDONLY | os.O_DIRECTORY)
        source = None
        temporary = None
        try:
            parts = Path(path).parts
            for part in parts[:-1]:
                following = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
                os.close(directory)
                directory = following
            source = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
            before = os.fstat(source)
            if not stat.S_ISREG(before.st_mode):
                raise AnalysisError("path_denied")
            if not 32 <= before.st_size <= MAX_FILE:
                raise AnalysisError("input_limit")
            digest = hashlib.sha256()
            header = bytearray()
            total = 0
            with tempfile.NamedTemporaryFile(dir=self.folder, delete=False) as output:
                temporary = Path(output.name)
                while True:
                    check(deadline, cancel)
                    block = os.read(source, 256 * 1024)
                    if not block:
                        break
                    total += len(block)
                    if total > MAX_FILE:
                        raise AnalysisError("input_limit")
                    if len(header) < 32:
                        header.extend(block[:32 - len(header)])
                    digest.update(block)
                    output.write(block)
            after = os.fstat(source)
            identity = lambda s: (s.st_dev, s.st_ino, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            if identity(before) != identity(after) or total != before.st_size:
                raise AnalysisError("input_changed")
            if len(header) != 32 or struct.unpack_from("<II", header) != (0xFEEDFACF, 0x100000C):
                raise AnalysisError("invalid_binary")
            subtype = struct.unpack_from("<I", header, 8)[0] & 0xFFFFFF
            actual = {0: "arm64", 2: "arm64e"}.get(subtype)
            if actual is None or actual != arch:
                raise AnalysisError("arch_mismatch")
            # 加密的 Mach-O 不进入分析；同时验证 load command 的边界。
            ncmds, sizeofcmds = struct.unpack_from("<II", header, 16)
            if sizeofcmds > total - 32 or ncmds > sizeofcmds // 8:
                raise AnalysisError("invalid_binary")
            with temporary.open("rb") as sample:
                sample.seek(32)
                commands = sample.read(sizeofcmds)
            position = 0
            for _ in range(ncmds):
                check(deadline, cancel)
                if position + 8 > len(commands):
                    raise AnalysisError("invalid_binary")
                cmd, size = struct.unpack_from("<II", commands, position)
                if size < 8 or size % 8 or position + size > len(commands):
                    raise AnalysisError("invalid_binary")
                if cmd in (0x21, 0x2C) and (size < 20 or struct.unpack_from("<I", commands, position + 16)[0]):
                    raise AnalysisError("invalid_binary")
                position += size
            if position != sizeofcmds:
                raise AnalysisError("invalid_binary")
            key = (digest.hexdigest(), arch, self.engine_digest, 1)
            destination = self.folder / (key[0] + ".macho")
            if destination.exists():
                temporary.unlink()
            else:
                temporary.chmod(0o400)
                temporary.rename(destination)
            temporary = None
            return key, destination
        except OSError as error:
            raise AnalysisError("path_denied") from error
        finally:
            os.close(directory)
            if source is not None:
                os.close(source)
            if temporary is not None:
                temporary.unlink(missing_ok=True)

    def evict(self, key):
        self.sessions.pop(key).close()
        snapshot = self.folder / (key[0] + ".macho")
        if not any(other[0] == key[0] for other in self.sessions):
            snapshot.unlink(missing_ok=True)

    def expire(self):
        """在请求入口或宿主空闲定时器中调用；不创建后台线程。"""
        with self.lock:
            for key, worker in list(self.sessions.items()):
                if (time.monotonic() - worker.last_used >= self.idle_seconds or
                        worker.requests >= 128 or worker.proc.poll() is not None):
                    self.evict(key)

    def call(self, request, *, timeout=15, cancel=None, output_limit=MAX_REPLY):
        started = time.monotonic()
        key = None
        try:
            if (type(timeout) not in (int, float) or not math.isfinite(timeout) or not 0 < timeout <= 60 or
                    type(output_limit) is not int or not 1 <= output_limit <= MAX_REPLY):
                raise AnalysisError("invalid_request")
            deadline = started + timeout
            command = self.validate(request)
            # 锁等待也计入取消与超时，不阻塞其他调用的取消信号。
            while not self.lock.acquire(timeout=0.02):
                check(deadline, cancel)
            try:
                check(deadline, cancel)
                if self.closed:
                    raise AnalysisError("closed")
                self.expire()
                key, snapshot = self.snapshot(request["path"], request["arch"], deadline, cancel)
                hit = key in self.sessions
                if not hit:
                    if sha256(DRIVER) != self.engine_digest:
                        raise AnalysisError("engine_changed")
                    check(deadline, cancel)
                    while len(self.sessions) >= self.max_sessions:
                        self.evict(next(iter(self.sessions)))
                    self.sessions[key] = Worker(snapshot, self.env, deadline, cancel, self.started_pids.append)
                worker = self.sessions[key]
                self.sessions.move_to_end(key)
                raw = worker.query(command, deadline, cancel)
                data = self.normalize(request, raw)
                reply = {"ok": True, "data": data, "meta": {
                    "cache_hit": hit, "pid": worker.proc.pid, "analysis_runs": 1,
                    "sha256": key[0], "arch": key[1], "engine_sha256": key[2],
                    "elapsed_ms": round((time.monotonic() - started) * 1000, 3)}}
                if len(json.dumps(reply, ensure_ascii=False).encode()) > output_limit:
                    raise AnalysisError("output_limit")
                check(deadline, cancel)
                return reply
            except BaseException:
                if key in self.sessions:
                    self.evict(key)
                elif key is not None:
                    (self.folder / (key[0] + ".macho")).unlink(missing_ok=True)
                raise
            finally:
                self.lock.release()
        except AnalysisError as error:
            return {"ok": False, "error": {"code": error.code, "message": str(error)}}
        except (OSError, ValueError, TypeError) as error:
            return {"ok": False, "error": {"code": "engine_error", "message": ERRORS["engine_error"]}}

    @staticmethod
    def normalize(request, raw):
        op = request["op"]
        if op == "functions":
            if type(raw) is not list:
                raise AnalysisError("protocol_error")
            items = sorted(raw, key=lambda item: item["addr"])
            offset, limit = request.get("offset", 0), request.get("limit", 100)
            page = [{"address": hex(item["addr"]), "name": item["name"],
                     "size": item["size"], "blocks": item["nbbs"]} for item in items[offset:offset + limit]]
            return {"functions": page, "total": len(items),
                    "next_offset": offset + len(page) if offset + len(page) < len(items) else None}
        if op == "decompile":
            if type(raw) is not dict or not isinstance(raw.get("code"), str) or not raw["code"].strip():
                raise AnalysisError("engine_error")
        elif type(raw) is not list:
            raise AnalysisError("protocol_error")
        # 地址保留为字符串，避免未来 JSON 消费者丢失 64 位精度。
        address_keys = {"addr", "offset", "jump", "fail", "ptr", "from", "to", "ref", "fcn_addr"}
        def convert(value):
            if isinstance(value, list):
                return [convert(item) for item in value]
            if isinstance(value, dict):
                return {key: hex(item) if key in address_keys and type(item) is int else convert(item)
                        for key, item in value.items()}
            return value
        return convert(raw)

    def close(self):
        with self.lock:
            if not self.closed:
                for key in list(self.sessions):
                    self.evict(key)
                self.temp.cleanup()
                self.closed = True

    def __enter__(self):
        return self

    def __exit__(self, *args):
        self.close()


def main():
    # 演示入口按行读取 JSON；实际 AI 宿主的取消令牌接入不在此阶段。
    with AnalysisService() as service:
        while True:
            line = sys.stdin.buffer.readline(8194)
            if not line:
                break
            if len(line) > 8192:
                response = {"ok": False, "error": {"code": "invalid_request", "message": ERRORS["invalid_request"]}}
                print(json.dumps(response, ensure_ascii=False), flush=True)
                break
            try:
                request = json.loads(line)
                response = service.call(request)
            except (ValueError, UnicodeError):
                response = {"ok": False, "error": {"code": "invalid_request", "message": ERRORS["invalid_request"]}}
            print(json.dumps(response, ensure_ascii=False), flush=True)


if __name__ == "__main__":
    main()
