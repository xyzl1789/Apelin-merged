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
    let isStopping: Bool

    /// 与实时活动的排序一致，不必为选出首行扫描每条会话的历史。
    static func precedes(_ lhs: Self, _ rhs: Self) -> Bool {
        if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
        if lhs.lastInteraction != rhs.lastInteraction { return lhs.lastInteraction > rhs.lastInteraction }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    private var rank: Int { approvalID != nil ? 0 : (isStopping ? 1 : 2) }
}

extension ChatRecord {
    var widgetFocus: ChatActivityFocus? {
        guard summary.isWorking else { return nil }
        let stopping = run == .stopping
        return .init(id: summary.id, lastInteraction: summary.lastInteraction,
                     approvalID: stopping ? nil : widgetPendingApproval?.id, isStopping: stopping)
    }

    /// 从尾部查最后一张未处理的审批卡，不为每段流式文字重扫整份历史。
    private var widgetPendingApproval: (id: String, tool: String, payload: JSONValue?)? {
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
                return (id, AgentToolName.canonical(tool)?.rawValue ?? tool, payload)
            default: break
            }
        }
        return nil
    }

    /// 忽略用量等辅助事件，只跟随实际改变展示步骤的事件。
    private static func isWidgetStep(_ event: TaskEvent) -> Bool {
        guard !ChatFork.isHistorical(event) else { return false }
        switch event.kind {
        case "text", "message":
            // 只调用工具的助手消息也会结束，但正文为空，不是正在回答。
            return event.payload?["text"]?.stringValue?.contains(where: { !$0.isWhitespace }) == true
        case "prompt", "steer", "messageStarted", "messageDiscarded", "finished",
             "reconnecting", "waitingForNetwork", "compactionStarted", "compactionFinished",
             "toolCallPreparing", "toolCall", "toolResult", "approvalRequested", "approvalResolved",
             "error", "thinking", "historyRewound": return true
        case TaskEvent.stateKind: return ChatTranscript.endsTask(event)
        default: return false
        }
    }

    /// 同一段流的文字仍合并发布；工具开始、结果和其他阶段边界不等节流。
    var widgetStepSignal: String? {
        guard summary.isWorking else { return nil }
        if run == .stopping { return "stopping" }
        guard let index = events.lastIndex(where: Self.isWidgetStep) else { return nil }
        switch events[index].kind {
        case "thinking": return "thinking"
        case "text", "message": return "replying"
        default: return "event:\(index)"
        }
    }

    var widgetProgress: ChatWidgetProgress? {
        guard summary.isWorking else { return nil }
        if run == .stopping {
            return .init(stage: .stopping, symbol: "stop.circle.fill",
                         title: String(localized: "Stopping…"), detail: nil)
        }
        if let approval = widgetPendingApproval {
            let mode = ApprovalCardText.runModeSwitch(approval.payload)
            let tool = Self.widgetTool(approval.tool, arguments: approval.payload?["arguments"]?.stringValue,
                                       mode: mode)
            return .init(stage: .waitingForApproval, symbol: "exclamationmark.triangle.fill", title: tool.title, detail: tool.detail)
        }
        let steps = events.reversed().lazy.filter(Self.isWidgetStep)
        guard let step = steps.first else { return nil }
        switch step.kind {
        case "finished", TaskEvent.stateKind: return nil
        case "reconnecting":
            return .init(stage: .reconnecting, symbol: "arrow.triangle.2.circlepath",
                         title: String(localized: "Reconnecting…"), detail: nil)
        case "waitingForNetwork":
            return .init(stage: .waitingForNetwork, symbol: "wifi.exclamationmark",
                         title: String(localized: "Waiting for Network…"), detail: nil)
        case "compactionStarted":
            return .init(stage: .compacting, symbol: "rectangle.compress.vertical",
                         title: String(localized: "Compacting Chat"), detail: nil)
        case "prompt", "steer", "messageStarted":
            return .init(stage: .thinking, symbol: "brain.head.profile", title: String(localized: "Thinking"), detail: nil)
        case "compactionFinished", "approvalRequested", "error", "messageDiscarded", "historyRewound":
            return Self.widgetWaitingForNextStep
        default: break
        }

        // 某个并行工具返回时，仍保留尚未结束的调用，而不是回到更早的思考。
        if let tool = widgetCurrentTool {
            return .init(stage: .tool, symbol: tool.symbol, title: tool.title, detail: tool.detail)
        }
        switch step.kind {
        case "toolCallPreparing":
            return .init(stage: .tool, symbol: "wrench.and.screwdriver",
                         title: String(localized: "Executing tool…"), detail: nil)
        case "thinking":
            var text = ""
            for event in steps.prefix(while: { $0.kind == "thinking" }) {
                if let part = event.payload?["text"]?.stringValue {
                    text = String((String(part.suffix(260)) + text).suffix(260))
                    if text.count == 260 { break }
                }
            }
            let detail = Self.widgetProgressText(text)
            return .init(stage: .thinking, symbol: "brain.head.profile",
                         title: String(localized: "Thinking"), detail: detail.isEmpty ? nil : detail)
        case "text", "message":
            return .init(stage: .replying, symbol: "text.bubble",
                         title: String(localized: "Replying…"), detail: widgetReply(completed: false))
        default:
            return Self.widgetWaitingForNextStep
        }
    }

    private static var widgetWaitingForNextStep: ChatWidgetProgress {
        .init(stage: .waitingForNextStep, symbol: "ellipsis.circle",
              title: String(localized: "Waiting for Next Step…"), detail: nil)
    }

    private static func widgetProgressText(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard line.count > 220 else { return line }
        return String(line.prefix(219)) + "…"
    }

    /// 结束后，回到仍在运行的那一个；旧回合和分叉继承的调用不显示。
    var widgetCurrentTool: ChatWidgetSnapshot.ToolActivity? {
        guard summary.isWorking else { return nil }
        var completed: Set<String> = []
        for event in events.reversed() where !ChatFork.isHistorical(event) {
            let payload = event.payload
            switch event.kind {
            case "prompt", "steer", "messageStarted", "finished", "messageDiscarded",
                 "compactionStarted", "compactionFinished", "historyRewound": return nil
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

    /// 保留本轮最近完成的工具，短到来不及单独绘制也能看到摘要。
    func widgetRecentTools(completed: Bool = false) -> [ChatWidgetSnapshot.ToolActivity] {
        var resultOrder: [String] = []
        var summaries: [String: ChatWidgetSnapshot.ToolActivity] = [:]
        var reachedTurn = !completed
        for event in events.reversed() where !ChatFork.isHistorical(event) {
            if ChatTranscript.endsTask(event) {
                if reachedTurn { break }
                continue
            }
            if event.kind == "finished" {
                if reachedTurn { break }
                reachedTurn = true
                continue
            }
            if event.kind == "prompt" { break }
            if !reachedTurn { reachedTurn = true }
            guard let id = event.payload?["id"]?.stringValue else { continue }
            if event.kind == "toolResult", resultOrder.count < 2, !resultOrder.contains(id) {
                resultOrder.append(id)
            }
            if event.kind == "toolCall", resultOrder.contains(id), summaries[id] == nil,
               let name = event.payload?["tool"]?.stringValue {
                summaries[id] = Self.widgetTool(name, arguments: event.payload?["arguments"]?.stringValue)
                if summaries.count == 2 { break }
            }
        }
        return resultOrder.compactMap { summaries[$0] }
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
                if text.isEmpty, let message = event.payload?["text"]?.stringValue,
                   let preview = Self.widgetReplyPreview(message) {
                    return preview
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

    private static func widgetTool(_ name: String, arguments: String?, mode: AgentRunModeRequest? = nil) -> ChatWidgetSnapshot.ToolActivity {
        let values = arguments.flatMap { try? JSONCoding.decode(JSONValue.self, from: Data($0.utf8)) }
        let canonical = AgentToolName.canonical(name)
        let modeReason = canonical == .runMode ? (mode?.reason ?? values?["why"]?.stringValue) : nil
        let detail = (modeReason ?? values?["reason"]?.stringValue).flatMap(Self.widgetToolDetail)
        guard let tool = canonical else {
            let title = name.isEmpty ? String(localized: "Executing tool…") : ChatTranscript.toolTitle(name, values: nil)
            return .init(symbol: ToolSymbol.name(for: name), title: title, detail: detail)
        }
        let symbol = ToolSymbol.name(for: tool.rawValue)
        var safe: [String: JSONValue] = [:]
        switch tool {
        case .fileRead, .fileWrite, .fileEdit, .fileCreate:
            if let path = values?["path"]?.stringValue.flatMap(Self.widgetRelativePath) { safe["path"] = .string(path) }
        case .fileShow:
            if case let .array(paths)? = values?["paths"] {
                let relative = paths.compactMap { $0.stringValue.flatMap(Self.widgetRelativePath) }
                if !relative.isEmpty { safe["paths"] = .array(relative.map { .string($0) }) }
            }
        case .webFetch:
            if let raw = values?["url"]?.stringValue, let url = URLComponents(string: raw),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme), let host = url.host {
                var address = URLComponents()
                address.scheme = scheme
                address.host = host
                if let site = address.string { safe["url"] = .string(site) }
            }
        case .runMode:
            if let target = mode?.mode.rawValue ?? values?["mode"]?.stringValue { safe["mode"] = .string(target) }
        default: break
        }
        let title = ChatTranscript.toolTitle(tool.rawValue, values: .object(safe))
        return .init(symbol: symbol, title: title, detail: detail == title ? nil : detail)
    }

    private static let widgetRedaction = LogRedaction(home: nil, installRoot: nil)

    private static func widgetToolDetail(_ text: String) -> String? {
        let summary = String(text.prefix(1_024))
            .replacingOccurrences(of: #"https?://[^\s]+"#, with: "…", options: [.regularExpression, .caseInsensitive])
        let redacted = widgetRedaction.redacted(summary)
        let line = widgetProgressText(redacted)
        return line.isEmpty ? nil : line
    }

    private static func widgetRelativePath(_ path: String) -> String? {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~"), !path.contains("://"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }), path.utf8.count <= 160 else { return nil }
        return path
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
            if run == .stopping {
                .stopping
            } else {
                approval == nil ? .working : .waiting
            }
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
