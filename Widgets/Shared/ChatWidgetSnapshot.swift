import Foundation
import SwiftUI

/// What Apelin shows beside a running turn: the same semantic stage and SF
/// Symbol as the conversation detail rows.
struct ChatWidgetProgress: Codable, Hashable, Sendable {
    enum Stage: String, Codable, Hashable, Sendable {
        case thinking, tool, replying
        /// 这一轮正在重新连上模型服务；请求还没发出去。
        case reconnecting
        /// 请求失败了，正在等网络回来。
        case waitingForNetwork
        /// 压缩上下文。
        case compacting
        /// 已完成当前工具，等待下一阶段事件。
        case waitingForNextStep
        /// 已请求停止，host 还没确认。
        case stopping
    }

    let stage: Stage
    let symbol: String
    let title: String
    /// Thinking text is the actual streamed reasoning, not a placeholder.
    let detail: String?

    /// 还没连上、已完成当前步骤或正在停止时，先前的工具行和回答预览不该盖住这个状态。
    var hidesToolAndPreview: Bool {
        switch stage {
        case .reconnecting, .waitingForNetwork, .waitingForNextStep, .stopping: true
        case .thinking, .tool, .replying, .compacting: false
        }
    }
}

/// The shared icon families used by `ChatToolCallRow` in the transcript.
///
/// The widgets cannot reach `ApelinProtocol`, so the mapping is by the tool's
/// recorded name (current names and the earlier releases' legacy names),
/// keeping the same SF Symbol per family the detail rows draw.
enum ChatWidgetToolStyle {
    static func symbol(for name: String?) -> String {
        guard let name, let tool = symbols[name] else { return "wrench.and.screwdriver" }
        return tool
    }

    private static let symbols: [String: String] = {
        var map: [String: String] = [:]
        for name in gitNames { map[name] = "arrow.triangle.branch" }
        register(fileReadNames, "doc.text.magnifyingglass", into: &map)
        register(fileWriteNames, "square.and.pencil", into: &map)
        register(buildNames, "hammer", into: &map)
        register(packageNames, "shippingbox", into: &map)
        register(screenNames, "iphone", into: &map)
        register(logNames, "text.alignleft", into: &map)
        register(crashNames, "exclamationmark.triangle", into: &map)
        register(memoryNames, "externaldrive", into: &map)
        register(skillNames, "book", into: &map)
        register(conversationNames, "bubble.left.and.bubble.right", into: &map)
        register(webNames, "globe", into: &map)
        register(todoNames, "checklist", into: &map)
        for (name, symbol) in miscNames { map[name] = symbol }
        for (legacy, current) in legacyNames { map[legacy] = map[current] ?? defaultSymbol }
        return map
    }()

    private static let gitNames: [String] = [
        "git_status", "git_diff", "git_log", "git_commit_detail", "git_branches",
        "git_stage", "git_unstage", "git_commit", "git_init", "git_branch_create",
        "git_branch_checkout", "git_branch_rename", "git_merge", "git_merge_abort",
        "git_fetch", "git_pull", "git_push", "git_clone", "git_squash",
        "git_remote_set", "git_remote_remove", "git_reset_to_remote",
        "git_tag", "git_stash", "git_restore", "git_clean", "git_remote_list",
        "apelin_git_read_settings", "apelin_git_set_author", "apelin_git_save_credential",
        "apelin_git_remove_credential", "apelin_git_create_repository", "apelin_git_create_issue",
    ]

