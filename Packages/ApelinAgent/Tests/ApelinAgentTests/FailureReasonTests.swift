@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAgent
import KWWKAI
import Testing

@Suite("Why a model request failed, for the reader")
struct FailureReasonTests {
    private static func transport(_ code: Int) -> ProviderFailure {
        ProviderFailure(message: "failed", transportDomain: NSURLErrorDomain, transportCode: code)
    }

    private static func status(_ status: Int, _ message: String = "refused") -> ProviderFailure {
        ProviderFailure(message: message, httpStatus: status)
    }

    @Test(arguments: [NSURLErrorNotConnectedToInternet, NSURLErrorDataNotAllowed, NSURLErrorInternationalRoamingOff])
    func `URLSession's own word for a device off the network is offline, route or none`(code: Int) {
        #expect(FailureReason.of(Self.transport(code), hasRoute: true) == .offline)
        #expect(FailureReason.of(Self.transport(code), hasRoute: false) == .offline)
    }

    @Test(arguments: [NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost])
    func `a provider out of reach is the network's failure with a route, and offline without`(code: Int) {
        #expect(FailureReason.of(Self.transport(code), hasRoute: true) == .network)
        #expect(FailureReason.of(Self.transport(code), hasRoute: false) == .offline)
    }

    @Test
    func `a request that timed out says so, unless there is no route to wait on`() {
        #expect(FailureReason.of(Self.transport(NSURLErrorTimedOut), hasRoute: true) == .timeout)
        #expect(FailureReason.of(Self.transport(NSURLErrorTimedOut), hasRoute: false) == .offline)
    }

    @Test
    func `a failed handshake is the network's failure, a certificate that will not do is not`() {
        #expect(FailureReason.of(Self.transport(NSURLErrorSecureConnectionFailed), hasRoute: true) == .network)
        #expect(FailureReason.of(Self.transport(NSURLErrorServerCertificateUntrusted), hasRoute: true) == .invalidRequest)
    }

    @Test
    func `what the provider answered is read by its status`() {
        #expect(FailureReason.of(Self.status(401), hasRoute: true) == .authentication)
        #expect(FailureReason.of(Self.status(402), hasRoute: true) == .quota)
        #expect(FailureReason.of(Self.status(429), hasRoute: true) == .rateLimit)
        #expect(FailureReason.of(Self.status(503), hasRoute: true) == .server)
        #expect(FailureReason.of(Self.status(400, "prompt is too long: 250000 tokens > 200000 maximum"), hasRoute: true) == .contextOverflow)
    }

    @Test
    func `403拒绝访问但不是配额耗尽时返回权限拒绝`() {
        #expect(FailureReason.of(Self.status(403), hasRoute: true) == .accessDenied)
    }

    @Test
    func `403配额耗尽仍由SpentAllowance优先归类为配额`() {
        #expect(FailureReason.of(Self.status(403, "quota_exceeded"), hasRoute: true) == .quota)
    }

    /// kwwk's preflight, when compacting cannot bring the conversation under
    /// the window, as a device saw it with a 65,000-token window and one
    /// 100 KB tool result: the chat is too long, said as such.
    @Test
    func `a conversation compaction cannot fit in the window is too long`() {
        for message in [
            "context is too large and compaction failed: compaction left 51590 tokens, above the recovery target of 39000",
            "context is too large and could not be compacted",
            "context requires approximately 70000 input tokens, exceeding the usable 60000-token input budget even after compaction",
        ] {
            #expect(FailureReason.of(ProviderFailure(message: message), hasRoute: true) == .contextOverflow, "\(message)")
        }
        // a provider's own refusal in those words keeps its status's reading
        #expect(FailureReason.of(Self.status(503, "context is too large and compaction failed"), hasRoute: true) == .server)
    }

    @Test
    func `无效请求保留既有分类，取消不另附原因`() {
        #expect(FailureReason.of(Self.status(400, "malformed request"), hasRoute: true) == .invalidRequest)
        #expect(FailureReason.of(Self.status(404, "model not found"), hasRoute: true) == .invalidRequest)
        #expect(FailureReason.of(ProviderFailure(message: "Request was aborted", transportDomain: NSURLErrorDomain, transportCode: -999), hasRoute: true) == nil)
    }

    @Test
    func `an error a request threw is read as kwwk captures it`() {
        #expect(FailureReason.of(URLError(.notConnectedToInternet), hasRoute: true) == .offline)
        #expect(FailureReason.of(URLError(.cannotFindHost), hasRoute: true) == .network)
        #expect(FailureReason.of(CocoaError(.fileNoSuchFile), hasRoute: true) == nil)
    }

