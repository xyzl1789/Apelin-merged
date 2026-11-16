import ApelinProtocol
import Foundation

extension Notification.Name {
    /// Posted when a conversation's automatic-assistant settings change, so
    /// the menu that shows them and an open conversation both refresh.
    static let autoAssistantPolicyChanged = Notification.Name("wiki.qaq.apelin.autoAssistantPolicyChanged")
}

/// The automatic assistant as a conversation's own setting rather than the
/// app's: the reader turns it on for the conversation they are in, from the
/// conversation's own menu, and it applies to that conversation's sends only.
///
/// A conversation an agent opened — a subagent's, or one started from another
/// conversation — follows the conversation that opened it unless it was given
/// settings of its own: switching the reader's conversation is the whole point
/// of the switch, and a subagent of it must not keep failing on the model that
/// failed.
enum AutoAssistantPolicy {
    /// The two automatic behaviours, each off until the reader turns it on.
    struct Settings: Codable, Equatable, Sendable {
        /// 失败（额度、限流、服务端错误、超时）后换一个模型重发。
        var switchOnFailure = false
        /// 超时后等一会儿用同一个模型重试。
        var retryOnTimeout = false

        /// Nothing automatic: what a conversation that never turned one on has.
        static let off = Settings()
    }

    private static let prefix = "autoAssistant.conversation."

    private static func key(_ id: UUID) -> String {
        prefix + id.uuidString
    }

    /// `id`'s own settings: its own when it has any written, else the ones of
    /// the conversation that opened it, followed up the chain. A conversation
    /// nothing was ever set for has them off.
    static func settings(for id: UUID, parents: [UUID: UUID?] = [:], defaults: UserDefaults = .standard) -> Settings {
        var seen: Set<UUID> = []
        var current: UUID? = id
        while let conversation = current, seen.insert(conversation).inserted {
            if let data = defaults.data(forKey: key(conversation)),
               let stored = try? JSONDecoder().decode(Settings.self, from: data)
            {
                return stored
            }
            current = parents[conversation] ?? nil
        }
        return .off
    }

    static func set(_ settings: Settings, for id: UUID, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key(id))
        NotificationCenter.default.post(name: .autoAssistantPolicyChanged, object: id)
    }

    /// A conversation copied into another — a branch — is that conversation
    /// continued, so it keeps what it was set to.
    static func inherit(from parent: UUID, into child: UUID, defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: key(parent)) else { return }
        defaults.set(data, forKey: key(child))
        NotificationCenter.default.post(name: .autoAssistantPolicyChanged, object: child)
    }

    /// The conversation shown and never written in keeps nothing: started
    /// again it is a new one and takes its opener's settings, if any.
    static func forget(_ id: UUID, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(id))
        NotificationCenter.default.post(name: .autoAssistantPolicyChanged, object: id)
    }

    // MARK: - The chain a conversation inherits along

    /// Which conversation opened which, for the ones the app holds. Reads each
    /// record's `parentChatID`, which is the conversation, not the host
    /// session: a subagent opened from a chat points back at it.
    static func parents(of chats: [ChatSummary]) -> [UUID: UUID?] {
        var parents: [UUID: UUID?] = [:]
        for chat in chats {
            parents[chat.id] = chat.parentChatID
        }
        return parents
    }

    /// `id`'s settings, looked up along the chain the open conversations
    /// describe. A chat whose opener the app holds inherits from it.
    @MainActor
    static func current(for id: UUID) -> Settings {
        let records = ChatRuntime.active?.records ?? [:]
        return settings(for: id, parents: parents(of: records.values.map(\.summary)))
    }
}
