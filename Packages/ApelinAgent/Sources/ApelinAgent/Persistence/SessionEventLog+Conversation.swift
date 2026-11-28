import Darwin
import Foundation
import KWWKAI

/// `messages.jsonl`: the model's conversation, appended to rather than
/// rewritten.
///
/// One line is one record, in the file's order:
///
///     {"kind":"snapshot","messages":[…]}   the whole conversation, when a
///                                          compaction, a repair or the
///                                          reader's edit rewrote it
///     {"kind":"append","messages":[…]}      the messages finished since
///
/// What a conversation is: its last snapshot, and every append after it.
/// A turn therefore costs one small line per finished message instead of the
/// whole history written again, and what a compaction replaces is still in
/// the file — which is what a fork through an older turn reads.
///
/// A line is written with one append and never edited, so a process killed
/// mid-write leaves a torn last line, which the reader drops (the same rule
/// as `events.jsonl`); damage anywhere else is an error, never an empty
/// conversation.
extension SessionEventLog {
    /// How one line of `messages.jsonl` reads.
    struct ConversationRecord: Codable, Equatable {
        enum Kind: String, Codable {
            case snapshot
            case append
        }

        var kind: Kind
        var messages: [Message]
        /// 只随新消息追加其锚点。空字典也标明这是带边界的新日志，
        /// 不在每次 checkpoint 重写整份锚点或逐消息对象。
        var anchors: [String: HistoryAnchor]? = nil
        var eventBoundary: UInt64? = nil

        private enum CodingKeys: String, CodingKey {
            case kind, messages, anchors, eventBoundary
        }

        init(
            kind: Kind,
            messages: [Message],
            anchors: [String: HistoryAnchor]? = nil,
            eventBoundary: UInt64? = nil,
        ) {
            self.kind = kind
            self.messages = messages
            self.anchors = anchors
            self.eventBoundary = eventBoundary
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            kind = try container.decode(Kind.self, forKey: .kind)
            messages = try container.decode([Message].self, forKey: .messages)
            anchors = try container.decodeIfPresent([String: HistoryAnchor].self, forKey: .anchors)
            eventBoundary = try container.decodeIfPresent(UInt64.self, forKey: .eventBoundary)
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(kind, forKey: .kind)
            try container.encode(messages, forKey: .messages)
            try container.encodeIfPresent(anchors, forKey: .anchors)
            try container.encodeIfPresent(eventBoundary, forKey: .eventBoundary)
        }
    }

    /// Where the conversation lives, beside the event log.
    var conversationURL: URL {
        directory.appendingPathComponent("messages.jsonl")
    }

