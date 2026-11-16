import enum ApelinProtocol.AgentNoticeRules
import Foundation
import KWWKAI

/// `apelin_notification_send`'s rules on the agent's side: the notice as the host will
/// post it, and how many this turn may still send. The session host
/// decides again from the `notice` event (`AgentNoticeTrack`); these are
/// checked first so the model hears why one was not sent, rather than
/// believing the user was told.
struct UserNotices {
    private var sentThisTurn = 0
    private var lastSent: Date?

    /// The notice to record, plain and within the lengths, or why not.
    /// Counted as sent once it passes, before it is recorded.
    mutating func take(_ arguments: JSONValue, now: Date) throws -> (title: String?, body: String) {
        guard let body = try AgentNoticeRules.plain(arguments.requireString("body")) else {
            throw ToolArgumentError("正文为空：请用一句话说明发生了什么或用户需要做什么")
        }
        guard body.count <= AgentNoticeRules.maximumBodyLength else {
            throw ToolArgumentError("正文有 \(body.count) 个字符；不超过 \(AgentNoticeRules.maximumBodyLength)，一到两个平实句子")
        }
        let title = AgentNoticeRules.plain(arguments.argString("title"))
        if let title, title.count > AgentNoticeRules.maximumTitleLength {
            throw ToolArgumentError("标题有 \(title.count) 个字符；不超过 \(AgentNoticeRules.maximumTitleLength)（几个词），或省略")
        }
        guard sentThisTurn < AgentNoticeRules.maximumPerTurn else {
            throw ToolDeniedError(message: "未发送：本轮已发出 \(AgentNoticeRules.maximumPerTurn) 条通知，已达上限。其余内容请写进回复；回合结束时 Apelin 会通知用户。")
        }
        if let lastSent, now.timeIntervalSince(lastSent) < AgentNoticeRules.minimumInterval {
            let seconds = Int(AgentNoticeRules.minimumInterval)
            throw ToolDeniedError(message: "未发送：上一条通知发出还不到 \(seconds) 秒，两条通知至少间隔 \(seconds) 秒。请把它并入下一条通知或你的回复。")
        }
        sentThisTurn += 1
        lastSent = now
        return (title, body)
    }

    /// A new turn may send its own few.
    mutating func turnEnded() {
        sentThisTurn = 0
    }

    /// What the model reads once the notice is recorded.
    var sentMessage: String {
        let left = AgentNoticeRules.maximumPerTurn - sentThisTurn
        return "Sent to Apelin as a notification. It shows only while Apelin is not in front and the user allows its notifications, and nothing tells you whether they saw it. \(left) more may go this turn."
    }
}
