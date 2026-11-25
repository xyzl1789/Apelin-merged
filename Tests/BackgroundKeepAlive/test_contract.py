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
        cls.module = source("Background/ApelinForeground.m")
        cls.app = source("Apelin/Application/ForegroundBackground.swift")

    def test_old_assertion_is_removed(self):
        self.assertFalse((ROOT / "Apelin/Widgets/BackgroundKeepAlive.swift").exists())
        self.assertNotIn("BackgroundKeepAlive", source("Apelin/Widgets/ChatWidgetPublisher.swift"))
        self.assertNotIn("BKSProcessAssertion", self.module + self.app)

    def test_only_springboard_is_injected(self):
        import plistlib
        plist = plistlib.loads((ROOT / "Background/ApelinForeground.plist").read_bytes())
        self.assertEqual(plist, {"Filter": {"Bundles": ["com.apple.springboard"]}})
        self.assertIn('APFBundle = @"wiki.qaq.apelin"', self.module)
        self.assertNotIn('hook(objc_getClass("UIMutableApplicationSceneSettings")', self.module)

    def test_scene_calls_original_without_losing_callbacks(self):
        self.assertIn("APFOriginalScene(self, cmd, replacement ?: settings, transition, completion)", self.module)
        self.assertIn("if (!APFTarget(self))", self.module)
        self.assertIn("configured && APFHolding()", self.module)
        self.assertIn("[settings mutableCopy]", self.module)

    def test_disabled_restores_last_system_settings(self):
        self.assertIn("APFRestoreScenes();", self.module)
        self.assertIn("setObject:[settings copy] forKey:self", self.module)
        self.assertIn("replacement ?: settings, nil, nil", self.module)
        self.assertIn("APFLiveRequest()", self.module)

    def test_foreground_notification_uses_both_halves(self):
        self.assertIn("_didChangeApplicationState:forBundleIdentifier:", self.module)
        self.assertIn("APFNotificationState(self, YES)", self.module)
        self.assertIn("APFOriginalNotice(self, cmd, notification, bundle, completion)", self.module)
        delegate = source("Apelin/Application/ConversationNotices.swift")
        self.assertIn("ForegroundBackground.foregroundNotifications ||", delegate)
        self.assertIn("[.banner, .list, .sound]", delegate)

    def test_independent_switches_and_conservative_status(self):
        self.assertIn('bool(forKey: "foregroundBackground.enabled")', self.app)
        self.assertIn('as? Bool ?? true', self.app)
        self.assertIn("hasFreshStatus", self.app)
        self.assertIn("持续运行仍需实测", self.app)
        self.assertIn("ForegroundBackground.isActuallyVisible", source("Apelin/Interface/Chats/ChatController.swift"))

    def test_background_sync_depends_on_running_chats(self):
        runtime = source("Apelin/Interface/Chats/ChatRuntime.swift")
        watcher = block(runtime, "private func watchHostRuns()")
        self.assertIn("self.records.values.contains(where: { $0.summary.isWorking })", watcher)

    def test_both_flavors_and_corresponding_source_are_packaged(self):
        build = source("Background/build.sh")
        self.assertIn("roothide) arch=arm64e", build)
        self.assertIn("rootless) arch=arm64", build)
        packager = source("Scripts/package-deb.sh")
        self.assertIn("ForegroundSource", packager)
        self.assertIn("ApelinForeground.m ApelinForeground.plist build.sh README.md LICENSE", packager)
        self.assertIn('ldid -S -Cadhoc "$foreground_dir/ApelinForeground.dylib"', packager)
        self.assertIn('lipo -archs "$foreground_dir/ApelinForeground.dylib"', packager)
        self.assertIn("Background/build.sh", source("Makefile"))
        self.assertIn("ApelinForeground-LICENSE.txt", packager)
        self.assertIn("SceneCheck.m", source("Makefile"))

    def test_license_is_preserved_without_linking_into_app(self):
        self.assertIn("SPDX-License-Identifier: GPL-3.0-or-later", self.module)
        self.assertIn("Serge Alagon", self.module)
        self.assertIn("Version 3", source("Background/LICENSE"))
        project = source("Apelin.xcodeproj/project.pbxproj")
        self.assertNotIn("ApelinForeground.m", project)
        self.assertNotIn("Background/", project)


if __name__ == "__main__":
    unittest.main()
