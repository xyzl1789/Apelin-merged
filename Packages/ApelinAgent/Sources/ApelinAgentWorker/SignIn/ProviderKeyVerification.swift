import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI

/// 站点对接口格式的要求，按响应正文认出来。
///
/// 一些中转站只开 Responses API，对 Chat Completions 回“本站已停用
/// /v1/chat/completions，请改用 /v1/responses”。用户选了哪种格式都不该
/// 决定成败：认出这一种情况后换格式重试，并把换过的格式保存下来。
public enum ProviderEndpointRequirement: Error, Equatable {
    /// 站点停用了 Chat Completions，要求改用 Responses API。
    case responsesOnly

    /// 正文里的说法，大小写与措辞各站不同，按关键词认。
    static func isResponsesOnly(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let mentionsResponses = lowered.contains("/v1/responses")
            || lowered.contains("responses api")
        let refusesCompletions = lowered.contains("chat/completions")
            || lowered.contains("chat_completions")
            || lowered.contains("chat completions")
        return mentionsResponses && refusesCompletions
    }
}

/// A candidate key stays in memory until its configured model answers.
/// This runs in the account worker, never in the app or a user conversation.
public enum ProviderKeyVerification {
    public static func verify(
        _ provider: AgentProvider,
        _ credentials: OAuthCredentials,
        modelOverride: String? = nil,
    ) async throws {
        let source = DeliveredCredentialSource([provider.storeID: credentials])
        let cancellation = CancellationHandle()
        do {
            try await AccountDesk.withDeadline(45) {
                try await withTaskCancellationHandler {
                    let manager = OAuthManager(source: source)
                    let model = modelOverride
                        ?? (ProviderModels.isDeepSeek(credentials)
                            ? ProviderModels.list(provider, credentials: credentials).first
                            : nil)
                    guard let resolved = try await ProviderRegistration.resolve(storeID: provider.storeID, manager: manager, modelOverride: model) else {
                        throw ApelinError(.badRequest, "无法配置该供应商。")
                    }
                    let auth = try await resolved.authResolver?(resolved.model, nil)
                    let response = try await complete(
                        model: resolved.model,
                        context: Context(messages: [.user(UserMessage(text: "Reply with OK."))]),
                        options: StreamOptions(
                            maxTokens: 32,
                            maxRetryDelayMs: 0,
                            resolvedAuth: auth,
                            cancellation: cancellation,
                            verbose: false,
                        ),
                    )
                    try Task.checkCancellation()
                    guard response.stopReason == .stop || response.stopReason == .length,
                          response.content.contains(where: {
                              switch $0 {
                              case let .text(text): !text.text.isEmpty
                              case let .thinking(thinking): !thinking.thinking.isEmpty
                              default: false
                              }
                          })
                    else { throw ApelinError(.unavailable, "供应商没有返回响应。") }
                } onCancel: {
                    cancellation.cancel()
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let failure as CompletionFailedError
            where ProviderEndpointRequirement.isResponsesOnly(failure.message.errorMessage ?? "")
        {
            // 站点自己的说法，调用方据此换接口格式重试。
            throw ProviderEndpointRequirement.responsesOnly
        } catch {
            // Provider error bodies may echo submitted values. No response
            // body, key, or request header crosses back to the app.
            throw ApelinError(
                .unavailable,
                "无法验证该供应商。请检查 API 密钥、端点和模型后重试。",
            )
        }
    }
}

