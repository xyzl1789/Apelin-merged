import ApelinCore
import ApelinProtocol
import Foundation

/// 有重叠运行时间的回合算同一批。先从仍在运行或最后结束的回合倒查，
/// 只要与这一批重叠就纳入；不相干的旧失败不影响结果。
struct ChatActivityBatch {
    struct Turn {
        let chatID: UUID
        let start: Date
        let end: Date?
        let outcome: ChatWidgetSnapshot.BatchOutcome?
    }

    private(set) var chatIDs: Set<UUID> = []
    private(set) var outcome: ChatWidgetSnapshot.BatchOutcome?
    private(set) var finalChatID: UUID?

    init(turns: [Turn]) {
        var earliest = Date.distantFuture
        var running = false
        var lastFailed: UUID?
        var lastStopped: UUID?
        for turn in turns.sorted(by: Self.newestFirst) {
            if let end = turn.end, end < earliest, !chatIDs.isEmpty { break }
            earliest = min(earliest, turn.start)
            chatIDs.insert(turn.chatID)
            if let result = turn.outcome {
                if finalChatID == nil { finalChatID = turn.chatID }
                if result == .failed, lastFailed == nil { lastFailed = turn.chatID }
                if result == .stopped, lastStopped == nil { lastStopped = turn.chatID }
            } else {
                running = true
            }
        }
        guard !running, !chatIDs.isEmpty else {
            finalChatID = nil
            return
        }
        if let lastFailed {
            outcome = .failed
            finalChatID = lastFailed
        } else if let lastStopped {
            outcome = .stopped
            finalChatID = lastStopped
        } else {
            outcome = .succeeded
        }
    }

    private static func newestFirst(_ lhs: Turn, _ rhs: Turn) -> Bool {
        let left = lhs.end ?? .distantFuture
        let right = rhs.end ?? .distantFuture
        if left != right { return left > right }
        if lhs.start != rhs.start { return lhs.start > rhs.start }
        return lhs.chatID.uuidString < rhs.chatID.uuidString
    }
}

/// 用于区分需要立即切换的会话变化和可合并的流式文案变化。
struct ChatActivityFocus: Hashable {
    let id: UUID
    let lastInteraction: Date
    let approvalID: String?
}

extension ChatRecord {
    var widgetFocus: ChatActivityFocus? {
        guard summary.isWorking else { return nil }
        return .init(id: summary.id, lastInteraction: summary.lastInteraction, approvalID: widgetPendingApproval?.id)
    }

