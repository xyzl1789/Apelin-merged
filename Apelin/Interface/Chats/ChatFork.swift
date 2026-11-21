import ApelinProtocol
import Foundation

/// 只记录尚未完成首次布局的会话 UUID；旧加载的完成不能清除新加载标记。
enum ChatOpeningRecovery {
    private static let key = "chat.openingID"

    static func pending(in defaults: UserDefaults = .standard) -> UUID? {
        defaults.string(forKey: key).flatMap(UUID.init(uuidString:))
    }

    static func begin(_ id: UUID, in defaults: UserDefaults = .standard) {
        defaults.set(id.uuidString, forKey: key)
    }

    static func finish(_ id: UUID, in defaults: UserDefaults = .standard) {
        guard pending(in: defaults) == id else { return }
        defaults.removeObject(forKey: key)
    }
}

/// Helpers for a conversation created from a sealed model snapshot. The fork
/// worker replays its new session log and marks those records in the event
/// payload; the marker is deliberately not a protocol field.
enum ChatFork {
    /// Empty saved forks still need their worker's replay; a draft with no
    /// session must not open a worker just because its page was selected.
    static func needsHistoryLoad(_ record: ChatRecord, isFollowed: Bool) -> Bool {
        record.sessionID != nil && !isFollowed
    }
    static func isHistorical(_ event: TaskEvent) -> Bool {
        event.payload?["historical"]?.boolValue == true
    }
}
