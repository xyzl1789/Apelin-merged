import ApelinProtocol

/// 应用内工具行与实时活动共用的图标规则；不依赖 UIKit，回归可直接调用。
enum ToolSymbol {
    static func name(for tool: String?) -> String {
        guard let tool, let name = AgentToolName.canonical(tool) else { return fallback }
        switch name {
        case .gitBranchDelete:
            return "trash"
        case .gitTag:
            return "tag"
        case .gitStash:
            return "archivebox"
        case .gitRestore:
            return "arrow.uturn.backward"
        case .gitClean:
            return "trash.slash"
        case .fileRead, .fileList, .fileGrep, .fileFind, .fileShow:
            return "doc.text.magnifyingglass"
        case .fileWrite, .fileEdit, .fileCreate:
            return "square.and.pencil"
        case .shellRun:
            return "terminal"
        case .gitStatus, .gitDiff, .gitLog, .gitCommitDetail, .gitBranches, .gitRemoteList,
             .gitStage, .gitUnstage, .gitCommit, .gitInit, .gitBranchCreate, .gitBranchCheckout,
             .gitBranchRename, .gitMerge, .gitMergeAbort, .gitFetch, .gitPull, .gitPush, .gitClone,
             .gitSquash, .gitRemoteSet, .gitRemoteRemove, .gitResetToRemote, .gitReadSettings,
             .gitSetAuthor, .gitSaveCredential, .gitRemoveCredential, .gitCreateRepository,
             .gitCreateIssue:
            return "arrow.triangle.branch"
        case .projectBuild, .toolchainSelfTest:
            return "hammer"
        case .packageInstall, .packageRemove, .packageList, .packagePublish, .packageRelease, .packageConfirmLoaded:
            return "shippingbox"
        case .screenCapture, .screenReadTree, .screenInteract, .deviceRespring:
            return "iphone"
        case .logRead:
            return "text.alignleft"
        case .crashList, .crashRead, .crashSymbolicate:
            return "exclamationmark.triangle"
        case .memoryList, .memorySave, .memoryDelete:
            return "externaldrive"
        case .skillList, .skillRead, .skillSave, .skillRemove:
            return "book"
        case .conversationCreate, .conversationSend, .conversationList, .conversationRead,
             .conversationStop:
            return "bubble.left.and.bubble.right"
        case .webSearch, .webFetch:
            return "globe"
        case .todoList, .todoWrite, .conversationPlan:
            return "checklist"
        case .notificationSend:
            return "bell"
        case .conversationCompact:
            return "rectangle.compress.vertical"
        case .questionAsk:
            return "questionmark.bubble"
        case .runMode:
            return "slider.horizontal.3"
        case .feedbackSend, .feedbackRead, .feedbackEdit:
            return "exclamationmark.bubble"
        case .templateList, .projectList, .projectCreate, .projectRename, .projectDelete,
             .projectCheckDistribution, .projectSetEnvironment:
            return "square.grid.2x2"
        case .toolchainList, .sdkList, .toolchainSetup, .sdkImport, .sdkAnalyzeFramework,
             .sdkReadHeader:
            return "gearshape.2"
        }
    }

    /// 未识别的工具（例如 MCP 工具）保持统一兜底图标。
    private static let fallback = "wrench.and.screwdriver"
}