    /// 从尾部查最后一张未处理的审批卡，不为每段流式文字重扫整份历史。
    private var widgetPendingApproval: (id: String, tool: String)? {
        var resolved: Set<String> = []
        for event in events.reversed() where !ChatFork.isHistorical(event) {
            let payload = event.payload
            switch event.kind {
            case "prompt", "finished": return nil
            case TaskEvent.stateKind:
                if let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)), state.isTerminal {
                    return nil
                }
            case "approvalResolved":
                if let id = payload?["approvalID"]?.stringValue { resolved.insert(id) }
            case "approvalRequested":
                guard let id = payload?["approvalID"]?.stringValue, !resolved.contains(id) else { continue }
                let tool = payload?["tool"]?.stringValue ?? ""
                return (id, AgentToolName.canonical(tool)?.rawValue ?? tool)
            default: break
            }
        }
        return nil
    }

    /// 当前会话在详情页下方的实际阶段：工具优先，其次是流式思考内容，再是回答预览。
    var widgetProgress: ChatWidgetProgress? {
        guard summary.isWorking else { return nil }
        var completed: Set<String> = []
        var latestThinking = ""
        var sawReply = false
        var sawTurn = false
        for event in events.reversed() where !ChatFork.isHistorical(event) {
            let payload = event.payload
            switch event.kind {
            case "prompt", "steer":
                sawTurn = true
                if latestThinking.isEmpty { latestThinking = payload? ["text"]?.stringValue ?? "" }
                break
            case "finished":
                return nil
            case TaskEvent.stateKind:
                if let state = payload? ["state"]?.stringValue.flatMap(TaskState.init(rawValue)), state.isTerminal { return nil }
            case "toolResult":
                if let id = payload? ["id"]?.stringValue { completed.insert(id) }
            case "toolCall":
                guard let id = payload? ["id"]?.stringValue, !completed.contains(id),
                      let name = payload? ["tool"]?.stringValue, !name.isEmpty else { continue }
                let title = Self.widgetToolTitle(name, arguments: payload? ["arguments"]?.stringValue)
                return .init(stage: .tool, symbol: ChatWidgetToolStyle.symbol(for: name), title: title, detail: nil)
            case "text", "message":
                sawReply = true
            case "thinking":
                if let text = payload? ["text"]?.stringValue, !text.isEmpty {
                    latestThinking = String((text + latestThinking).prefix(260))
                }
            case "messageStarted", "toolCallPreparing":
                sawTurn = true
            default:
                break
            }
        }
        guard sawTurn || !latestThinking.isEmpty else { return nil }
        if !latestThinking.isEmpty {
            return .init(stage: .thinking, symbol: "brain.head.profile", title: String(localized: "Thinking"), detail: Self.widgetProgressText(latestThinking))
        }
        if sawReply {
            return .init(stage: .replying, symbol: "text.bubble", title: String(localized: "Replying…"), detail: widgetReply(completed: false))
        }
        return .init(stage: .thinking, symbol: "brain.head.profile", title: String(localized: "Thinking"), detail: nil)
    }

    private static func widgetProgressText(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > 220 else { return line }
        return String(line.prefix(219)) + "…"
    }

    private static func widgetToolTitle(_ name: String, arguments: String?) -> String {
        guard let tool = AgentToolName.canonical(name) else { return name.replacingOccurrences(of: "_", with: " ").capitalized }
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        switch tool {
        case .fileRead:
            return values? ["path"]?.stringValue.map { String(localized: "Read \($0)") } ?? String(localized: "Read a file")
        case .fileGrep, .fileFind: return String(localized: "Search files")
        case .fileList: return String(localized: "List files")
        case .fileShow: return String(localized: "Show files")
        default: return ChatTranscript.toolTitle(name, arguments: nil)
        }
    }

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

    /// 只取本轮最后一段对外回答，不取推理、工具输出或旧回合。
    func widgetReply(completed: Bool) -> String? {
        var text = ""
        var seenFinish = false
        for event in events.reversed() where !ChatFork.isHistorical(event) {
            switch event.kind {
            case "finished":
                guard completed, !seenFinish, text.isEmpty,
                      event.payload?["reason"]?.stringValue == "completed" else { return nil }
                seenFinish = true
            case "prompt", "steer", "messageStarted", "toolCall", "toolResult", "messageDiscarded",
                 "historyRewound", "replyEdited", "replyDeleted", "thinking", "toolCallPreparing", "reconnecting", "waitingForNetwork":
                return Self.widgetReplyPreview(text)
            case "message":
                guard !completed || seenFinish else { return nil }
                if text.isEmpty, let message = event.payload?["text"]?.stringValue, !message.isEmpty {
                    return Self.widgetReplyPreview(message)
                }
            case "text" where !completed:
                if let part = event.payload?["text"]?.stringValue {
                    text = String((String(part.prefix(192)) + text).prefix(192))
                }
            default: break
            }
        }
        return Self.widgetReplyPreview(text)
    }

    private static func widgetReplyPreview(_ text: String) -> String? {
        let singleLine = text.prefix(192).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !singleLine.isEmpty else { return nil }
        var result = ""
        var bytes = 0
        for character in singleLine {
            let size = String(character).utf8.count
            if bytes + size > 180 { return result.isEmpty ? nil : result + "…" }
            result.append(character)
            bytes += size
        }
        return text.count > 192 ? result + "…" : result
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

    /// 只用当前设备真实跑过的回合。整段回合用开始和结束时间表示，避免
    /// 一秒合并更新期间启动又结束的会话被漏算。
    var widgetTurns: [ChatActivityBatch.Turn] {
        var turns: [ChatActivityBatch.Turn] = []
        var start: Date?
        var previousEventTime: Date?

        func finish(at time: Date, outcome: ChatWidgetSnapshot.BatchOutcome) {
            guard let began = start else { return }
            turns.append(.init(chatID: summary.id, start: began, end: max(began, time), outcome: outcome))
            start = nil
        }

        for event in events where !ChatFork.isHistorical(event) {
            defer { previousEventTime = event.time }
            switch event.kind {
            case "prompt":
                // 缺结束事件的上一轮止于最后一次活动，不把停顿算作重叠。
                finish(at: previousEventTime ?? event.time, outcome: .stopped)
                start = event.time
            case "steer", "messageStarted":
                if start == nil { start = event.time }
            case "finished":
                let outcome: ChatWidgetSnapshot.BatchOutcome = switch event.payload?["reason"]?.stringValue {
                case "completed": .succeeded
                case "failed": .failed
                default: .stopped
                }
                finish(at: event.time, outcome: outcome)
            case TaskEvent.stateKind:
                guard let raw = event.payload?["state"]?.stringValue,
                      let state = TaskState(rawValue: raw), state.isTerminal else { continue }
                let outcome: ChatWidgetSnapshot.BatchOutcome = switch state {
                case .failed, .interrupted: .failed
                case .succeeded: .succeeded
                default: .stopped
                }
                finish(at: event.time, outcome: outcome)
            default: break
            }
        }
        if summary.isWorking {
            // 在工具/模型开始事件到达前，先把该会话算作还在运行。
            turns.append(.init(chatID: summary.id, start: start ?? summary.lastInteraction, end: nil, outcome: nil))
        } else if let previousEventTime {
            // 丢失结束事件时不报成功，也不让批次一直挂在进行中。
            finish(at: previousEventTime, outcome: .stopped)
        }
        return turns
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
        var turnOpen = false
        var turnStart: Date?
        var failed = false
        for event in events {
            let payload = event.payload
            switch event.kind {
            case "prompt", "steer", "messageStarted":
                // 同一回合的多个助手消息段不应让计时器回到 0。
                if !turnOpen { turnStart = event.time }
                turnOpen = true
                failed = false
            case "finished":
                failed = payload?["reason"]?.stringValue == "failed"
                turnOpen = false
            case TaskEvent.stateKind:
                if let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)), state.isTerminal {
                    if turnOpen, state == .failed || state == .interrupted {
                        failed = true
                    }
                    turnOpen = false
                }
            default:
                break
            }
        }
        let approval = summary.isWorking ? widgetPendingApproval : nil
        let status: ChatWidgetSnapshot.Chat.Status = if summary.isWorking {
            approval == nil ? .working : .waiting
        } else {
            failed ? .failed : .done
        }
        return ChatWidgetSnapshot.Chat(
            id: summary.id.uuidString,
            title: String(summary.displayTitle.prefix(80)),
            project: projectName,
            status: status,
            approvalTool: approval?.tool,
            startedAt: turnOpen ? turnStart : nil,
        )
    }
}
