import Foundation
import KWWKAI

/// kwwk 的 `OpenAIResponsesProvider` 只在压缩请求里合并 `model.headers`，
/// 普通流式请求（`runHTTP`）只读 `StreamOptions.headers`。中转站按
/// User-Agent 白名单放行客户端，漏掉这个头就等于匿名访问，站点会以
/// “仅支持编程客户端”拒绝。Chat Completions 的传输没有这个问题。
///
/// 这层包装把模型的请求头补进 `StreamOptions`，两条路径于是行为一致：
/// 账户验证、模型验证、真实会话都走 `APIRegistry`，因此都经过这里。
public final class ResponsesProviderWithModelHeaders:
    APIProvider,
    APIProviderSessionLifecycle,
    NativeCompactionProvider,
    @unchecked Sendable
{
    private let inner: OpenAIResponsesProvider

    public init(inner: OpenAIResponsesProvider) {
        self.inner = inner
    }

    public var api: String {
        inner.api
    }

    public func stream(
        model: Model,
        context: Context,
        options: StreamOptions?,
    ) -> AssistantMessageStream {
        inner.stream(
            model: model,
            context: context,
            options: Self.options(model: model, adding: options),
        )
    }

    public func compact(
        model: Model,
        context: Context,
        instructions: String,
        options: StreamOptions?,
    ) async throws -> NativeCompactionResult? {
        try await inner.compact(
            model: model,
            context: context,
            instructions: instructions,
            options: Self.options(model: model, adding: options),
        )
    }

    public func closeSession(sessionId: String) async {
        await inner.closeSession(sessionId: sessionId)
    }

    /// 调用方自己给的请求头优先：模型的头只补缺，不覆盖。
    static func options(model: Model, adding options: StreamOptions?) -> StreamOptions? {
        let modelHeaders = model.headers ?? [:]
        guard !modelHeaders.isEmpty else { return options }
        var headers = options?.headers ?? [:]
        for (name, value) in modelHeaders
            where !headers.keys.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame })
        {
            headers[name] = value
        }
        var merged = options ?? StreamOptions()
        merged.headers = headers
        return merged
    }
}
