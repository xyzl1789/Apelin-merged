import ApelinProtocol
import Foundation

func checkChatForkHistory() {
    let suite = "chat-opening-test." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let first = UUID()
    let second = UUID()
    precondition(ChatOpeningRecovery.pending(in: defaults) == nil)
    ChatOpeningRecovery.begin(first, in: defaults)
    precondition(ChatOpeningRecovery.pending(in: defaults) == first, "异常退出保留未完成打开的 UUID")
    ChatOpeningRecovery.begin(second, in: defaults)
    ChatOpeningRecovery.finish(first, in: defaults)
    precondition(ChatOpeningRecovery.pending(in: defaults) == second, "旧加载不得清除新会话标记")
    ChatOpeningRecovery.finish(second, in: defaults)
    ChatOpeningRecovery.finish(second, in: defaults)
    precondition(ChatOpeningRecovery.pending(in: defaults) == nil, "成功打开可重复收尾")

    let historical = TaskEvent(
        seq: EventSeq(1),
        kind: "message",
        payload: .object(["text": .string("old"), "historical": .bool(true)])
    )
    let realtime = TaskEvent(seq: EventSeq(2), kind: "message", payload: .object(["text": .string("new")]))
    precondition(ChatFork.isHistorical(historical), "historical replay marker is recognized")
    precondition(!ChatFork.isHistorical(realtime), "ordinary events remain realtime")
    var fork = ChatRecord(summary: ChatSummary(title: "Fork", lastInteraction: Date()), sessionID: UUID().uuidString)
    precondition(ChatFork.needsHistoryLoad(fork, isFollowed: false), "empty forks load without a send")
    precondition(!ChatFork.needsHistoryLoad(fork, isFollowed: true), "a replay already followed is not opened again")
    fork.events = [historical]
    precondition(ChatFork.needsHistoryLoad(fork, isFollowed: false), "a partial replay resumes after reopening")
    fork.sessionID = nil
    precondition(!ChatFork.needsHistoryLoad(fork, isFollowed: false), "a draft alone never starts a session")
    print("ok: fork history is distinguished from live events and loads on selection")
}
