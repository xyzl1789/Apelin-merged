import Foundation
import KWWKAgent
import KWWKAI
import Testing

struct ConversationTurnLimitRecoveryTests {
    @Test(.timeLimit(.minutes(1)))
    func aDifferentProviderErrorDoesNotTriggerCompaction() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        var refused = fauxAssistantMessage("", stopReason: .error, errorMessage: "Invalid API key.")
        refused.failure = ProviderFailure(message: "Invalid API key.", httpStatus: 401)
        faux.setResponses([
            .message(fauxAssistantMessage("first completed")),
            .message(fauxAssistantMessage("second completed")),
            .message(refused),
        ])
        let session = try await Self.openSession(home, faux)
        try await session.prompt("first")
        await session.waitForIdle()
        try await session.prompt("second")
        await session.waitForIdle()
        try await session.prompt("continue")
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(faux.state.callCount == 3)
        #expect(!events.contains(.compactionStarted))
        #expect(events.contains { if case .error = $0 { return true }; return false })
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aDirectlyThrownTurnLimitCompactsAndContinuesOnce() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let limitText = "This conversation has reached 100 model turns. Run /compact or /new to continue."
        faux.setResponses([
            .message(fauxAssistantMessage("first completed")),
            .message(fauxAssistantMessage("second completed")),
            .factory { _, _, _, _ in throw ProviderFailure(message: limitText) },
            .message(fauxAssistantMessage("Summary: resume the current task.")),
            .message(fauxAssistantMessage("continued after automatic compaction")),
        ])
        let session = try await Self.openSession(home, faux)
        try await session.prompt("first")
        await session.waitForIdle()
        try await session.prompt("second")
        await session.waitForIdle()
        try await session.prompt("continue the existing task")
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(faux.state.callCount == 5)
        #expect(events.contains(.compactionStarted))
        #expect(events.contains(.messageFinished(text: "continued after automatic compaction")))
        #expect(!events.contains { if case .error = $0 { return true }; return false })
        #expect(events.last == .finished(reason: .completed))
        await session.close()
    }

    @Test(.timeLimit(.minutes(1)))
    func aRetryThatHitsTheSameTurnLimitStopsAfterOneAutomaticCompaction() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let limitText = "This conversation has reached 100 model turns. Run /compact or /new to continue."
        func limitedReply() -> AssistantMessage {
            var message = fauxAssistantMessage("", stopReason: .error, errorMessage: limitText)
            message.failure = ProviderFailure(message: limitText)
            return message
        }
        faux.setResponses([
            .message(fauxAssistantMessage("first completed")),
            .message(fauxAssistantMessage("second completed")),
            .message(limitedReply()),
            .message(fauxAssistantMessage("Summary: resume the current task.")),
            .message(limitedReply()),
        ])
        let session = try await Self.openSession(home, faux)
        try await session.prompt("first")
        await session.waitForIdle()
        try await session.prompt("second")
        await session.waitForIdle()
        try await session.prompt("continue")
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(faux.state.callCount == 5)
        #expect(events.count(where: { $0 == .compactionStarted }) == 1)
        #expect(events.count(where: { if case .error = $0 { return true }; return false }) == 1)
        #expect(events.last.map { if case .finished(reason: .failed) = $0 { return true }; return false } == true)
        await session.close()
    }

    private static func openSession(
        _ home: TemporaryHome,
        _ faux: FauxProviderRegistration
    ) async throws -> AgentSession {
        try await AgentSession(
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
    }
}