    /// A session's log from before errors had reasons reads as it did, and
    /// an error with none is written as it was.
    @Test
    func `an error recorded without a reason still reads, and one is written only when named`() throws {
        let old = try JSONDecoder().decode(AgentSessionEvent.self, from: Data(#"{"error":{"message":"The provider stopped"}}"#.utf8))
        #expect(old == .error(message: "The provider stopped"))
        let plain = try String(decoding: JSONEncoder().encode(AgentSessionEvent.error(message: "x")), as: UTF8.self)
        #expect(!plain.contains("reason"))
        let named = try JSONEncoder().encode(AgentSessionEvent.error(message: "x", reason: .offline))
        #expect(try JSONDecoder().decode(AgentSessionEvent.self, from: named) == .error(message: "x", reason: .offline))
        let newer = try JSONDecoder().decode(
            AgentSessionEvent.self,
            from: Data(#"{"error":{"message":"x","reason":"eclipse"}}"#.utf8),
        )
        #expect(newer == .error(message: "x", reason: ApelinError.Reason(rawValue: "eclipse")), "a reason not known yet still reads")
    }

    @Test
    func `错误原因在关闭与重开事件日志后仍完整保留`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let id = UUID().uuidString
        let log = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        let events: [AgentSessionEvent] = [
            .error(message: "旧版无原因错误"),
            .error(message: "设备离线", reason: .offline),
            .error(message: "未来原因", reason: .init(rawValue: "eclipse")),
        ]
        for event in events { try await log.append(event) }
        await log.close()

        let reopened = try SessionEventLog(sessionsRoot: home.dataRoot.sessions, sessionID: id)
        let records = try await reopened.records(afterSeq: 0)
        #expect(records.map(\.event) == events)
        #expect(records.map(\.seq) == [1, 2, 3])
        await reopened.close()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [400, 401, 402, 429])
    func `模型返回或抛出的错误均记录分类且不误触发轮数恢复`(_ thrown: Bool, _ status: Int) async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let faux = await registerFauxProvider()
        defer { faux.unregister() }
        let message = "供应商拒绝请求"
        var failure = ProviderFailure(message: message, httpStatus: status)
        failure.shouldRetry = false
        // 捕获不可变副本，确保假供应商的并发闭包只读已冻结的错误。
        let settled = failure
        if thrown {
            faux.setResponses([.factory { _, _, _, _ in throw settled }])
        } else {
            var reply = fauxAssistantMessage("", stopReason: .error, errorMessage: message)
            reply.failure = settled
            faux.setResponses([.message(reply)])
        }
        let expected: ApelinError.Reason = switch status {
        case 400: .invalidRequest
        case 401: .authentication
        case 402: .quota
        default: .rateLimit
        }
        let session = try await AgentSession(
            configuration: AgentSessionConfiguration(
                project: home.project,
                provider: .registered(faux.getModel()),
                approval: ApprovalPolicy(mode: .relaxed),
                dataRoot: home.dataRoot,
                network: NetworkPath { true },
            ),
            backend: MockBackend(),
            digests: MockDigestLedger(),
            credentials: DeliveredCredentialSource(),
        )
        try await session.prompt("核对模型错误")
        await session.waitForIdle()
        let events = try await session.log.records(afterSeq: 0).map(\.event)
        #expect(events.contains(.error(message: message, reason: expected)))
        #expect(events.last == .finished(reason: .failed))
        #expect(faux.state.callCount == 1)
        #expect(!events.contains(.reconnecting) && !events.contains(.waitingForNetwork))
        #expect(!events.contains(.compactionStarted))
        await session.close()
    }

    // MARK: - A sign-in's exchange

    @Test(.timeLimit(.minutes(1)))
    func `an operation that ends in time answers as it did`() async throws {
        #expect(try await Deadline.within(.seconds(5)) { 7 } == 7)
        await #expect(throws: URLError.self) {
            _ = try await Deadline.within(.seconds(5)) { throw URLError(.cannotFindHost) }
        }
    }

    /// One that does not answer its cancellation either, as a request to a
    /// connection that answers nothing may not. The operation ends only when
    /// the test lets it, after the limit has answered, so the answer cannot
    /// have waited for it however slow the machine: no wall clock is read
    /// (one was, and a loaded runner failed it).
    @Test(.timeLimit(.minutes(1)))
    func `an operation past its limit is no longer waited for`() async throws {
        let gate = Gate()
        await #expect(throws: Deadline.Exceeded.self) {
            _ = try await Deadline.within(.milliseconds(100)) {
                await gate.wait()
                await gate.markEnded()
                return 1
            }
        }
        #expect(await !gate.ended, "the limit answered while the operation still ran")
        await gate.open()
    }

    /// An operation's end, held until the test opens it; waiting on it
    /// ignores cancellation, as a request that answers nothing does.
    private actor Gate {
        private var isOpen = false
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var ended = false

        func wait() async {
            await withCheckedContinuation { continuation in
                if isOpen {
                    continuation.resume()
                } else {
                    waiter = continuation
                }
            }
        }

        func open() {
            isOpen = true
            waiter?.resume()
            waiter = nil
        }

        func markEnded() {
            ended = true
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `a caller that is cancelled stops waiting too`() async throws {
        let waiting = Task {
            try await Deadline.within(.seconds(30)) {
                try await Task.sleep(for: .seconds(30))
                return 1
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        waiting.cancel()
        await #expect(throws: CancellationError.self) { _ = try await waiting.value }
    }
}
