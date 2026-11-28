import ApelinCore
import ApelinProtocol
import Foundation

/// A reopened session's task that ends before its replay has caught up (its
/// worker died, the host stopped, a second open of the session failed) ends
/// the turn on its last `state`, as a first task does. A conversation an
/// earlier version saved, which read that `state` as part of the replay and
/// moved its cursor past it, takes it again once an attach says the task
/// has finished, and only once.
func checkReplayEnd() {
    // 加载失败或旧记录遗留忙碌态时，没有会话的停止请求应结束显示，
    // 但不得擅自把有 host 会话的记录标为结束。
    var orphan = ChatRecord(summary: ChatSummary(title: "旧会话", lastInteraction: Date(), isWorking: true))
    orphan.run = .running
    orphan.draft = ComposerDraft(text: "保留草稿")
    precondition(orphan.endRunWithoutSession())
    precondition(!orphan.summary.isWorking && orphan.run == .ended)
    precondition(orphan.draft.text == "保留草稿")
    precondition(orphan.endRunWithoutSession(), "重复收尾保持一致")
    orphan.sessionID = UUID().uuidString
    orphan.run = .running
    orphan.summary.isWorking = true
    precondition(!orphan.endRunWithoutSession())
    precondition(orphan.summary.isWorking && orphan.run == .running, "有会话时须等待 host 校准")

    // 更新打断压缩后，worker 在历史边界内补 cancelled；旧版本把它吞作回放。
    let compactHistory = [
        event(1, "prompt"), event(2, "finished"),
        event(3, "compactionStarted"), event(4, "compactionFinished", ["outcome": .string("compacted")]),
        event(5, "prompt"), event(6, "finished"), event(7, "compactionStarted"),
    ]
    var compactReplay = ChatRecord(summary: ChatSummary(title: "压缩恢复", lastInteraction: Date(), isWorking: true))
    compactReplay.events = compactHistory
    compactReplay.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
    precondition(compactReplay.take(Array(compactHistory.prefix(4))).isEmpty, "已显示的压缩结果仍只回放")
    compactReplay = try! JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(compactReplay))
    var legacyReplayJSON = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(compactReplay)) as! [String: Any]
    var legacyReplayFields = legacyReplayJSON["replay"] as! [String: Any]
    legacyReplayFields.removeValue(forKey: "activityEnds")
    legacyReplayJSON["replay"] = legacyReplayFields
    var legacyReplay = try! JSONDecoder().decode(ChatRecord.self, from: JSONSerialization.data(withJSONObject: legacyReplayJSON))
    precondition(legacyReplay.restoreReplayBoundaries() && legacyReplay.cursor == .start, "旧版部分回放只重读边界，不丢历史")
    precondition(!legacyReplay.restoreReplayBoundaries(), "回放边界迁移只做一次")
    precondition(legacyReplay.take(compactHistory).isEmpty, "重读完整旧历史不追加重复消息")
    precondition(compactReplay.take(Array(compactHistory.dropFirst(4))).isEmpty)
    let cancelledCompaction = event(8, "compactionFinished", ["outcome": .string("cancelled"), "historical": .bool(true)])
    precondition(compactReplay.take([cancelledCompaction]) == [cancelledCompaction], "恢复补写的压缩结束必须保留")
    precondition(legacyReplay.take([cancelledCompaction]) == [cancelledCompaction], "旧版部分回放升级后也必须收到恢复结束")
    precondition(compactReplay.take([cancelledCompaction]).isEmpty, "重试批次不能重复追加回执")
    let compactRecovered = ChatTranscript(events: compactReplay.events) { _ in nil }
    precondition(!compactRecovered.isWorking && !compactRecovered.isCompacting, "无需发送新消息也应结束旧压缩")
    let afterRecovery = event(9, "prompt")
    precondition(compactReplay.take([afterRecovery]) == [afterRecovery] && compactReplay.replay == nil)
    precondition(ChatTranscript(events: compactReplay.events) { _ in nil }.isWorking, "恢复后新轮次仍可开始")

    // 轮次的 aborted 回执也会在新任务的初始历史边界里，不得只修压缩。
    var turnReplay = ChatRecord(summary: ChatSummary(title: "轮次恢复", lastInteraction: Date(), isWorking: true))
    turnReplay.events = [event(1, "prompt"), event(2, "messageStarted")]
    turnReplay.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
    precondition(turnReplay.take(turnReplay.events).isEmpty)
    let abortedTurn = event(3, "finished", ["reason": .string("aborted"), "historical": .bool(true)])
    precondition(turnReplay.take([abortedTurn]) == [abortedTurn])
    precondition(!ChatTranscript(events: turnReplay.events) { _ in nil }.isWorking)

    // 宿主确认整个任务结束时，两种忙碌态都要收尾；连接丢失不等于任务终态。
    var compactActivity = ChatRunActivity(events: [event(1, "compactionStarted")])
    precondition(compactActivity.isActive(runEnded: false), "真实压缩任务重连时仍保持忙碌")
    precondition(!compactActivity.isActive(runEnded: true), "已结束的任务不能仅因压缩标记而忙碌")
    compactActivity.endTask()
    precondition(!compactActivity.isWorking && !compactActivity.isCompacting)
    for tail in [[event(1, "compactionStarted")], [event(1, "prompt"), event(2, "compactionStarted")]] {
        let endedCompaction = ChatTranscript(events: tail, runEnded: true) { _ in nil }
        precondition(!endedCompaction.isWorking && !endedCompaction.isCompacting)
    }
    let staleCompaction = ChatTranscript(events: [
        event(1, "compactionStarted"), event(2, "prompt"), event(3, "finished"),
    ]) { _ in nil }
    precondition(!staleCompaction.isWorking && !staleCompaction.isCompacting, "旧版漏回执不能跨新轮次残留")
    let liveCompaction = ChatTranscript(events: [event(1, "compactionStarted")]) { _ in nil }
    precondition(liveCompaction.isCompacting, "不能把仍在运行的压缩当成遗留标记清掉")

    // 防重快照随会话保存，不随页面重建或进程重启丢失；旧记录仍可读取。
    var automatic = ChatRecord(summary: ChatSummary(title: "自动压缩", lastInteraction: Date()))
    let fill = ChatCompactionAttempt(tokens: 800, window: 1000)
    automatic.automaticCompactionAttempt = fill
    let automaticData = try! JSONEncoder().encode(automatic)
    let restoredAutomatic = try! JSONDecoder().decode(ChatRecord.self, from: automaticData)
    precondition(restoredAutomatic.automaticCompactionAttempt == fill)
    precondition(restoredAutomatic.automaticCompactionAttempt != ChatCompactionAttempt(tokens: 900, window: 1000))
    var legacy = try! JSONSerialization.jsonObject(with: automaticData) as! [String: Any]
    legacy.removeValue(forKey: "automaticCompactionAttempt")
    let legacyData = try! JSONSerialization.data(withJSONObject: legacy)
    precondition(try! JSONDecoder().decode(ChatRecord.self, from: legacyData).automaticCompactionAttempt == nil)

    let askedID = UUID()
    // A turn the conversation saw start and not end: its task stopped while
    // the app was away. The new task replays it, numbered as it was.
    let history = [
        event(1, "prompt", ["id": .string(askedID.uuidString), "text": .string("Build it")]),
        event(2, "messageStarted"), event(3, "thinking", ["text": .string("Reading the project")]),
        event(4, "approvalRequested", ["approvalID": .string("a1"), "tool": .string("shell_run"), "arguments": .string("{}")]),
        event(5, TaskEvent.stateKind, ["state": .string(TaskState.waitingForApproval.rawValue)]),
        event(6, "approvalResolved", ["approvalID": .string("a1"), "decision": .string("approve")]),
        event(7, TaskEvent.stateKind, ["state": .string(TaskState.running.rawValue)]),
        event(8, "text", ["text": .string("Building")]),
    ]
    let replay = history
    let shown = ChatTranscript(events: history) { _ in nil }
    precondition(shown.isWorking, "the turn it saw start still runs")

    func reopened() -> ChatRecord {
        var record = ChatRecord(summary: ChatSummary(title: "Build", lastInteraction: Date(), isWorking: true))
        record.task = TaskHandle(taskID: .make(), kind: .agent)
        record.events = history
        record.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
        return record
    }

    func end(_ seq: Int, _ state: TaskState) -> TaskEvent {
        event(UInt64(seq), TaskEvent.stateKind, [
            "state": .string(state.rawValue), "message": .string("The background process for this task stopped."),
        ])
    }

    func finished(_ record: ChatRecord, _ state: TaskState, at end: TaskEvent, carrying events: [TaskEvent]) -> TaskEventBatch {
        TaskEventBatch(taskID: record.task!.taskID, events: events, state: state, lastSeq: end.seq, finished: true)
    }

    // The task ends after so much of the replay: none of it (a second open
    // failed), part of it, or all of it, with the end in the same batch or
    // in one of its own.
    let cuts: [(state: TaskState, replayed: Int, inOneBatch: Bool)] = [
        (.failed, 0, true), (.interrupted, 3, true), (.interrupted, 5, false),
        (.failed, replay.count, false), (.cancelled, replay.count, true), (.cancelled, 7, false),
    ]
    for cut in cuts {
        var record = reopened()
        let ending = end(cut.replayed + 1, cut.state)
        let read = Array(replay.prefix(cut.replayed))
        let taken = cut.inOneBatch ? record.take(read + [ending]) : record.take(read) + record.take([ending])
        precondition(taken == [ending], "a task that ends \(cut.state) during its replay is taken at its end")
        precondition(record.events == history + [ending] && record.replay == nil && record.cursor == ending.seq,
                     "that one event, which ends the replay")
        let ended = ChatTranscript(events: record.events) { _ in nil }
        precondition(!ended.isWorking && !ended.isCompacting, "and the turn ends, as it does in a first task")
        precondition(ended.messages.map(\.id) == shown.messages.map(\.id), "on the rows it showed, none added or lost")
        precondition(record.missedEnd(of: finished(record, cut.state, at: ending, carrying: [ending]), isWorking: ended.isWorking) == nil,
                     "and an attach that says the task finished finds nothing missing")
    }

    // The states an approval sets are part of the replay, read past with the
    // rest of it; the first message it has not seen ends it, as before.
    var replayed = reopened()
    precondition(replayed.take(Array(replay.prefix(5))).isEmpty && replayed.take(Array(replay.dropFirst(5))).isEmpty,
                 "waitingForApproval and running are read past")
    precondition(replayed.events == history && replayed.cursor == replay.last?.seq)
    let next = event(UInt64(replay.count + 1), "prompt", ["id": .string(UUID().uuidString), "text": .string("And test it")])
    precondition(replayed.take([next]) == [next] && replayed.replay == nil, "a new message ends the replay")
    let goingOn = ChatTranscript(events: replayed.events) { _ in nil }.messages
    precondition(Array(goingOn.prefix(shown.messages.count)).map(\.id) == shown.messages.map(\.id),
                 "and the rows before it stay as they were")

    // A conversation an earlier version saved: it read the task's end as
    // part of the replay, which still waits, and its cursor is past it.
    var swallowed = reopened()
    let lost = end(replay.count + 1, .interrupted)
    precondition(swallowed.take(replay).isEmpty)
    swallowed.replay?.cursor = lost.seq
    let atEnd = finished(swallowed, .interrupted, at: lost, carrying: [])
    precondition(swallowed.take(atEnd.events).isEmpty, "an attach past the cursor brings nothing")
    var cache = ChatTranscriptCache()
    func cached(_ record: ChatRecord) -> ChatTranscript {
        cache.transcript(of: record, now: Date(), isFollowed: { _ in true }, conversationTitle: { _ in nil }) { _ in nil }
    }
    let stuck = cached(swallowed)
    precondition(stuck.isWorking && stuck.messages.count == shown.messages.count + 1 && stuck.messages.last?.role.isThinking == true,
                 "so the turn runs on, a running summary standing in under its reply")
    precondition(swallowed.missedEnd(of: atEnd, isWorking: stuck.isWorking) == lost.seq,
                 "until an attach says the task finished: its end is its last event")
    let running = TaskEventBatch(taskID: atEnd.taskID, events: [], state: .running, lastSeq: lost.seq, finished: false)
    precondition(swallowed.missedEnd(of: running, isWorking: true) == nil, "a task still running has no end to miss")
    let empty = TaskEventBatch(taskID: atEnd.taskID, events: [], state: .failed, lastSeq: .start, finished: true)
    precondition(swallowed.missedEnd(of: empty, isWorking: true) == nil, "nor one with no events")
    let ahead = finished(swallowed, .interrupted, at: end(replay.count + 2, .interrupted), carrying: [])
    precondition(swallowed.missedEnd(of: ahead, isWorking: true) == nil, "and an end the cursor has not reached is not missed")

    var refused = swallowed
    precondition(!refused.takeMissedEnd(event(lost.seq.rawValue, TaskEvent.stateKind, ["state": .string("running")]), at: lost.seq),
                 "only a state that ends the task is taken")
    precondition(!refused.takeMissedEnd(end(replay.count, .interrupted), at: lost.seq), "and only at the task's last event")
    precondition(!refused.takeMissedEnd(nil, at: lost.seq), "an end that could not be read again is not made up")
    precondition(refused.events == history && refused.replay != nil, "none of them adds an event")
    precondition(!refused.summary.isWorking, "but the row stops working all the same: the task has ended")

    precondition(swallowed.takeMissedEnd(lost, at: lost.seq), "the end read again is taken")
    precondition(swallowed.events == history + [lost] && swallowed.replay == nil && swallowed.cursor == lost.seq,
                 "that one event, which ends the replay")
    let converged = cached(swallowed)
    precondition(!converged.isWorking && !swallowed.summary.isWorking, "and the turn ends")
    precondition(converged.messages.map(\.id) == shown.messages.map(\.id), "on the rows it showed, the stand-in gone")
    precondition(converged.messages == ChatTranscript(events: swallowed.events) { _ in nil }.messages,
                 "the runtime's transcript reads it as one built from every event does")
    precondition(swallowed.take(atEnd.events).isEmpty)
    precondition(swallowed.missedEnd(of: atEnd, isWorking: converged.isWorking) == nil,
                 "a second attach that says the task finished finds nothing missing")
    precondition(!swallowed.takeMissedEnd(lost, at: lost.seq) && swallowed.events.count == history.count + 1,
                 "and the end is taken once")
    // Queue-only changes must leave replay too: recovery, reorder, editing
    // and deletion do not need a new user prompt to become visible.
    let waitingID = UUID()
    func queue(_ seq: UInt64, text: String?, paused: Bool) -> TaskEvent {
        event(seq, "pendingQueue", [
            "paused": .bool(paused),
            "messages": .array(text.map { [.object([
                "id": .string(waitingID.uuidString), "text": .string($0),
                "attachments": .array([]), "editing": .bool(false),
            ])] } ?? []),
        ])
    }
    let oldQueue = queue(9, text: "Waiting", paused: false)
    var queueRecord = reopened()
    queueRecord.events.append(oldQueue)
    queueRecord.reopen(as: TaskHandle(taskID: .make(), kind: .agent))
    precondition(queueRecord.take(history).isEmpty)
    // A relaunch while partway through replay keeps the remaining count.
    queueRecord = try! JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(queueRecord))
    precondition(queueRecord.take([oldQueue]).isEmpty)
    let recovered = queue(10, text: "Waiting", paused: true)
    precondition(queueRecord.take([recovered]) == [recovered] && queueRecord.replay == nil)
    precondition(ChatTranscript(events: queueRecord.events) { _ in nil }.pendingPaused)
    let edited = queue(11, text: "Edited", paused: true)
    precondition(queueRecord.take([edited]) == [edited])
    precondition(ChatTranscript(events: queueRecord.events) { _ in nil }.pendingMessages.first?.text == "Edited")
    let deleted = queue(12, text: nil, paused: true)
    precondition(queueRecord.take([deleted]) == [deleted])
    precondition(ChatTranscript(events: queueRecord.events) { _ in nil }.pendingMessages.isEmpty)
    var noOldQueue = reopened()
    precondition(noOldQueue.take(history).isEmpty)
    precondition(noOldQueue.take([oldQueue]) == [oldQueue], "a first pending receipt ends replay")
    print("ok: replay end, partial replay recovery and queue-only changes after reopening")
}
