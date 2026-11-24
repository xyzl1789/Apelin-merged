import ApelinCore
import ApelinProtocol
import Foundation

extension ChatRecord {
    /// 从本回合末尾倒查仍未返回结果的最近一次调用。并行时最新的调用
    /// 结束后，回到仍在运行的那一个；旧回合和分叉继承的调用不显示。
    var widgetCurrentTool: ChatWidgetSnapshot.ToolActivity? {
        guard summary.isWorking else { return nil }
        var completed: Set<String> = []
        for event in events.reversed() where !ChatFork.isHistorical(event) {
            let payload = event.payload
            switch event.kind {
            case "prompt", "finished": return nil
            case TaskEvent.stateKind:
                if let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)), state.isTerminal {
                    return nil
                }
            case "toolResult":
                if let id = payload?["id"]?.stringValue { completed.insert(id) }
            case "toolCall":
                guard let id = payload?["id"]?.stringValue, !completed.contains(id),
                      let name = payload?["tool"]?.stringValue, !name.isEmpty else { continue }
                return Self.widgetTool(name, arguments: payload?["arguments"]?.stringValue)
            default: break
            }
        }
        return nil
    }

    private static func widgetTool(_ name: String, arguments: String?) -> ChatWidgetSnapshot.ToolActivity {
        guard let tool = AgentToolName.canonical(name) else {
            return .init(symbol: "wrench.and.screwdriver", title: String(localized: "Executing tool…"))
        }
        let symbol: String = switch tool {
        case .fileRead, .fileShow: "doc.text"
        case .fileWrite, .fileEdit, .fileCreate: "square.and.pencil"
        case .fileList: "folder"
        case .fileGrep, .fileFind, .webSearch: "magnifyingglass"
        case .webFetch: "globe"
        case .sdkAnalyzeFramework, .sdkReadHeader: "book"
        case .shellRun: "terminal"
        case .projectBuild: "hammer"
        case .packageInstall, .packageRemove, .packageList, .packagePublish, .packageRelease: "shippingbox"
        case .gitPush, .gitFetch, .gitPull, .gitClone: "arrow.up.arrow.down"
        case .gitStatus, .gitDiff, .gitLog, .gitCommit, .gitStage, .gitUnstage, .gitCommitDetail: "arrow.triangle.branch"
        case .screenReadTree, .screenInteract, .screenCapture: "iphone"
        case .logRead, .crashList, .crashRead, .crashSymbolicate: "list.bullet.rectangle"
        default: "wrench.and.screwdriver"
        }
        let title: String
        switch tool {
        case .fileRead, .fileWrite, .fileEdit, .fileCreate:
            if let file = widgetFileName(arguments) {
                title = tool == .fileRead ? String(localized: "Read \(file)") : String(localized: "Edit \(file)")
            } else {
                title = ChatTranscript.toolTitle(tool.rawValue, arguments: nil)
            }
        default:
            // 锁屏只用操作名称，不带命令、网址、查询、理由或工具输出。
            title = ChatTranscript.toolTitle(tool.rawValue, arguments: nil)
        }
        return .init(symbol: symbol, title: title)
    }

    private static func widgetFileName(_ arguments: String?) -> String? {
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        guard let path = values?["path"]?.stringValue, !path.hasPrefix("/"), !path.hasPrefix("~"),
              !path.contains("://"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/").contains(".."),
              let name = path.split(separator: "/").last, name != ".", !name.hasPrefix(".") else { return nil }
        return name.utf8.count <= 120 ? String(name) : nil
    }

    /// Whether the widgets list it: a conversation that holds something.
    /// An untouched New Chat holds nothing but its place in the sidebar.
    var isListedInWidgets: Bool {
        !events.isEmpty || sending != nil
    }

    /// What the widgets say about it, from the same events the transcript
    /// is built from. Waiting needs a running turn (`isWorking`): an
    /// approval left asking by a session that ended with the host waits
    /// for nothing. Failed is a last turn that finished `failed`, or one
    /// cut off by its task failing; a session that merely ended after its
    /// turn finished is done.
    func widgetChat(projectName: String?) -> ChatWidgetSnapshot.Chat {
        var waiting: [(id: String, tool: String)] = []
        var turnOpen = false
        var turnStart: Date?
        var failed = false
        for event in events {
            let payload = event.payload
            switch event.kind {
            case "prompt", "steer", "messageStarted":
                // 一轮的开始时间只认第一次：`messageStarted` 在一轮里
                // 每个助手消息段都会发一次（中途插入的引导也算），每次
                // 都写会让计时器回到 0 重新走，显示时长与真实运行时间
                // 对不上。turn 已经开着就保留原来的开始时间。
                if !turnOpen {
                    turnStart = event.time
                }
                turnOpen = true
                failed = false
            case "approvalRequested":
                if let id = payload?["approvalID"]?.stringValue {
                    // By today's name: the widget names only those.
                    let tool = payload?["tool"]?.stringValue ?? ""
                    waiting.append((id, AgentToolName.canonical(tool)?.rawValue ?? tool))
                }
            case "approvalResolved":
                let id = payload?["approvalID"]?.stringValue
                waiting.removeAll { $0.id == id }
            case "finished":
                failed = payload?["reason"]?.stringValue == "failed"
                turnOpen = false
                waiting.removeAll()
            case TaskEvent.stateKind:
                if let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)), state.isTerminal {
                    if turnOpen, state == .failed || state == .interrupted {
                        failed = true
                    }
                    turnOpen = false
                    waiting.removeAll()
                }
            default:
                break
            }
        }
        let status: ChatWidgetSnapshot.Chat.Status = if summary.isWorking {
            waiting.isEmpty ? .working : .waiting
        } else {
            failed ? .failed : .done
        }
        return ChatWidgetSnapshot.Chat(
            id: summary.id.uuidString,
            title: String(summary.displayTitle.prefix(80)),
            project: projectName,
            status: status,
            approvalTool: status == .waiting ? waiting.last?.tool : nil,
            startedAt: turnOpen ? turnStart : nil,
        )
    }
}
