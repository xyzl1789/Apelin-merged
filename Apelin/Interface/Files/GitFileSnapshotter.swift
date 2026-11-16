import ApelinProtocol
import Foundation

/// 文件编辑器的 Git 快照：第一次保存覆盖前，把这个文件编辑前的内容
/// 作为一次提交留在 Git 里，之后在 Git 页里随时可以取回。
///
/// 只在知道所属项目（能给出 `projectID`，且文件就在它的仓库里）时启用；
/// 其余场合快照器为 nil，编辑器照旧直接写。快照是静默的：仓库不存在、
/// 文件未改动、无作者身份，都只是不拍，绝不打扰编辑。
@MainActor
final class GitFileSnapshotter {
    private let scopeID: String
    private let path: String
    /// 拍过就不再拍：一次编辑会话只留一次底。
    private var taken = false

    init(scopeID: String, path: String) {
        self.scopeID = scopeID
        self.path = path
    }

    /// 拍快照：把该文件的当前工作区内容提交到 Git。整个提交只装这一个
    /// 文件，先暂存它，提交完把它从暂存区退出，免得打乱读者自己的暂存。
    func takeOnce() async {
        guard !taken else { return }
        taken = true
        do {
            let status = try await ApelinService.app.gitStatus(projectID: scopeID)
            // 文件得在仓库里且确有改动；没改动的文件无需留底。
            guard let entry = status.entries.first(where: { $0.path == path }),
                  entry.worktree != " "
            else { return }
            try await ApelinService.app.gitStage(projectID: scopeID, paths: [path])
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd HH:mm"
            let stamp = formatter.string(from: Date())
            _ = try await ApelinService.app.gitCommit(GitCommitRequest(
                projectID: scopeID,
                message: "snapshot: \(path) before edit (\(stamp))",
            ))
            try? await ApelinService.app.gitUnstage(projectID: scopeID, paths: [path])
        } catch {
            // 静默失败：仓库没有身份、不是仓库、临时失败，都不拦编辑。
        }
    }
}