    /// Names of the tools the detail rows map to the remaining symbols, by family.
    private static let fileReadNames = ["file_read", "file_list", "file_grep", "file_find", "file_show"]
    private static let fileWriteNames = ["file_write", "file_edit", "file_create"]
    private static let buildNames = ["apelin_project_build", "apelin_toolchain_self_test"]
    private static let packageNames = ["apelin_package_install", "apelin_package_remove", "apelin_package_list",
                                       "apelin_package_publish", "apelin_package_release", "apelin_package_confirm_loaded"]
    private static let screenNames = ["apelin_screen_capture", "apelin_screen_read_tree", "apelin_screen_interact",
                                      "apelin_device_respring"]
    private static let logNames = ["apelin_log_read"]
    private static let crashNames = ["apelin_crash_list", "apelin_crash_read", "apelin_crash_symbolicate"]
    private static let memoryNames = ["apelin_memory_list", "apelin_memory_save", "apelin_memory_delete"]
    private static let skillNames = ["apelin_skill_list", "apelin_skill_read", "apelin_skill_save", "apelin_skill_remove"]
    private static let conversationNames = ["apelin_conversation_create", "apelin_conversation_send",
                                            "apelin_conversation_list", "apelin_conversation_read",
                                            "apelin_conversation_stop"]
    private static let webNames = ["web_search", "apelin_web_fetch"]
    private static let todoNames = ["apelin_todo_list", "apelin_todo_write", "apelin_conversation_plan"]
    private static let miscNames: [String: String] = [
        "apelin_notification_send": "bell",
        "apelin_conversation_compact": "rectangle.compress.vertical",
        "apelin_question_ask": "questionmark.bubble",
        "apelin_run_mode": "slider.horizontal.3",
        "apelin_feedback_send": "exclamationmark.bubble",
        "apelin_feedback_read": "exclamationmark.bubble",
        "apelin_feedback_edit": "exclamationmark.bubble",
        "apelin_template_list": "square.grid.2x2",
        "apelin_project_list": "square.grid.2x2",
        "apelin_project_create": "square.grid.2x2",
        "apelin_project_rename": "square.grid.2x2",
        "apelin_project_delete": "square.grid.2x2",
        "apelin_project_check_distribution": "square.grid.2x2",
        "apelin_project_set_environment": "square.grid.2x2",
        "apelin_toolchain_list": "gearshape.2",
        "apelin_sdk_list": "gearshape.2",
        "apelin_toolchain_setup": "gearshape.2",
        "apelin_sdk_import": "gearshape.2",
        "apelin_sdk_analyze_framework": "gearshape.2",
        "apelin_sdk_read_header": "gearshape.2",
        "shell_run": "terminal",
    ]

    private static let defaultSymbol = "wrench.and.screwdriver"

    private static let legacyNames: [String: String] = [
        "write_file": "file_write",
        "patch_file": "file_edit",
        "create_file": "file_create",
        "read_file": "file_read",
        "list": "file_list",
        "grep": "file_grep",
        "find": "file_find",
        "run_code": "shell_run",
        "analyze_framework": "apelin_sdk_analyze_framework",
        "framework_header": "apelin_sdk_read_header",
        "build": "apelin_project_build",
        "install": "apelin_package_install",
        "remove_package": "apelin_package_remove",
        "respring": "apelin_device_respring",
        "confirm_loaded": "apelin_package_confirm_loaded",
        "read_logs": "apelin_log_read",
        "list_crashes": "apelin_crash_list",
        "read_crash": "apelin_crash_read",
        "symbolicate_crash": "apelin_crash_symbolicate",
        "capture_screen": "apelin_screen_capture",
        "read_ui_tree": "apelin_screen_read_tree",
        "ui_action": "apelin_screen_interact",
        "memory_list": "apelin_memory_list",
        "memory_save": "apelin_memory_save",
        "memory_delete": "apelin_memory_delete",
        "read_skill": "apelin_skill_read",
        "notify_user": "apelin_notification_send",
        "check_distribution": "apelin_project_check_distribution",
        "project_template_list": "apelin_template_list",
        "project_create": "apelin_project_create",
        "git_settings": "apelin_git_read_settings",
        "git_set_author": "apelin_git_set_author",
        "git_save_credential": "apelin_git_save_credential",
        "git_remove_credential": "apelin_git_remove_credential",
        "conversation_create": "apelin_conversation_create",
        "conversation_send": "apelin_conversation_send",
        "conversation_list": "apelin_conversation_list",
        "conversation_read": "apelin_conversation_read",
        "conversation_stop": "apelin_conversation_stop",
        "conversation_plan": "apelin_conversation_plan",
        "toolchain_list": "apelin_toolchain_list",
        "sdk_list": "apelin_sdk_list",
        "toolchain_setup": "apelin_toolchain_setup",
        "sdk_import": "apelin_sdk_import",
        "toolchain_self_test": "apelin_toolchain_self_test",
        "project_environment_set": "apelin_project_set_environment",
    ]

    private static func register(_ names: [String], _ symbol: String, into map: inout [String: String]) {
        for name in names { map[name] = symbol }
    }
}

