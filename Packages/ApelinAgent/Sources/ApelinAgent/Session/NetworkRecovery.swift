import Foundation
import KWWKAgent
import KWWKAI
import Network

/// Whether the device has a route to the network, which a model request the
/// network failed waits for (`NetworkRecovery`).
public struct NetworkPath: Sendable {
    /// False only while the system says there is no route; true before it
    /// has said anything.
    public var isSatisfied: @Sendable () -> Bool

    public init(isSatisfied: @escaping @Sendable () -> Bool) {
        self.isSatisfied = isSatisfied
    }

    /// The system's answer: `NWPathMonitor`'s latest, from one monitor a
    /// process, started when a session is first configured.
    public static var system: NetworkPath {
        let monitor = PathMonitor.shared
        return NetworkPath { monitor.isSatisfied }
    }
}

/// `NWPathMonitor` kept running, its latest status readable from any task.
private final class PathMonitor: @unchecked Sendable {
    static let shared = PathMonitor()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    @objc private dynamic var unsatisfied = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            self?.update(unsatisfied: path.status == .unsatisfied)
        }
        monitor.start(queue: DispatchQueue(label: "wiki.qaq.apelin.agent.network-path"))
    }

    /// A path that needs a connection counts: the request may bring it up.
    @objc dynamic var isSatisfied: Bool {
        lock.withLock { !unsatisfied }
    }

    @objc private dynamic func update(unsatisfied: Bool) {
        lock.withLock { self.unsatisfied = unsatisfied }
    }
}

/// Model requests the network failed, answered once it is back.
///
/// kwwk tries a failed request eight times within about a minute and a half
/// (`ProviderRetryPolicy`; five times in fifteen seconds before 0.1.118),
/// and takes a failed TLS handshake for a refused
/// request it never tries again. A phone that changes networks or wakes
/// from sleep is often offline for longer, and the turn ended with "The
/// Internet connection appears to be offline." or "An SSL error has
/// occurred…" for a spell it would have outlived.
///
/// Around the requests a session's agent makes (`AgentOptions.streamFn`),
/// an attempt the network failed before kwwk had anything of the reply:
/// - is handed to kwwk only once `NetworkPath` has a route again, or after
///   `Patience.pathWait`, so kwwk's own retry goes out when it can get
///   through; kwwk still retries it and counts the attempts;
/// - is asked again here when its TLS handshake failed, at most
///   `Patience.secureConnectionRetries` times, after a pause.
///
/// `onWait` 在每次等待前报告原因。已经输出文本、思考或工具调用的
/// 请求仍由 kwwk 通过 `streamRewind` 撤回和重试；工具只在回复确定后执行一次。
enum NetworkRecovery {
    /// 失败请求在下次尝试前等待的条件。
    enum Wait: Equatable, Sendable {
        case route
        case handshake
    }

    struct Patience: Sendable {
        /// The longest one failure waits for a route, in milliseconds.
        var pathWait: UInt64 = 30000
        /// How often the route is looked at meanwhile.
        var pathPoll: UInt64 = 100
        /// The pause before a failed handshake is asked again.
        var secureConnectionPause: UInt64 = 1000
        var secureConnectionRetries = 2

        static let standard = Patience()
    }

    /// `inner` with the failures above waited on, or asked again.
    static func stream(
        path: NetworkPath,
        patience: Patience = .standard,
        inner: @escaping StreamFn = { model, context, options in
            try await KWWKAI.stream(model: model, context: context, options: options)
        },
        onWait: @escaping @Sendable (Wait) async -> Void,
    ) -> StreamFn {
        { model, context, options in
            let cancellation = options?.cancellation
            let first: AssistantMessageStream
            do {
                first = try await cancellable(cancellation) {
                    try await inner(model, context, options)
                }
            } catch let failure as ProviderFailure {
                return failedStream(failure, model: model)
            }
            let (stream, continuation) = AssistantMessageStream.makeStream()
            let out = Output(continuation)
            Task {
                do {
                    try await cancellable(cancellation) {
                        try await relay(
                            first,
                            to: out,
                            path: path,
                            patience: patience,
                            cancellation: cancellation,
                            onWait: onWait,
                        ) {
                            try await inner(model, context, options)
                        }
                    }
                } catch {
                    // ProviderFailure can be thrown while creating or retrying a
                    // stream. Keep its HTTP/category fields on the terminal
                    // assistant message; turning it into an aborted reply makes
                    // AgentSession record an unclassified error.
                    if let failure = error as? ProviderFailure {
                        var failed = AssistantMessage(
                            content: [], api: model.api, provider: model.provider, model: model.id,
                            stopReason: .error, errorMessage: failure.message,
                        )
                        failed.failure = failure
                        finish(out, .error(reason: .error, error: failed), failed)
                    } else {
                        let stopped = stopped(AssistantMessage(
                            content: [], api: model.api, provider: model.provider, model: model.id,
                        ))
                        finish(out, .error(reason: .aborted, error: stopped), stopped)
                    }
                }
            }
            return stream
        }
    }

    /// Do not use a task group here: leaving its scope waits for every child,
    /// including a provider that ignores cancellation. The one-result stream
    /// releases our waiter independently; the operation is still cancelled,
    /// and a late result is discarded by the finished continuation.
    static func cancellable<Value: Sendable>(
        _ cancellation: CancellationHandle?,
        operation: @escaping @Sendable () async throws -> Value,
    ) async throws -> Value {
        try checkCancellation(cancellation)
        let (results, out) = AsyncThrowingStream<Value, Error>.makeStream()
        let task = Task {
            do {
                try checkCancellation(cancellation)
                out.yield(try await operation())
                out.finish()
            } catch {
                out.finish(throwing: error)
            }
        }
        let registration = cancellation?.onCancel { _ in
            out.finish(throwing: CancellationError())
            task.cancel()
        }
        defer {
            registration?.cancel()
            task.cancel()
        }
        var iterator = results.makeAsyncIterator()
        guard let result = try await iterator.next() else { throw CancellationError() }
        // A buffered result may win the iterator race against cancellation.
        try checkCancellation(cancellation)
        return result
    }

