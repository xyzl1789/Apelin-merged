import ApelinProtocol
import Foundation

/// Typed calls on the session's project; the worker supplies its own project ID.
public struct GitBranchesToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) { self.context = context }
}

public struct GitBranchCreateToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var name: String
    public var startPoint: String?
    public var checkout: Bool
    public init(context: HostCallContext, name: String, startPoint: String? = nil, checkout: Bool = false) {
        self.context = context
        self.name = name
        self.startPoint = startPoint
        self.checkout = checkout
    }
}

public struct GitBranchCheckoutToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var name: String
    public var remote: String?
    public init(context: HostCallContext, name: String, remote: String? = nil) {
        self.context = context
        self.name = name
        self.remote = remote
    }
}

public struct GitBranchDeleteToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var name: String
    /// The remote whose branch is deleted (`origin`); nil is the local one.
    public var remote: String?
    /// A local branch whose commits HEAD does not hold is refused unless
    /// this is true.
    public var force: Bool
    public init(context: HostCallContext, name: String, remote: String? = nil, force: Bool = false) {
        self.context = context
        self.name = name
        self.remote = remote
        self.force = force
    }
}

public struct GitBranchRenameToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var from: String
    public var to: String
    public init(context: HostCallContext, from: String, to: String) {
        self.context = context
        self.from = from
        self.to = to
    }
}

public struct GitMergeToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var branch: String
    public var noFastForward: Bool
    public init(context: HostCallContext, branch: String, noFastForward: Bool = false) {
        self.context = context
        self.branch = branch
        self.noFastForward = noFastForward
    }
}

public struct GitMergeAbortToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public init(context: HostCallContext) { self.context = context }
}

public struct GitLogToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var limit: Int
    public var skip: Int
    public init(context: HostCallContext, limit: Int = 50, skip: Int = 0) {
        self.context = context
        self.limit = limit
        self.skip = skip
    }
}

public struct GitCommitDetailToolRequest: Sendable, Hashable, Codable {
    public var context: HostCallContext
    public var commit: String
    public init(context: HostCallContext, commit: String) {
        self.context = context
        self.commit = commit
    }
}

/// Test and offline backends may have no repository behind them.
public extension AgentHostBackend {
    func gitBranches(_: GitBranchesToolRequest) async throws -> GitBranchesResponse {
        throw ToolDeniedError(message: "此处无法管理分支")
    }

    func gitBranchCreate(_: GitBranchCreateToolRequest) async throws -> GitBranchCreateResponse {
        throw ToolDeniedError(message: "此处无法创建分支")
    }

    func gitBranchCheckout(_: GitBranchCheckoutToolRequest) async throws -> GitBranchCheckoutResponse {
        throw ToolDeniedError(message: "此处无法切换分支")
    }

    func gitBranchDelete(_: GitBranchDeleteToolRequest) async throws -> GitBranchDeleteResponse {
        throw ToolDeniedError(message: "此处无法删除分支")
    }

    func gitBranchRename(_: GitBranchRenameToolRequest) async throws -> GitBranchRenameResponse {
        throw ToolDeniedError(message: "此处无法重命名分支")
    }

    func gitMerge(_: GitMergeToolRequest) async throws -> GitMergeResponse {
        throw ToolDeniedError(message: "此处无法合并分支")
    }

    func gitMergeAbort(_: GitMergeAbortToolRequest) async throws -> GitMergeAbortResponse {
        throw ToolDeniedError(message: "此处无法中止合并")
    }

    func gitLog(_: GitLogToolRequest) async throws -> GitLogResponse {
        throw ToolDeniedError(message: "此处无法查看 git 历史")
    }

    func gitCommitDetail(_: GitCommitDetailToolRequest) async throws -> GitCommitDetailResponse {
        throw ToolDeniedError(message: "此处无法查看提交详情")
    }
}
