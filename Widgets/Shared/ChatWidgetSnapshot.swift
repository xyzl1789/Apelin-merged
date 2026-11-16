import Foundation

/// What the widgets show of the conversations, written by the app and read
/// by the widget extension; the Live Activity's payload is the same shape,
/// cut to the conversations in progress.
///
/// Everything in it is ready to draw: the extension cannot reach the app's
/// model, so the app resolves the status, the project's display name and
/// the order before it writes. No date is kept, so a conversation that only
/// streams more text writes nothing and reloads no widget.
struct ChatWidgetSnapshot: Codable, Hashable, Sendable {
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
    var workingCount = 0
    var waitingCount = 0

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
    }

    init() {}

    /// What the Live Activity shows: only the conversations in progress.
    var inProgress: ChatWidgetSnapshot {
        var activity = self
        activity.chats = Array(chats.filter(\.isInProgress).prefix(Self.activityLimit))
        activity.totalCount = workingCount + waitingCount
        return activity
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

/// 锁屏卡片的背景与样式设置：app 在偏好设置里选择，沙盒里的扩展通过写入
/// 快照用的同一个 App Group 默认设置读取——扩展读不到 app 自己的偏好。
enum ChatWidgetAppearance {
    private static let customKey = "widgets.liveActivity.customBackground"
    private static let styleKey = "widgets.liveActivity.cardStyle"

    /// 锁屏卡片的样式。`compact` 是一直沿用的列表；`leaf` 是叶子园：每条
    /// 进行中的对话一片叶子，颜色随状态。
    enum CardStyle: String, CaseIterable, Sendable {
        case compact
        case leaf

        var title: String {
            switch self {
            case .compact: String(localized: "Compact List")
            case .leaf: String(localized: "Leaf Garden")
            }
        }
    }

    /// 一直沿用的底色：黑色半透明盖在系统自带材质之上，壁纸隐约可见，
    /// 文字仍看得清。
    static let defaultOpacity: Double = 0.45

    private static var defaults: UserDefaults? {
        UserDefaults(suiteName: ChatWidgetStore.appGroup)
    }

    /// 开：按 `defaultOpacity` 画自定义底色。关：不传 tint，恢复系统自带
    /// 卡片材质，随壁纸与深浅色自动切换（原版的样子）。
    static var customBackground: Bool {
        get { defaults?.object(forKey: customKey) as? Bool ?? true }
        set {
            defaults?.set(newValue, forKey: customKey)
            defaults?.synchronize()
        }
    }

    /// 锁屏卡片选的样式，缺省是沿用至今的紧凑列表。
    static var cardStyle: CardStyle {
        get { CardStyle(rawValue: defaults?.string(forKey: styleKey) ?? "") ?? .compact }
        set {
            defaults?.set(newValue.rawValue, forKey: styleKey)
            defaults?.synchronize()
        }
    }
}
