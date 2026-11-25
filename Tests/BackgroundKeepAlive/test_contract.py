#!/usr/bin/env python3
"""实时活动与保活桥接的源码约束检查；不替代 Swift 类型检查或真机验收。"""

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]


def source(path):
    return (ROOT / path).read_text(encoding="utf-8")


def block(text, marker):
    """提取标记后的 Swift 代码块；忽略字符串和行注释内的花括号。"""
    start = text.index("{", text.index(marker))
    tokens = re.compile(r'//[^\n]*|"(?:\\.|[^"\\])*"|[{}]', re.MULTILINE)
    depth = 0
    for match in tokens.finditer(text, start):
        token = match.group()
        if token == "{":
            depth += 1
        elif token == "}":
            depth -= 1
            if depth == 0:
                return text[start + 1:match.start()]
    raise AssertionError("代码块没有闭合：" + marker)


class ActivityContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.widget = source("Widgets/Extension/ChatsActivityWidget.swift")
        cls.row = block(cls.widget, "private struct ChatActivitySessionRow")

    def test_finished_identity_is_not_gated_at_entry(self):
        self.assertNotIn("if let chat = state.mostUrgent, state.finishedBadge == nil", self.widget)
        self.assertEqual(self.widget.count("ChatActivitySessionRow(chat: chat, state: state)"), 2)

    def test_identity_and_status_remain_outside_flow(self):
        flow = self.row.index("if state.finishedBadge == nil")
        for identity in ("chat.title", "chat.projectName", "phase.title"):
            self.assertLess(self.row.index("Text(verbatim: " + identity + ")"), flow)

    def test_details_and_tools_are_gated_together(self):
        flow = block(self.row, "if state.finishedBadge == nil")
        for content in ("if let detail = phase.detail", "ForEach(state.recentTools.indices"):
            self.assertIn(content, flow)
            self.assertEqual(self.row.count(content), 1)

    def test_finished_phase_uses_result_not_last_tool(self):
        phase = block(self.widget, "if let badge = finishedBadge")
        self.assertIn("batchOutcome == .stopped ? badge.label : chat.statusLine", phase)
        self.assertIn("return (badge.symbol, badge.color", phase)
        self.assertNotIn("currentTool", phase)
        self.assertNotIn("recentTools", phase)


class KeepAliveContract(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.keepalive = source("Apelin/Widgets/BackgroundKeepAlive.swift")

    def test_pending_request_is_not_replaced(self):
        count = block(self.keepalive, "static func setRunningCount")
        self.assertLess(count.index("guard !isAcquiring, !isHolding"), count.index("acquire()"))
        self.assertIn("guard count > 0 else", count)

    def test_block_callback_is_kept_alive_through_init(self):
        acquire = block(self.keepalive, "private static func acquire()")
        self.assertIn("@convention(block) (Bool) -> Void", acquire)
        self.assertIn("withExtendedLifetime((name, handlerObject))", acquire)
        self.assertIn("Unmanaged.passUnretained(handlerObject).toOpaque()", acquire)
        self.assertIn("acquisitionFinished(acquired, request: id)", acquire)

    def test_initial_validity_does_not_trigger_release(self):
        acquire = block(self.keepalive, "private static func acquire()")
        stored = acquire.index("assertion = Unmanaged<NSObject>")
        timeout = acquire.index("acquisitionTimeout = Task", stored)
        self.assertNotIn("release(", acquire[stored:timeout])
        self.assertIn("requestID == id, isAcquiring", acquire[timeout:])
        self.assertIn("Task.sleep(for: .seconds(10))", acquire[timeout:])

    def test_late_callback_cannot_release_new_request(self):
        callback = block(self.keepalive, "private static func acquisitionFinished")
        self.assertTrue(callback.lstrip().startswith("guard requestID == id, assertion != nil else"))
        self.assertIn("guard acquired, valid else", callback)
        self.assertIn("retryNotBefore =", callback)

    def test_release_invalidates_request_before_object(self):
        release = block(self.keepalive, "private static func release(reason:")
        self.assertLess(release.index("requestID = nil"), release.index("bridge.invalidate"))
        self.assertIn("acquisitionTimeout?.cancel()", release)
        self.assertIn("record(", release)

    def test_background_sync_depends_on_running_chats(self):
        runtime = source("Apelin/Interface/Chats/ChatRuntime.swift")
        watcher = block(runtime, "private func watchHostRuns()")
        self.assertIn("self.records.values.contains(where: { $0.summary.isWorking })", watcher)
        self.assertNotIn("BackgroundKeepAlive.isHolding", watcher)

    def test_persistent_journal_is_connected(self):
        journal = source("Apelin/Application/AppJournal.swift")
        self.assertIn("BackgroundKeepAlive.diagnosticHandler =", journal)
        self.assertIn('Dog.shared.join("KeepAlive", message, level: isError ? .error : .info)', journal)


if __name__ == "__main__":
    unittest.main()
