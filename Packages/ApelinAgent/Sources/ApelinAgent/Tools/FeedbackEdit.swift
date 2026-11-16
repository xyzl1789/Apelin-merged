import enum ApelinProtocol.FeedbackRules
import CryptoKit
import Foundation
import KWWKAI

/// apelin_feedback_read and apelin_feedback_edit (owner, 2026-10-30): an
/// issue on Apelin's own repository read, and one the user's GitHub account
/// opened there changed, rather than filed again. The edit names the
/// revision of the read it was made against; before anyone is asked the
/// tool reads the issue again and refuses an edit of another account's
/// issue, of an issue that changed since that read (the user may have
/// edited it on GitHub), one that changes nothing, and text `FeedbackRules`
/// refuses. The card then names the issue and the whole new text, and
/// apelin-environment writes it only while the issue still says what this
/// read saw, keeping its footer.
enum FeedbackEdit {
    static let numberKey = "number"
    static let revisionKey = "revision"

    /// A short name for an issue's title and body as one read saw them.
    static func revision(title: String, body: String) -> String {
        let data = (try? JSONEncoder().encode([title, body])) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// The issue a call names.
    static func number(_ arguments: JSONValue) throws -> Int {
        guard let number = arguments.argInt(numberKey), number >= 1 else {
            throw ToolArgumentError("请按 \(FeedbackRules.repository) 上的编号指名议题，例如 12。")
        }
        return number
    }

    /// What the card names, from the issue as it was just read; refused,
    /// with what to do, when no edit could be made.
    static func approval(for arguments: JSONValue, issue: FeedbackReadToolResponse) throws -> FeedbackEditApproval {
        guard issue.openedByUser else {
            throw ToolDeniedError(message: "未做更改：#\(issue.issue) 由 \(issue.author) 打开，而非用户的 GitHub 账户，只有该账户打开的议题才能编辑。用户可以在 GitHub 上评论它。")
        }
        guard let revision = arguments.argNonEmptyString(revisionKey) else {
            throw ToolArgumentError("未做更改：请先用 apelin_feedback_read 读取议题，并传入它返回的 revision。")
        }
        guard revision == issue.revision else {
            throw ToolDeniedError(message: "未做更改：自读取该版本后 #\(issue.issue) 在 GitHub 上已变化（可能被用户修改）。请用 apelin_feedback_read 重新读取，保留那里的更改，并在再次询问前向用户展示基于当前内容的编辑。")
        }
        let title = arguments.argString("title").map { $0.trimmingCharacters(in: .whitespaces) }
        let body = arguments.argString("body")
        let newTitle = title == issue.title ? nil : title
        let newBody = body == issue.body ? nil : body
        if let problem = FeedbackRules.editProblem(title: newTitle, body: newBody) {
            throw ToolArgumentError("未做更改：\(problem).")
        }
        return FeedbackEditApproval(
            repository: issue.repository,
            number: issue.issue,
            url: issue.url,
            title: newTitle,
            body: newBody,
            currentTitle: issue.title,
            currentBody: issue.body,
        )
    }
}
