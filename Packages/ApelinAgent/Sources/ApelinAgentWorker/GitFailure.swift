import ApelinAgent
import ApelinProtocol
import Foundation

/// A git refusal in words the model can act on and pass on to the user.
enum GitFailure {
    /// `ApelinError.description` is `<code>: <message>`, which is how a
    /// task's final `state` carries a failure.
    static func split(_ text: String?) -> (ApelinError.Code?, String) {
        guard let text, !text.isEmpty else { return (nil, "") }
        if let colon = text.firstIndex(of: ":"), let code = ApelinError.Code(rawValue: String(text[..<colon])) {
            return (code, text[text.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        if let code = ApelinError.Code(rawValue: text) {
            return (code, "")
        }
        return (nil, text)
    }

    static func describe(
        _ operation: String,
        code: ApelinError.Code?,
        message: String,
        reason: String?,
        host: String?,
        forced: Bool = false,
    ) -> GitToolFailure {
        let detail = message.isEmpty ? (code?.rawValue ?? "no reason given") : message
        var text = "\(forced ? "forced " : "")\(operation) failed: \(detail)"
        if !text.hasSuffix(".") {
            text += "."
        }
        if forced, let hint = forcedHint(code: code, reason: reason) {
            return GitToolFailure(message: text + " " + hint)
        }
        if let hint = hint(operation, code: code, message: message, reason: reason, host: host) {
            text += " " + hint
        }
        return GitToolFailure(message: text)
    }

    static func isAuthentication(_ message: String, reason: String?) -> Bool {
        let words = (message + " " + (reason ?? "")).lowercased()
        // Not "auth" alone: a commit's missing author is not a credential.
        return ["authenticat", "authoriz", "credential", "forbidden", "token", "password"].contains { words.contains($0) }
            || words.range(of: #"\b40[13]\b"#, options: .regularExpression) != nil
    }

    private static func hint(
        _ operation: String,
        code: ApelinError.Code?,
        message: String,
        reason: String?,
        host: String?,
    ) -> String? {
        // A reason the host named comes before any guess from the words,
        // which a project's name or a URL could set off.
        if reason == ApelinError.Reason.notARepository.rawValue {
            return "该项目还没有仓库：先用 git_init 创建，再用 git_commit（all: true）提交。"
        }
        if reason == ApelinError.Reason.noSuchRemote.rawValue {
            guard operation == "git push" else {
                return "项目没有该名称的远程：git_remote_list 列出现有远程，git_remote_set 按用户给出的地址添加。"
            }
            return "项目还没有这样的远程：询问用户是否用 apelin_git_create_repository 为它创建 GitHub 仓库（用哪个所有者、名称和可见性），或请用户提供他们创建的空仓库（无 README、许可或 .gitignore）的 HTTPS 地址；然后用带 url 的 git_push 推送。"
        }
        if reason == ApelinError.Reason.headChanged.rawValue {
            return "在用户看到将要合并的内容后分支又变了，因此没有压缩。请告知用户；若仍要压缩，再次调用 git_squash，它会重新读取提交并再次询问。"
        }
        if reason == ApelinError.Reason.remoteURLDiffers.rawValue {
            // The message says where the remote points and what to do instead.
            return nil
        }
        if isAuthentication(message, reason: reason) {
            if host == "github.com" {
                return "远程需要 Apelin 没有的 github.com 凭据，或拒绝了已保存的凭据：请让用户在设置 ▸ Git 里用 Sign In with GitHub 登录后重试。"
            }
            let place = host.map { "for \($0) " } ?? ""
            return "远程需要 Apelin 没有的凭据，或拒绝了已保存的凭据：请让用户提供令牌 \(place)并用 apelin_git_save_credential 保存后重试。"
        }
        if operation == "git commit", message.lowercased().contains("author") {
            return "请让用户在设置 ▸ Git 中设置提交作者。"
        }
        guard code == .conflict else { return nil }
        switch operation {
        case "git pull":
            return "pull 只做快进：分支已与其上游分叉，或有本地更改挡路。请告知用户；不要强行推送。"
        case "git push":
            return "远程有本分支没有的提交。请先 fetch 并 pull（pull 只做快进），再在用户同意下 merge 或 rebase。推送被拒绝绝不是强推的理由：force_with_lease 只用于用户明确要求的强制推送。"
        case "git reset to remote":
            return "未做更改。请再次调用 git_reset_to_remote，让用户看到现在会丢弃什么并重新决定。"
        case "git clone":
            return "工作区已有仓库，或存在与仓库同名的文件。请告知用户，不要删除他们的文件来腾位置。"
        default:
            return nil
        }
    }

    /// A forced push's refusal: the lease that did not hold, or the
    /// remote's own no. Nothing was pushed either way.
    private static func forcedHint(code: ApelinError.Code?, reason: String?) -> String? {
        switch reason {
        case ApelinError.Reason.remoteChanged.rawValue:
            return "在用户批准覆盖后远程分支又变了，因此没有推送。请告知用户它现在的状态；若仍要覆盖，再次调用 git_push 并带 force_with_lease，它会重新拉取并以当前将丢失的内容再次询问。"
        case ApelinError.Reason.localChanged.rawValue:
            return "在用户批准强制推送后分支又变了，因此没有推送。请告知用户；若仍要推送，再次调用 git_push 并带 force_with_lease，它会以当前提交再次询问。"
        default:
            guard code == .conflict else { return nil }
            return "远程以原话拒绝了强制推送，什么都没有推送：比如受保护分支只能由用户在远程更改。请告知用户是什么在阻止，绝不要绕过它。"
        }
    }
}
