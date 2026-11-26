import Foundation
import KWWKAI
import Testing

struct ConversationTurnLimitTests {
    @Test func recognizesOnlyTheExplicitProviderTurnLimitMessage() {
        #expect(ConversationTurnLimit.matches("当前会话模型已回复 100 轮，达到上限。Codex 请运行 /compact 或 /new。"))
        #expect(ConversationTurnLimit.matches("This conversation has reached 100 model turns. Run /compact or /new to continue."))
        #expect(!ConversationTurnLimit.matches("The model says this conversation has reached 100 model turns."))
        #expect(!ConversationTurnLimit.matches("Rate limit exceeded. Try again in 60 seconds."))
        #expect(!ConversationTurnLimit.matches("当前会话已达到用量上限，请 /compact。"))
        #expect(ConversationTurnLimit.assistantCount([
            .user(UserMessage(text: "one")),
            .assistant(fauxAssistantMessage("answer")),
            .toolResult(ToolResultMessage(toolCallId: "call", toolName: "read", content: [])),
        ]) == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func anExplicitTurnLimitCompactsAndContinuesOnceInTheSameSession() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let limitText = "当前会话模型已回复 100 轮，达到上限。请运行 /compact 或 /new。"
        var limited = fauxAssistantMessage("", stopReason: .error, errorMessage: limitText)
        limited.failure = ProviderFailure(message: limitText)
        faux.setResponses([
            .message(fauxAssistantMessage("first completed")),
            .message(fauxAssistantMessage("second completed")),
            .message(limited),
            .message(fauxAssistantMessage("Summary: continue the current task from its latest user request.")),
            .message(fauxAssistantMessage("continued after automatic compaction")),
        ])
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .confirm),
                dataRoot: home.dataRoot
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource()
        )
        try await session.prompt("first")
        await session.waitForIdle()
        try await session.prompt("second")
        await session.waitForIdle()
        try await session.prompt("continue the existing work")
        await session.waitForIdle()

        let records = try await session.log.records(afterSeq: 0)
        let events = records.map(\.event)
        #expect(faux.state.callCount == 5)
        #expect(events.contains(.compactionStarted))
        #expect(events.contains { event in
            guard case let .compactionFinished(result) = event else { return false }
            return result.outcome == .compacted
        })
        #expect(events.contains(.messageFinished(text: "continued after automatic compaction")))
        #expect(!events.contains { if case .error = $0 { return true }; return false })
        #expect(events.last == .finished(reason: .completed))
        let transcript = try await session.log.readTranscript()
        #expect(ConversationTurnLimit.assistantCount(transcript) == 1)
        #expect(CompactionRecap.summary(of: transcript)?.contains("continue the current task") == true)
        await session.close()
    }
}
