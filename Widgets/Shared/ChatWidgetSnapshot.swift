import Foundation
import SwiftUI

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
            status == .working || status == .waiting
        }

        var link: URL {
            ApelinLink.conversation(id).url
        }
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
    /// 仅实时活动携带的单行回答预览，不写进主屏小组件的快照。
    var answerPreview: String?
    /// 某个会话刚完成或失败时的短暂提示；不计入进行中数量。
    var transientResult: Chat?
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
        workingCount = chats.count { $0.chat.status == .working }
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
        if var notice = result.transientResult {
            notice.title = Self.activityText(notice.title, bytes: 160)
            notice.project = notice.project.map { Self.activityText($0, bytes: 120) }
            result.transientResult = notice
        }
        if let tool = result.currentTool {
            result.currentTool = .init(symbol: Self.activityText(tool.symbol, bytes: 64), title: Self.activityText(tool.title, bytes: 180))
        }
        // JSON 转义可能把每字节放大六倍；最后的兜底仍保留会话和状态。
        if !fits(result) {
            result.answerPreview = nil
            result.currentTool = nil
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
        case .working: 1
        case .done, .failed: 2
        }
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

