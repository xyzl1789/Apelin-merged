import Foundation

/// Semantic visibility shared by the projection, the row and its measurement.
/// A turn header owns status and counts; empty thought placeholders are not steps.
enum ChatActivityContent {
    static func title(_ message: ChatMessage) -> String {
        message.foldsProcessSteps ? "" : message.activityTitle
    }

    static func source(_ message: ChatMessage) -> String? {
        guard message.role.isThinking, let source = message.processingSource,
              source.contains(where: { !$0.isWhitespace }) else { return nil }
        return source
    }

    static func banner(_ message: ChatMessage) -> ToolCallBanner? {
        message.foldsProcessSteps || message.role.isThinking ? message.banner : nil
    }

    static func steps(_ message: ChatMessage) -> [ChatMessage] {
        guard !message.foldsProcessSteps else { return [] }
        return TraceStep.messages(of: message).filter { step in
            if case .thinking = step.role {
                return step.text.contains(where: { !$0.isWhitespace })
            }
            return true
        }
    }

    /// 正在写入的思考取最新文本，已结束的思考不作为当前步骤。
    static func preview(_ message: ChatMessage) -> String? {
        guard message.role.isThinking else { return nil }
        let text = message.text
        return text.contains(where: { !$0.isWhitespace }) ? text : nil
    }

    /// 跟随追踪中最新一步：思考或工具调用共用同一活动行。
    static func line(_ message: ChatMessage) -> ToolCallBanner.ActivityLine? {
        let steps = message.trace
        if let newest = steps.last {
            if let text = preview(newest) {
                return .thought(text)
            }
            if newest.role == .tool, let call = newest.banner {
                return .call(call, token: callToken(of: steps))
            }
        }
        if let text = preview(message) {
            return .thought(text)
        }
        return banner(message).map { .call($0, token: callToken(of: steps)) }
    }

    /// 同样文案的后续调用也要刷新，以调用数量区分。
    private static func callToken(of steps: [ChatMessage]) -> Int {
        steps.count(where: { $0.role == .tool })
    }

    static func hasContent(_ message: ChatMessage) -> Bool {
        !title(message).isEmpty || source(message) != nil || line(message) != nil
            || (!message.foldsProcessSteps && message.receivedTokens != nil)
            || !steps(message).isEmpty
    }
}

/// Folded process rows belong beside their turn header, not at the position
/// of the newest model segment. Assistant text and attachments never move.
enum ChatProcessPresentation {
    static func rows(_ items: [ChatMessage], isExpanded: (UUID) -> Bool) -> [ChatMessage] {
        var newest: [UUID: ChatMessage] = [:]
        var lastContent: [UUID: ChatMessage] = [:]
        var headed = Set<UUID>()
        for item in items {
            guard let turn = item.turnMessageID else { continue }
            if case .turn = item.role { headed.insert(turn) }
            if case .thinking = item.role {
                newest[turn] = item
                var candidate = item
                candidate.foldsProcessSteps = true
                // Completed segments keep their call in the trace. Read that
                // content without reviving its execution state. Recompute from
                // this snapshot so rewind/discard/replay never retain a ghost.
                candidate.banner = item.banner ?? item.trace.last { $0.role == .tool }?.banner
                if ChatActivityContent.hasContent(candidate) {
                    lastContent[turn] = candidate
                }
            }
        }
        var visible: [ChatMessage] = []
        visible.reserveCapacity(items.count)
        func append(_ message: ChatMessage) {
            var row = message
            if row.role == .assistant,
               !row.text.contains(where: { !$0.isWhitespace }), row.attachments.isEmpty,
               !row.offersActions, row.turnStats == nil
            {
                return
            }
            if row.role.isActivity {
                if let turn = row.turnMessageID, headed.contains(turn) {
                    row.receivedTokens = nil
                    row.receivedSettles = false
                }
                guard ChatActivityContent.hasContent(row) else { return }
                row.activityJoinsPrevious = visible.last.map {
                    $0.role.isActivity && $0.turnMessageID == row.turnMessageID
                } ?? false
            }
            visible.append(row)
        }
        for item in items {
            guard !item.role.isApproval else { continue }
            if case let .turn(running, _) = item.role, let turn = item.turnMessageID {
                var header = item
                // Legacy callers may still carry the count on a summary.
                // Current transcripts put it directly on this stable header.
                if running, header.headerReceivedTokens == nil, let summary = newest[turn] {
                    header.headerReceivedTokens = summary.receivedTokens
                    header.headerReceivedSettles = summary.receivedSettles
                }
                append(header)
                if running, !isExpanded(turn), var process = lastContent[turn] {
                    process.id = ChatTranscript.rowID(forProcess: turn)
                    append(process)
                }
                continue
            }
            if case .thinking = item.role, let turn = item.turnMessageID,
               headed.contains(turn), !isExpanded(turn)
            {
                continue
            }
            append(item)
        }
        return visible
    }
}