/// What the widgets show of the conversations, written by the app and read
/// by the widget extension; the Live Activity's payload is the same shape,
/// cut to the conversations in progress.
///
/// Everything in it is ready to draw: the extension cannot reach the app's
/// model, so the app resolves the status, the project's display name and
/// the order before it writes. Streamed replies only update the Live Activity;
/// the home-screen widget snapshot does not include them.
struct ChatWidgetSnapshot: Codable, Hashable, Sendable {
    struct ToolActivity: Codable, Hashable, Sendable {
        let symbol: String
        let title: String
    }

    struct Chat: Codable, Hashable, Sendable, Identifiable {
        enum Status: String, Codable, Hashable, Sendable {
            /// A turn is running.
            case working
            /// A turn is stopping and the host has not confirmed the end.
            case stopping
            /// A turn is running and waits for the user's approval.
            case waiting
            /// The last turn ended, or none ran yet.
            case done
            /// The last turn failed.
            case failed
        }

        /// The app's chat ID, which `apelin://conversation/<id>` opens.
        var id: String
        var title: String
        /// The project's display name; nil for General Chat.
        var project: String?
        var status: Status
        /// The tool the newest waiting approval is for (`apelin_package_install`,
        /// `git_push`, …), for the status line to name.
        var approvalTool: String?
        /// 本回合（当前正在跑的任务）开始时刻：实时活动上的进行时长计时器
        /// 从它起走；不在回合中为 nil。
        var startedAt: Date?

        var isInProgress: Bool {
            status == .working || status == .stopping || status == .waiting
        }

        var link: URL {
            ApelinLink.conversation(id).url
        }
    }

    private enum CodingKeys: String, CodingKey {
        case chats, totalCount, inProgressCount, workingCount, waitingCount
        case currentTool, progress, answerPreview, transientResult, batchOutcome
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        chats = try container.decodeIfPresent([Chat].self, forKey: .chats) ?? []
        totalCount = try container.decodeIfPresent(Int.self, forKey: .totalCount) ?? chats.count
        inProgressCount = try container.decodeIfPresent(Int.self, forKey: .inProgressCount) ?? 0
        workingCount = try container.decodeIfPresent(Int.self, forKey: .workingCount) ?? 0
        waitingCount = try container.decodeIfPresent(Int.self, forKey: .waitingCount) ?? 0
        currentTool = try container.decodeIfPresent(ToolActivity.self, forKey: .currentTool)
        progress = try container.decodeIfPresent(ChatWidgetProgress.self, forKey: .progress)
        answerPreview = try container.decodeIfPresent(String.self, forKey: .answerPreview)
        transientResult = try container.decodeIfPresent(ResultNotice.self, forKey: .transientResult)
        batchOutcome = try container.decodeIfPresent(BatchOutcome.self, forKey: .batchOutcome)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(chats, forKey: .chats)
        try container.encode(totalCount, forKey: .totalCount)
        try container.encode(inProgressCount, forKey: .inProgressCount)
        try container.encode(workingCount, forKey: .workingCount)
        try container.encode(waitingCount, forKey: .waitingCount)
        try container.encodeIfPresent(currentTool, forKey: .currentTool)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(answerPreview, forKey: .answerPreview)
        try container.encodeIfPresent(transientResult, forKey: .transientResult)
        try container.encodeIfPresent(batchOutcome, forKey: .batchOutcome)
    }

    /// The conversations to list, the one that most needs a look first.
    var chats: [Chat] = []
    /// Every conversation, listed or not.
    var totalCount = 0
    /// 正在进行的会话数（等待审批 + 工作中）：灵动岛与实时活动卡片上的
    /// 计数用它，已完成（✅/❌）的终态会话不算在内。
    var inProgressCount = 0
    var workingCount = 0
    var waitingCount = 0
    /// 仅实时活动携带，且只保留当前显示的一个会话的工具信息。
    var currentTool: ToolActivity?
    /// 仅实时活动携带的当前阶段；主屏小组件不读取。
    var progress: ChatWidgetProgress?
    /// 仅实时活动携带的单行回答预览，不写进主屏小组件的快照。
    var answerPreview: String?
    /// 某个会话刚完成或失败时的短暂提示；不计入进行中数量。
    struct ResultNotice: Codable, Hashable, Sendable {
        var chat: Chat
        let expiresAt: Date
    }
    var transientResult: ResultNotice?