    private static func checkCancellation(_ cancellation: CancellationHandle?) throws {
        try Task.checkCancellation()
        try cancellation?.throwIfCancelled()
    }

    /// A failure kwwk tries again and a missing route explains: a
    /// connection dropped, refused or timed out.
    static func isLostConnection(_ failure: ProviderFailure) -> Bool {
        failure.isRetryable && [.transport, .timeout].contains(failure.category)
    }

    /// `NSURLErrorSecureConnectionFailed`: a TLS handshake that failed, as
    /// one does while the network changes under it. A certificate that will
    /// not do (-1201 to -1206) is another failure, never asked again.
    static func isFailedHandshake(_ failure: ProviderFailure) -> Bool {
        failure.transportDomain == NSURLErrorDomain && failure.transportCode == NSURLErrorSecureConnectionFailed
    }

    /// Hands each attempt's events to `out` as they come, and its end once
    /// judged: as it came, after a wait for the route, or asked again.
    private static func relay(
        _ first: AssistantMessageStream,
        to out: Output,
        path: NetworkPath,
        patience: Patience,
        cancellation: CancellationHandle?,
        onWait: @Sendable (Wait) async -> Void,
        ask: @escaping @Sendable () async throws -> AssistantMessageStream,
    ) async throws {
        var attempt = first
        // Whether kwwk has had any of the reply: a start alone carries
        // nothing, and the next attempt's start stands in for it.
        var answered = false
        var retries = 0
        while true {
            try checkCancellation(cancellation)
            var ending: AssistantMessageEvent?
            for await event in attempt {
                // A provider may have queued events before noticing Stop.
                try checkCancellation(cancellation)
                switch event {
                case .done, .error:
                    ending = event
                case .start:
                    out.push(event)
                default:
                    answered = true
                    out.push(event)
                }
            }
            let final = await attempt.result()
            try checkCancellation(cancellation)
            guard !answered, final.stopReason == .error, let failure = final.providerFailure else {
                finish(out, ending, final)
                return
            }
            let asksAgain = isFailedHandshake(failure) && retries < patience.secureConnectionRetries
            let lacksRoute = !asksAgain && isLostConnection(failure) && !path.isSatisfied()
            guard asksAgain || lacksRoute else {
                finish(out, ending, final)
                return
            }
            await onWait(lacksRoute ? .route : .handshake)
            try checkCancellation(cancellation)
            try await waitForRoute(path, patience: patience, cancellation: cancellation)
            if asksAgain {
                try await ProviderRetryPolicy.wait(patience.secureConnectionPause, cancellation: cancellation)
            }
            try checkCancellation(cancellation)
            guard asksAgain else {
                finish(out, ending, final)
                return
            }
            do {
                attempt = try await cancellable(cancellation, operation: ask)
            } catch {
                // Preserve the original failure when retry creation fails,
                // but never turn a cancelled retry back into a network error.
                try checkCancellation(cancellation)
                if error is CancellationError { throw error }
                finish(out, ending, final)
                return
            }
            retries += 1
        }
    }

    /// Returns once `path` has a route or `patience.pathWait` has passed;
    /// throws once the request is stopped.
    private static func waitForRoute(
        _ path: NetworkPath,
        patience: Patience,
        cancellation: CancellationHandle?,
    ) async throws {
        var waited: UInt64 = 0
        while !path.isSatisfied(), waited < patience.pathWait {
            try await ProviderRetryPolicy.wait(patience.pathPoll, cancellation: cancellation)
            waited += patience.pathPoll
        }
    }

    /// `push(terminal)` and `end` must be one operation: the relay can
    /// settle at the same time as its cancelled waiter. Stream.end alone
    /// cannot prevent both terminal events being queued before either end.
    private final class Output: @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AssistantMessageStream.Continuation
        @objc private dynamic var ended = false

        init(_ continuation: AssistantMessageStream.Continuation) {
            self.continuation = continuation
        }

        func push(_ event: AssistantMessageEvent) {
            lock.withLock {
                guard !ended else { return }
                continuation.push(event)
            }
        }

        func finish(_ ending: AssistantMessageEvent?, _ final: AssistantMessage) {
            lock.withLock {
                guard !ended else { return }
                ended = true
                if let ending { continuation.push(ending) }
                continuation.end(final)
            }
        }
    }

    private static func failedStream(_ failure: ProviderFailure, model: Model) -> AssistantMessageStream {
        let (stream, continuation) = AssistantMessageStream.makeStream()
        let out = Output(continuation)
        let partial = AssistantMessage(content: [], api: model.api, provider: model.provider, model: model.id)
        var failed = AssistantMessage(
            content: [], api: model.api, provider: model.provider, model: model.id,
            stopReason: .error, errorMessage: failure.message,
        )
        failed.failure = failure
        out.push(.start(partial: partial))
        finish(out, .error(reason: .error, error: failed), failed)
        return stream
    }

    private static func finish(
        _ out: Output,
        _ ending: AssistantMessageEvent?,
        _ final: AssistantMessage,
    ) {
        out.finish(ending, final)
    }

    /// What a provider ends a request stopped before its reply with.
    private static func stopped(_ failed: AssistantMessage) -> AssistantMessage {
        AssistantMessage(
            content: [],
            api: failed.api,
            provider: failed.provider,
            model: failed.model,
            stopReason: .aborted,
            errorMessage: "Request was aborted",
        )
    }
}
