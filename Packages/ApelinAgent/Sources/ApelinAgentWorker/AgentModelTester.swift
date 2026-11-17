import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI

/// One independent model request: no agent loop, history, tools, or retry loop.
enum AgentModelTester {
    static func run(
        _ request: AgentModelTestRequest,
        credentials: any CredentialSource,
        progress: (@Sendable (AgentModelTestProgress) -> Void)? = nil,
    ) async -> AgentModelTestResponse {
        let cancellation = CancellationHandle()
        let report = ModelTestReport(cancelRequest: { cancellation.cancel() }, progress: progress)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                report.attach(continuation)
                let deadline = Task {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    report.finish(failure: "模型测试在 \(report.phaseName) 阶段 60 秒后超时。")
                }
                let operation = Task {
                    do {
                        try Task.checkCancellation()
                        try await perform(request, credentials: credentials, cancellation: cancellation, report: report)
                    } catch {
                        report.finish(failure: safeFailure(error, phase: report.phaseName))
                    }
                }
                report.attach(tasks: [operation, deadline])
            }
        } onCancel: {
            report.finish(failure: "模型测试已取消。")
        }
    }

    private static func perform(
        _ request: AgentModelTestRequest,
        credentials: any CredentialSource,
        cancellation: CancellationHandle,
        report: ModelTestReport,
    ) async throws {
        guard !request.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            report.finish(failure: "请先选择模型再测试。")
            return
        }
        if let unsupported = unsupportedPureHiProvider(request.provider) {
            report.finish(failure: unsupported)
            return
        }
        let configuration = try AgentWorker.provider(provider: request.provider, model: request.model)
        report.begin(.credentials)
        let resolved = try await ProviderResolver.resolve(configuration, credentials: credentials) { diagnostic in
            // The resolver emits this only after the saved credential read.
            // Do not keep the diagnostic or any credential in the report.
            if diagnostic.hasPrefix("provider credentials read in ") { report.begin(.preparation) }
        }
        try Task.checkCancellation()
        try cancellation.throwIfCancelled()
        report.begin(.authorization)
        let auth = try await resolved.authResolver?(resolved.model, nil)
        try Task.checkCancellation()
        try cancellation.throwIfCancelled()
        report.beginRequest()
        let stream = try await KWWKAI.stream(
            model: resolved.model,
            context: context(),
            options: options(auth: auth, cancellation: cancellation),
        )
        for await event in stream {
            try Task.checkCancellation()
            observe(event, report: report)
        }
        try Task.checkCancellation()
        let final = await stream.result()
        record(final, report: report, event: false)
        if let failure = final.providerFailure {
            report.finish(failure: safeFailure(failure, phase: "response"))
        } else if final.stopReason != .stop, final.stopReason != .length {
            report.finish(failure: "模型没有完成文本响应（\(final.stopReason.rawValue)）。")
        } else {
            report.finish()
        }
    }

    static func context() -> Context {
        Context(systemPrompt: nil, messages: [.user(UserMessage(text: "Hi"))], tools: nil)
    }

    static func options(auth: ResolvedProviderAuth?, cancellation: CancellationHandle) -> StreamOptions {
        StreamOptions(
            maxTokens: 2048,
            transport: .sse,
            cacheRetention: CacheRetention.none,
            maxRetryDelayMs: 0,
            resolvedAuth: auth,
            reasoning: nil,
            cancellation: cancellation,
            toolChoice: ToolChoice.none,
            verbose: false,
        )
    }

    /// `start` can be emitted locally, before a connection. Text-start is not
    /// first text: record only a snapshot that actually contains characters.
    static func observe(_ event: AssistantMessageEvent, report: ModelTestReport) {
        switch event {
        case .start:
            break
        case let .textStart(_, partial), let .textDelta(_, _, partial), let .textEnd(_, _, partial),
             let .thinkingStart(_, partial), let .thinkingDelta(_, _, partial), let .thinkingEnd(_, _, partial),
             let .toolCallStart(_, partial), let .toolCallDelta(_, _, partial), let .toolCallEnd(_, _, partial):
            record(partial, report: report, event: true)
        case let .done(_, message):
            record(message, report: report, event: true)
        case let .error(_, message):
            // Errors may be produced locally (encoding/cancellation), not by
            // a remote event. Keep content, but don't fabricate a first event.
            record(message, report: report, event: false)
        }
    }

    private static func record(_ message: AssistantMessage, report: ModelTestReport, event: Bool) {
        let text = message.content.compactMap { block -> String? in
            if case let .text(value) = block { return value.text }
            return nil
        }.joined()
        let thinking = message.content.compactMap { block -> String? in
            if case let .thinking(value) = block { return value.thinking }
            return nil
        }.joined()
        report.record(text: text, thinking: thinking, event: event)
    }

    /// Fixed SDK transports which add required/default instructions even for
    /// nil systemPrompt. Refuse before resolving credentials or sending Hi.
    static func unsupportedPureHiProvider(_ provider: AgentProvider) -> String? {
        switch provider {
        case .anthropicOAuth:
            return "该供应商会附加必需的 Claude Code 身份提示，因此无法进行纯 Hi 测试。"
        case .cursor:
            return "该供应商会附加默认系统提示，因此无法进行纯 Hi 测试。"
        case .qoder, .qoderCN:
            return "该供应商会附加必需的助手系统提示，因此无法进行纯 Hi 测试。"
        default:
            return nil
        }
    }

    /// No raw error body, URL, header, provider message or token crosses IPC.
    static func safeFailure(_ error: Error, phase: String) -> String {
        if error is ProviderResolutionError { return "没有已保存的登录，请在模型供应商中重新登录。" }
        let failure = ProviderFailure.capture(error)
        let reason: String
        switch failure.outcome {
        case .signInRequired: reason = "身份验证失败，请重新登录。"
        case .accessDenied: reason = "该账户无权使用此模型。"
        case .quotaExhausted: reason = "模型账户的配额已用尽。"
        case .rateLimited: reason = "模型供应商对请求进行了限速。"
        case .contextTooLong: reason = "模型供应商拒绝了过大的输入。"
        case .requestRejected: reason = "模型供应商拒绝了该请求。"
        case .serviceUnavailable: reason = "模型供应商不可用。"
        case .timeout: reason = "模型请求超时。"
        case .network: reason = "与模型供应商的连接失败。"
        case .contentRefused: reason = "模型供应商拒绝了该内容。"
        case .cancelled: reason = "模型请求已取消。"
        case .unknown: reason = "模型测试失败。"
        }
        let status = failure.httpStatus.map { " HTTP \($0)." } ?? ""
        return "\(reason)\(status) Stage: \(phase)."
    }
}