    /// 应用挂起时由系统触发重绘；过期只隐藏短提示，不隐藏运行进度。
    func forActivityDisplay(isStale: Bool, now: Date = .now) -> Self {
        guard let transientResult,
              isStale || waitingCount > 0 || inProgressCount == 0 || now >= transientResult.expiresAt else { return self }
        var display = self
        display.transientResult = nil
        return display
    }

    /// 只汇总同批运行的会话，终态不再读取历史失败卡片。
    var batchOutcome: BatchOutcome?

    enum BatchOutcome: String, Codable, Hashable, Sendable {
        case succeeded, failed, stopped
    }

    static let empty = ChatWidgetSnapshot()

    /// The most a snapshot lists: more than any widget shows.
    static let listLimit = 8
    /// The most the Live Activity's payload lists, which ActivityKit keeps
    /// to 4 KB; neither of its presentations shows more than three.
    static let activityLimit = 4

    /// `chats`, each with the time the sidebar lists it by (when the reader
    /// last started or wrote in it), put in the order the widgets list
    /// them: waiting for an approval, then working, then the rest, newest
    /// first within each.
    init(chats: [(chat: Chat, updated: Date)], limit: Int = listLimit) {
        let ordered = chats.sorted { lhs, rhs in
            let left = Self.rank(lhs.chat.status), right = Self.rank(rhs.chat.status)
            if left != right {
                return left < right
            }
            if lhs.updated != rhs.updated {
                return lhs.updated > rhs.updated
            }
            return lhs.chat.id < rhs.chat.id
        }
        self.chats = Array(ordered.prefix(max(0, limit)).map(\.chat))
        totalCount = chats.count
        workingCount = chats.count { $0.chat.status == .working || $0.chat.status == .stopping }
        waitingCount = chats.count { $0.chat.status == .waiting }
        inProgressCount = workingCount + waitingCount
    }

    init() {}

    /// What the Live Activity shows: the Live Activity's current chats, with
    /// an optional short-lived result notice kept separately from active counts.
    var inProgress: ChatWidgetSnapshot {
        var activity = self
        activity.chats = Array(chats.prefix(Self.activityLimit))
        activity.totalCount = chats.count
        activity.inProgressCount = inProgressCount
        return activity
    }

    /// 按实际 JSON 字节数留出余量，避免多会话的长标题或项目名让系统拒收
    /// 整份活动。先去掉屏幕不画的尾部行；始终保留首行、计数和跳转目标。
    func fittingActivityPayload() -> Self {
        let budget = 3_500
        let encoder = JSONEncoder()
        func fits(_ value: Self) -> Bool {
            guard let bytes = try? encoder.encode(value) else { return false }
            return bytes.count <= budget
        }

        var result = self
        while !fits(result), result.chats.count > 1 { result.chats.removeLast() }
        if fits(result) { return result }

        if !result.chats.isEmpty {
            result.chats[0].title = Self.activityText(result.chats[0].title, bytes: 240)
            result.chats[0].project = result.chats[0].project.map { Self.activityText($0, bytes: 180) }
            result.chats[0].approvalTool = result.chats[0].approvalTool.flatMap { $0.utf8.count <= 96 ? $0 : nil }
        }
        result.answerPreview = result.answerPreview.map { Self.activityText($0, bytes: 180) }
        if var progress = result.progress {
            progress = .init(
                stage: progress.stage,
                symbol: Self.activityText(progress.symbol, bytes: 64),
                title: Self.activityText(progress.title, bytes: 120),
                detail: progress.detail.map { Self.activityText($0, bytes: 220) },
            )
            result.progress = progress
        }
        if var notice = result.transientResult {
            notice.chat.title = Self.activityText(notice.chat.title, bytes: 120)
            notice.chat.project = nil
            result.transientResult = notice
        }
        if let tool = result.currentTool {
            result.currentTool = .init(symbol: Self.activityText(tool.symbol, bytes: 64), title: Self.activityText(tool.title, bytes: 180))
        }
        // JSON 转义可能把每字节放大六倍；最后的兜底仍保留会话和状态。
        if !fits(result) {
            result.answerPreview = nil
            result.currentTool = nil
            result.progress = result.progress.map {
                .init(stage: $0.stage, symbol: $0.symbol, title: $0.title, detail: nil)
            }
            result.transientResult = nil
            if !result.chats.isEmpty {
                result.chats[0].title = Self.activityText(result.chats[0].title, bytes: 160)
                result.chats[0].project = result.chats[0].project.map { Self.activityText($0, bytes: 120) }
            }
        }
        return result
    }

