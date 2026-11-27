#!/usr/bin/env python3
"""容量静态契约；不加载分析引擎，也不代替设备上的协议回归。"""
import ast
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
EXT = ROOT / "Extensions/AgentTools/ReverseAnalysis"
MIB = 1024 * 1024


class CapacityContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.runtime = (EXT / "Sources/Runtime.h").read_text()
        cls.worker = (EXT / "Sources/Worker.c").read_text()
        cls.analysis = (EXT / "Sources/Analysis.m").read_text()
        cls.server = (EXT / "Sources/Server.m").read_text()
        cls.regression = (ROOT / "Tests/ReverseAnalysis/verify_extension.py").read_text()
        cls.tree = ast.parse(cls.regression)

    def test_both_processes_use_48_mib(self):
        for source, pattern in (
            (self.runtime, r"RAMaxFile\s*=\s*(\d+)\s*\*\s*1024\s*\*\s*1024"),
            (self.worker, r"input\.st_size\s*>\s*(\d+)\s*\*\s*1024\s*\*\s*1024"),
        ):
            match = re.search(pattern, source)
            self.assertIsNotNone(match)
            self.assertEqual(int(match.group(1)) * MIB, 48 * MIB)

    def test_snapshot_uses_shared_inclusive_limit(self):
        self.assertIn("before.st_size < 32 || before.st_size > RAMaxFile", self.analysis)

    def test_attachment_uses_same_inclusive_limit(self):
        self.assertIn("info.st_size <= RAMaxFile", self.server)

    def test_description_and_error_match_limit(self):
        descriptor = json.loads((EXT / "Descriptors.json").read_text())
        functions = next(tool for tool in descriptor["tools"] if tool["name"] == "analyze_functions")
        self.assertIn("最大 48 MiB", functions["description"])
        self.assertIn("32 字节至 48 MiB", self.analysis)
        self.assertIn("输入限 48 MiB", (EXT / "README.md").read_text())

    def test_runtime_regression_has_accept_and_reject_boundaries(self):
        assignments = {
            target.id: node.value
            for node in self.tree.body if isinstance(node, ast.Assign)
            for target in node.targets if isinstance(target, ast.Name)
        }
        for name, expression in (
            ("INPUT_LIMIT", "48 * 1024 * 1024"),
            ("CAPACITY_SIZES", "(32 * 1024 * 1024 + 1, 41 * 1024 * 1024, INPUT_LIMIT)"),
        ):
            self.assertEqual(ast.dump(assignments[name]), ast.dump(ast.parse(expression, mode="eval").body))
        self.assertIn("stream.truncate(INPUT_LIMIT + 1)", self.regression)
        self.assertIn('client.reject("invalidArguments", binary=native(oversized))', self.regression)
        self.assertIn('client.reject("attachmentRejected", arch=arch', self.regression)

    def test_runtime_capacity_is_called_by_main(self):
        main = next(node for node in self.tree.body if isinstance(node, ast.FunctionDef) and node.name == "main")
        calls = [node.func.id for node in ast.walk(main)
                 if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)]
        self.assertIn("input_capacity", calls)
        capacity = next(node for node in self.tree.body
                        if isinstance(node, ast.FunctionDef) and node.name == "input_capacity")
        source = ast.get_source_segment(self.regression, capacity)
        self.assertIn('for arch in ("arm64", "arm64e")', source)
        self.assertIn("for size in CAPACITY_SIZES", source)
        self.assertIn('"byteCount": INPUT_LIMIT}', source)
        self.assertIn('attached["meta"]["cache_hit"]', source)
        self.assertIn("hashlib.sha256(padded.read_bytes()).hexdigest() == digest", source)

    def test_reply_limits_are_not_raised(self):
        self.assertIn("RAMaxFrame = 1024 * 1024", self.runtime)
        self.assertIn("RAMaxReply = 256 * 1024", self.runtime)


if __name__ == "__main__":
    unittest.main(verbosity=2)
