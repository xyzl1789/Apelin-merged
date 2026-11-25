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
        flow = self.row.index("if state.detailsEnabled && state.finishedBadge == nil")
        for identity in ("chat.title", "chat.projectName", "phase.title"):
            self.assertLess(self.row.index("Text(verbatim: " + identity + ")"), flow)

    def test_details_and_tools_are_gated_together(self):
        flow = block(self.row, "if state.detailsEnabled && state.finishedBadge == nil")
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
        self.assertIn("APFNotificationState(self, !visible)", self.module)
        self.assertIn("BOOL visible = APFVisible()", self.module)
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

    def test_only_actually_visible_current_conversation_is_suppressed(self):
        delegate = source("Apelin/Application/ConversationNotices.swift")
        rule = block(delegate, "nonisolated static func suppressesViewedConversation")
        self.assertIn("guard actuallyVisible, let visibleSession, !visibleSession.isEmpty", rule)
        self.assertIn("notificationSession == visibleSession", rule)
        callback = block(delegate, "willPresent notification:")
        self.assertIn("notification.request.content.threadIdentifier", delegate)
        for value in ("self.visibleChat?.notificationSessionID", "ForegroundBackground.isActuallyVisible", "completionHandler([])"):
            self.assertIn(value, callback)
        self.assertLess(callback.index("suppressesViewedConversation"), callback.index("let show ="))
        chat = source("Apelin/Interface/Chats/ChatController.swift")
        self.assertIn("ConversationNotices.shared.visibleChat = self", block(chat, "override func viewDidAppear"))
        self.assertIn("ConversationNotices.shared.visibleChat = nil", block(chat, "override func viewWillDisappear"))
        session = block(chat, "var notificationSessionID:")
        self.assertIn("presentedViewController == nil", session)
        self.assertIn("runtime.records[chat.id]?.sessionID", session)

    def test_sender_filters_before_system_delivery(self):
        poster = source("Apelind/Session/Notice/NoticePoster.swift")
        post = block(poster, "func post(_ notice:")
        self.assertLess(post.index("ViewedConversation.shouldSuppress"), post.index("UNMutableNotificationContent()"))
        self.assertIn("content.threadIdentifier = notice.sessionID", post)
        notices = source("Apelind/Session/Notice/AgentNotices.swift")
        relayed = block(notices, "func relayed(")
        self.assertLess(relayed.index("marks[session] = advanced"), relayed.index("post(notice)"))

    def test_viewed_session_lease_is_ephemeral_and_fails_open(self):
        viewed = source("Packages/ApelinKit/Sources/ApelinCore/ViewedConversation.swift")
        self.assertIn("foreground & 5 == 5", viewed)
        self.assertIn("foreground >> 32 == processID", viewed)
        self.assertIn("age >= 0 && age < Double(leaseSeconds)", viewed)
        self.assertIn("readState(name) == first", viewed)
        self.assertIn("kill(pid, 0) == 0", viewed)
        self.assertNotIn("UserDefaults", viewed)
        self.assertNotIn("write(to:", viewed)
        delegate = source("Apelin/Application/ConversationNotices.swift")
        self.assertIn("didSet { refreshViewedConversation() }", delegate)
        self.assertIn("notify_set_state(viewedToken, 0)", delegate)
        self.assertIn("Timer(timeInterval: 1, repeats: true)", delegate)
        chat = source("Apelin/Interface/Chats/ChatController.swift")
        self.assertIn("refreshViewedConversation()", block(chat, "func use(_ chat:"))
        self.assertIn("refreshViewedConversation()", block(chat, "func refreshRuntime()"))

    def test_app_fallback_reads_current_bridge_state(self):
        visible = block(self.app, "static var isActuallyVisible:")
        self.assertIn("notify_get_state(statusToken, &current)", visible)
        self.assertIn("current >> 32", visible)
        self.assertIn("return current & 4 != 0", visible)
        self.assertIn("let wasVisible = hasFreshStatus && status & 5 == 5", self.app)

    def test_swift_matching_rule_on_xcode_host(self):
        import shutil
        import subprocess
        import tempfile
        if not shutil.which("xcrun"):
            self.skipTest("本机缺少 Xcode；Swift 规则执行需在 macOS harness 补验")
        delegate = source("Apelin/Application/ConversationNotices.swift")
        rule = block(delegate, "nonisolated static func suppressesViewedConversation")
        program = '''
func suppressesViewedConversation(notificationSession: String, visibleSession: String?, actuallyVisible: Bool) -> Bool {
''' + rule + '''
}
for visible in [false, true] {
    for current: String? in [nil, "", "current", "other"] {
        for notice in ["", "current", "other"] {
            let expected = visible && current != nil && current != "" && notice == current
            precondition(suppressesViewedConversation(notificationSession: notice, visibleSession: current, actuallyVisible: visible) == expected)
        }
    }
}
print("通过：24组当前会话、其他会话、不可见、未知会话的生产 Swift 规则")
'''
        scratch = ROOT / ".build"
        scratch.mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(prefix="notice-rule-", dir=scratch) as temp:
            path = Path(temp)
            (path / "main.swift").write_text(program, encoding="utf-8")
            subprocess.run(["xcrun", "--sdk", "macosx", "swiftc", "-swift-version", "5", str(path / "main.swift"), "-o", str(path / "check")], check=True)
            subprocess.run([str(path / "check")], check=True)

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

    def test_settings_entry_and_independent_options(self):
        settings = source("Apelin/Interface/Settings/SettingsViewController.swift")
        self.assertIn("case .background: [.foregroundBackground]", settings)
        self.assertNotIn("[.foregroundBackground, .weChat]", settings)
        page = source("Apelin/Interface/Settings/ForegroundBackgroundController.swift")
        self.assertNotIn("case .license", page)
        for option in ("locked", "indicators", "lockIndicator"):
            self.assertIn("ForegroundBackground." + option, page)
            self.assertIn('forKey: "foregroundBackground.' + option + '"', self.app)
        self.assertIn("APFRefreshContainers();", self.module)
        self.assertIn("APFRefreshMarks();", self.module)

    def test_background_cards_and_matching_footers(self):
        page = source("Apelin/Interface/Settings/ForegroundBackgroundController.swift")
        self.assertIn("numberOfSections(in _: UITableView) -> Int { Row.allCases.count }", page)
        self.assertIn("numberOfRowsInSection _: Int) -> Int { 1 }", page)
        self.assertIn("Row(rawValue: indexPath.section)", page)
        self.assertIn("IndexPath(row: 0, section: $0.rawValue)", page)
        footer = block(page, "titleForFooterInSection section:")
        for row in ("enabled", "notifications", "locked", "indicators", "lockIndicator", "status", "protectionStatus"):
            self.assertIn("case ." + row + ":", footer)
        self.assertIn("未开启后台保活", footer)
        self.assertIn("任务进度实时活动与灵动岛实时显示", footer)
        self.assertNotIn("开源许可见设置", page)

    def test_provider_note_has_own_trailing_label_and_reserved_menu(self):
        page = source("Apelin/Interface/Settings/Accounts/ModelProvidersController.swift")
        self.assertNotIn("func providerTitle", page)
        self.assertIn("cell.accessoryView = menuButton(account)", page)
        self.assertIn("width: 32, height: 44", block(page, "private func menuButton"))
        row = block(page, "private final class ProviderAccountCell")
        for requirement in ("heading.alignment = .firstBaseline", "heading.addArrangedSubview(noteLabel)",
                            "title.setContentHuggingPriority(.defaultLow", "noteLabel.setContentHuggingPriority(.defaultHigh",
                            "multiplier: 0.45", "noteLabel.lineBreakMode = .byTruncatingTail",
                            "contentView.layoutMarginsGuide", "row.trailingAnchor.constraint(equalTo: margins.trailingAnchor)"):
            self.assertIn(requirement, row)
        self.assertNotIn("accessoryView =", row)
        self.assertEqual(row.count("adjustsFontForContentSizeCategory = true"), 3)

    def test_lock_mark_is_only_icon(self):
        name = block(self.module, "static id APFDisplayName")
        self.assertIn('stringByAppendingString:@" 🔒"', name)
        self.assertNotIn("已锁定", name)

    def test_unified_license_is_reviewed_and_gpl_gate_stays_closed(self):
        import copy
        import importlib.util
        import json
        spec = importlib.util.spec_from_file_location("license_collector", ROOT / "Scripts/collect-licenses.py")
        collector = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(collector)
        entries = collector.standalone_entries(str(ROOT))
        review = json.loads(source("Licenses/review.json"))
        review["binaryRevisions"] = {}
        review["notices"] = {item["id"]: review["notices"][item["id"]] for item in entries}
        review["gplExceptions"] = {item["id"]: review["gplExceptions"][item["id"]] for item in entries}
        collector.validate_review(review, [], entries)
        self.assertIn("Version 3", entries[0]["text"])
        self.assertIn("Serge Alagon", entries[0]["name"])
        changed = copy.deepcopy(entries)
        changed[0]["text"] += "changed"
        with self.assertRaises(SystemExit):
            collector.validate_review(review, [], changed)
        unknown = copy.deepcopy(entries)
        unknown[0]["id"] = "linked/unreviewed"
        review["notices"]["linked/unreviewed"] = review["notices"].pop(entries[0]["id"])
        review["gplExceptions"] = {}
        with self.assertRaises(SystemExit):
            collector.validate_review(review, [], unknown)

    def test_license_is_preserved_without_linking_into_app(self):
        self.assertIn("SPDX-License-Identifier: GPL-3.0-or-later", self.module)
        self.assertIn("Serge Alagon", self.module)
        self.assertIn("Version 3", source("Background/LICENSE"))
        project = source("Apelin.xcodeproj/project.pbxproj")
        self.assertNotIn("ApelinForeground.m", project)
        self.assertNotIn("Background/", project)


if __name__ == "__main__":
    unittest.main()