    private static func activityText(_ text: String, bytes: Int) -> String {
        let suffix = "…"
        var prefix = ""
        var used = 0
        for character in text {
            let size = String(character).utf8.count
            if used + size > bytes - suffix.utf8.count { return prefix + suffix }
            prefix.append(character)
            used += size
        }
        return prefix
    }

    /// The conversation a tap on the Live Activity opens: the one waiting,
    /// else the latest working.
    var mostUrgent: Chat? {
        chats.first
    }

    private static func rank(_ status: Chat.Status) -> Int {
        switch status {
        case .waiting: 0
        case .stopping: 1
        case .working: 2
        case .done, .failed: 3
        }
    }
}

/// 运行中的会话不变；待审批时暂停展示，整批结束时丢弃短提示。
struct ChatActivityResultQueue {
    private var pending: [ChatWidgetSnapshot.Chat] = []
    private var active: ChatWidgetSnapshot.ResultNotice?

    mutating func update(
        ended: [ChatWidgetSnapshot.Chat], runningIDs: Set<String>, waiting: Bool, now: Date
    ) -> ChatWidgetSnapshot.ResultNotice? {
        guard !runningIDs.isEmpty else {
            self = Self()
            return nil
        }
        pending.removeAll { runningIDs.contains($0.id) }
        if let notice = active {
            if runningIDs.contains(notice.chat.id) || now >= notice.expiresAt {
                active = nil
            } else if waiting {
                pending.insert(notice.chat, at: 0)
                active = nil
            }
        }
        for chat in ended where !runningIDs.contains(chat.id) {
            guard active?.chat.id != chat.id, !pending.contains(where: { $0.id == chat.id }) else { continue }
            pending.append(chat)
        }
        guard !waiting else { return nil }
        if active == nil, !pending.isEmpty {
            let index = pending.firstIndex { $0.status == .failed } ?? pending.startIndex
            active = .init(chat: pending.remove(at: index), expiresAt: now.addingTimeInterval(5))
        }
        return active
    }
}

/// Where the snapshot lives: the App Group container both the app and the
/// extension carry (`com.apple.security.application-groups`). The extension
/// is sandboxed and cannot read mobile's Documents, and the app has no
/// container of its own to share.
enum ChatWidgetStore {
    static let appGroup = "group.wiki.qaq.apelin"
    /// The kind WidgetKit reloads after a write.
    static let widgetKind = "wiki.qaq.apelin.chats"

    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent("Widgets", isDirectory: true)
            .appendingPathComponent("chats.json")
    }

    /// The last snapshot written; empty when there is none or it does not read.
    static func read() -> ChatWidgetSnapshot {
        guard let url = fileURL, let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ChatWidgetSnapshot.self, from: data)
        else { return .empty }
        return snapshot
    }

    /// Writes `snapshot` whole, replacing the last; false when there is no
    /// container to write into.
    @discardableResult
    static func write(_ snapshot: ChatWidgetSnapshot) throws -> Bool {
        guard let url = fileURL else { return false }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        return true
    }
}

/// 实时活动卡片的背景：给 `activityBackgroundTint` 一层跟随系统深浅色的
/// 半透明颜色——深色模式半透明黑、浅色模式半透明白——系统把它揉进自带
/// 的毛玻璃材质里，壁纸隐约透出。动态 UIColor 在实时活动的渲染里不随
/// 外观重新求值，所以按视图的 colorScheme 直接选色；tint 只在活动内容
/// 更新时才被系统重画，因此外观变化时发布器会重推一次当前活动
/// （`ChatWidgetPublisher.appearanceChanged`）。
enum ChatWidgetAppearance {
    /// 半透明层的透明度：更透，让壁纸多透出一些。
    static let defaultOpacity: Double = 0.25

    /// 当前深浅色对应的半透明 tint 颜色。暗色黑、亮色白。
    static func backgroundTint(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0, green: 0, blue: 0, opacity: defaultOpacity)
            : Color(red: 1, green: 1, blue: 1, opacity: defaultOpacity)
    }
}