    /// Whether the conversation has been written at all: a session that
    /// predates `messages.jsonl` is seeded from its transcript once.
    var hasConversation: Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: conversationURL.path),
              let size = attributes[.size] as? Int
        else { return false }
        return size > 0
    }

    /// The conversation as it stands: the last snapshot and what was appended
    /// after it. Nil for a session that has none yet.
    func readConversation() throws -> [Message]? {
        try conversationSegments().last
    }

    /// Every segment the file holds, in order: each one a snapshot and the
    /// appends that followed it. A fork through an older turn reads the
    /// segment that turn belongs to, so a compaction cannot take it away.
    func conversationSegments() throws -> [[Message]] {
        var segments: [[Message]] = []
        for record in try conversationRecords() {
            switch record.kind {
            case .snapshot:
                segments.append(record.messages)
            case .append:
                guard !segments.isEmpty else {
                    throw SessionStoreError.corrupt("messages.jsonl 在任何快照之前就有追加内容")
                }
                segments[segments.count - 1] += record.messages
            }
        }
        return segments
    }

    /// Adds the messages the conversation gained. A file that holds no
    /// snapshot yet is given one, so every append follows a segment's start.
    func appendConversation(
        _ messages: [Message],
        anchors: [String: HistoryAnchor]? = nil,
        completeBoundary: Bool = true,
    ) throws {
        guard !messages.isEmpty || anchors != nil else { return }
        try trimTornLine()
        let kind: ConversationRecord.Kind = hasConversation ? .append : .snapshot
        let boundary = anchors != nil && completeBoundary ? try replayBoundary() : nil
        try writeConversationLine(ConversationRecord(
            kind: kind, messages: messages, anchors: anchors, eventBoundary: boundary,
        ))
    }

    /// Starts a segment: from here on the conversation is `messages`. What
    /// came before stays in the file, where a fork still reads it.
    func snapshotConversation(_ messages: [Message], anchors: [String: HistoryAnchor]? = nil) throws {
        try trimTornLine()
        let boundary: UInt64?
        if let anchors, ForkContext.hasCompleteToolResults(messages) {
            boundary = try reusableBoundary(for: messages) ?? replayBoundary()
        } else {
            boundary = nil
        }
        try writeConversationLine(ConversationRecord(
            kind: .snapshot, messages: messages, anchors: anchors, eventBoundary: boundary,
        ))
    }

    /// If an interrupted run repaired its model transcript, do not pair that
    /// complete prefix with later approval/tool UI events. Reuse the last
    /// checkpoint whose exact model messages are a prefix of the repaired one.
    private func reusableBoundary(for messages: [Message]) throws -> UInt64? {
        var segment: [Message] = []
        var started = false
        var boundary: UInt64?
        for record in try conversationRecords() {
            switch record.kind {
            case .snapshot:
                segment = record.messages
                started = true
            case .append:
                guard started else {
                    throw SessionStoreError.corrupt("messages.jsonl 在任何快照之前就有追加内容")
                }
                segment += record.messages
            }
            if record.anchors != nil,
               let candidate = record.eventBoundary,
               ForkContext.hasCompleteToolResults(segment),
               messages.starts(with: segment)
            {
                boundary = candidate
            }
        }
        return boundary
    }

    /// The conversation through the turn of `id`, for a fork: the segment
    /// that holds that message — or, when it holds it twice, the first that
    /// does, which is the context it was read in — cut after it.
    ///
    /// `anchors` says what each message's text became in the model's
    /// conversation; a message sent before anchors were kept is found by
    /// `ConversationHistory`, as the history's own changes find it.
    func conversation(through id: UUID, anchors: [String: HistoryAnchor]) throws -> [Message]? {
        try conversationSelection(through: id, anchors: anchors)?.messages
    }

    /// 新会话不再逐轮创建对象快照；追加记录本身保存完整模型边界
    /// 及对应的 UI 序列。回退移除活动锚点后，旧段里的锚点仍可定位原文。
    func conversationForkContext(through id: UUID, anchors: [String: HistoryAnchor]) throws -> ForkContext? {
        guard let selected = try conversationSelection(through: id, anchors: anchors) else { return nil }
        // persisted-read: UI 日志不可读时交还旧对象快照路径，不把部分日志当成完整历史
        guard let history = try? historyRecords() else { return nil }
        let bounded = selected.eventBoundary.map { boundary in
            history.filter { $0.seq <= boundary }
        } ?? history
        guard let records = bounded.forkRecords(through: id) else { return nil }
        return ForkContext(messages: selected.messages, records: records, anchors: selected.anchors)
    }

    private struct ConversationSelection {
        var messages: [Message]
        var anchors: [String: HistoryAnchor]
        var eventBoundary: UInt64?
    }

    private func conversationSelection(through id: UUID, anchors: [String: HistoryAnchor]) throws -> ConversationSelection? {
        let key = id.uuidString.lowercased()
        var segment: [Message] = []
        var known: [String: HistoryAnchor] = [:]
        var started = false
        var selected: ConversationSelection?
        for record in try conversationRecords() {
            switch record.kind {
            case .snapshot:
                // 第一份包含此消息的历史段才是它最初读到的上下文。
                if let selected { return selected }
                segment = record.messages
                known = record.anchors ?? [:]
                started = true
            case .append:
                guard started else {
                    throw SessionStoreError.corrupt("messages.jsonl 在任何快照之前就有追加内容")
                }
                segment += record.messages
                known.merge(record.anchors ?? [:]) { _, new in new }
            }
            guard let anchor = known[key] ?? anchors[key],
                  let index = ConversationHistory.index(of: anchor, in: segment)
            else { continue }
            let end = ConversationHistory.nextReaderMessage(after: index, in: segment)
            let messages = Array(segment.prefix(end))
            if record.anchors != nil {
                // 未完成工具批次虽然必须持久化以供恢复，却不能向前推进
                // 可分叉边界，更不能夹带随后出现的审批或流式尾部。
                guard record.eventBoundary != nil,
                      try ForkContext.completePrefix(of: messages) == messages
                else { continue }
            }
            let turnAnchors = anchors.merging(known) { _, saved in saved }.filter { entry in
                guard let position = ConversationHistory.index(of: entry.value, in: messages) else { return false }
                return position < end
            }
            selected = ConversationSelection(messages: messages, anchors: turnAnchors, eventBoundary: record.eventBoundary)
        }
        return selected
    }

    private func conversationRecords() throws -> [ConversationRecord] {
        let url = conversationURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        var records: [ConversationRecord] = []
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        for (index, line) in lines.enumerated() {
            do {
                records.append(try Self.decoder.decode(ConversationRecord.self, from: Data(line)))
            } catch {
                // the process died mid-write: the last line is not a record
                if index == lines.count - 1 { break }
                throw SessionStoreError.corrupt("messages.jsonl 第 \(index + 1) 行")
            }
        }
        return records
    }

    /// Cuts away a last line the process died in the middle of writing.
    /// Appending after it would make it read as damage where it is meant to
    /// be read past, and the file's whole lines are what a reader trusts.
    private func trimTornLine() throws {
        let url = conversationURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size > 0
        else { return }
        guard let handle = FileHandle(forReadingAtPath: url.path) else {
            throw SessionStoreError.io("无法读取 messages.jsonl")
        }
        let tail: Data
        do {
            try handle.seek(toOffset: UInt64(size - 1))
            tail = try handle.read(upToCount: 1) ?? Data()
            try handle.close()
        } catch {
            try? handle.close()
            throw SessionStoreError.io("无法读取 messages.jsonl")
        }
        guard tail != Data([0x0A]) else { return }
        let whole = try Data(contentsOf: url)
        let end = whole.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0
        try Data(whole[..<end]).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
    }

    private func writeConversationLine(_ record: ConversationRecord) throws {
        var data = try Self.conversationEncoder.encode(record)
        data.append(0x0A)
        let descriptor = open(conversationURL.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw SessionStoreError.io("无法打开 messages.jsonl")
        }
        defer { Darwin.close(descriptor) }
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            var written = 0
            while written < buffer.count {
                let count = Darwin.write(descriptor, base.advanced(by: written), buffer.count - written)
                guard count > 0 else {
                    throw SessionStoreError.io("无法写入 messages.jsonl")
                }
                written += count
            }
        }
    }

    /// The conversation's lines are written the way the event log writes
    /// its own: keys sorted, dates ISO 8601, slashes unescaped.
    static let conversationEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
