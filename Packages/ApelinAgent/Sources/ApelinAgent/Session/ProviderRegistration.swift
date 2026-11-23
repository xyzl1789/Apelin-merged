import ApelinProtocol
import Foundation
import KWWKAI

/// The same registration for account verification and conversation requests.
/// kwwk owns the transports; Apelin adds DeepSeek's separate credential and
/// restores the catalog capabilities its generic Chat Completions login loses.
public enum ProviderRegistration {
    public static func resolve(
        storeID: String,
        manager: OAuthManager,
        modelOverride: String? = nil,
        parameters: AgentModelParameters? = nil,
    ) async throws -> ResolvedAuth? {
        guard let credentials = try await manager.credentials(for: storeID) else { return nil }
        if storeID == CredentialProviderID.deepSeek {
            let id = modelOverride ?? DeepSeekProvider.extra("defaultModel", in: credentials) ?? DeepSeekProvider.defaultModel
            let base = DeepSeekProvider.extra("baseUrl", in: credentials) ?? DeepSeekProvider.baseURL
            let fallback = Model(id: id, api: "openai-completions", provider: "deepseek", baseURL: base)
            let model = ModelResolver.resolving(
                DeepSeekProvider.applyingCatalog(to: fallback),
                catalogKey: "deepseek",
                parameters: parameters,
            )
            await APIRegistry.shared.register(OpenAICompletionsProvider(), scope: model.provider)
            return ResolvedAuth(model: model, modelLabel: "\(model.name) from DeepSeek", authResolver: { _, _ in
                ResolvedProviderAuth(token: credentials.access, scheme: .bearer)
            })
        }
        let registered: ResolvedAuth? = if CredentialProviderID.endpointNumber(storeID) != nil {
            // kwwk knows one OpenAI-compatible login, by its store id. A
            // further endpoint is registered as that login, from its own
            // credentials: the model carries its base URL, and the key is
            // bound to this resolution below.
            try await registerStored(
                storeId: CredentialProviderID.openAICompatible,
                manager: OAuthManager(
                    source: DeliveredCredentialSource([CredentialProviderID.openAICompatible: credentials]),
                ),
                modelOverride: modelOverride,
            )
        } else {
            try await registerStored(storeId: storeID, manager: manager, modelOverride: modelOverride)
        }
        guard let resolved = registered else { return nil }
        // A model the endpoint's own record does not describe is read against
        // the catalogs: a relay's `cn:deepseek-v4.1-flash` is DeepSeek's model,
        // with its window, its ceiling and its images. An endpoint whose
        // figures are already the catalog's changes nothing here.
        var model = ModelResolver.resolving(
            DeepSeekProvider.isOfficial(credentials) ? DeepSeekProvider.applyingCatalog(to: resolved.model) : resolved.model,
            catalogKey: catalogKey(storeID: storeID),
            parameters: parameters,
        )
        // An OpenAI-compatible endpoint may speak either request shape. The
        // saved extra is kwwk's `Model.api` value, so the catalog read above
        // cannot change which transport the session dispatches to. kwwk's
        // Chat Completions login registers one provider under the shared
        // `openai-compatible` scope; Responses needs its own API registered
        // under that same scope, with SSE only so a relay without WebSockets
        // still works.
        var format = AgentAPIFormat.chatCompletions
        if CredentialProviderID.isOpenAICompatible(storeID),
           case let .string(value)? = credentials.extras[AgentSignInField.apiFormat.rawValue],
           let chosen = AgentAPIFormat(rawValue: value)
        {
            format = chosen
        }
        let compatible = CredentialProviderID.isOpenAICompatible(storeID)
        let azure = compatible && ProviderRegistration.extra(AgentSignInField.azure.rawValue, in: credentials) == "true"
        if compatible, !azure, format == .responses {
            // kwwk 的 Responses 传输只把 `StreamOptions.headers` 带进普通流式
            // 请求，模型自身的头会被丢掉；中转站按 User-Agent 白名单放行，
            // 所以这里包一层把模型头补进去，否则站点回“仅支持编程客户端”。
            await APIRegistry.shared.register(
                ResponsesProviderWithModelHeaders(
                    inner: OpenAIResponsesProvider(webSocketClient: nil),
                ),
                scope: model.provider,
            )
            model.api = format.rawValue
        }
        // 自建/中转端点按 User-Agent 白名单放行客户端，与验证共用这一份
        // model：加上标识后，账户验证和真实会话的 Chat Completions/Responses
        // 请求（kwwk 都读取 model.headers）都会被中转站接受。只对这些端点
        // 注入，OAuth/CLI 登录自带的强制 UA 不动。
        // 自定义 User-Agent（Minis 的 `customUserAgent`）非空时替代默认标识。
        if CredentialProviderID.isOpenAICompatible(storeID) {
            // 仅在端点未明确声明时使用旧接口兼容的 system 角色。
            if model.compat?.supportsDeveloperRole == nil {
                var compat = model.compat ?? ModelCompat()
                compat.supportsDeveloperRole = false
                model.compat = compat
            }
            let customUA = ProviderRegistration.extra(AgentSignInField.customUserAgent.rawValue, in: credentials)
            model = CompatibleEndpointUserAgent.applying(to: model, customUserAgent: customUA)
            if azure {
                guard let base = extra(AgentSignInField.baseURL.rawValue, in: credentials),
                      let endpoint = azureEndpoint(base, format: format, deployment: model.id)
                else { return nil }
                model.baseURL = base
                model.api = format.rawValue
                // Azure 和普通兼容账号的路径拼接不同，不能覆盖共享的传输注册。
                model.provider += "-azure-\(storeID)"
                switch format {
                case .chatCompletions:
                    await APIRegistry.shared.register(OpenAICompletionsProvider(
                        defaultBaseURL: endpoint,
                        urlBuilder: { model, _, fallback in
                            azureEndpoint(model.baseURL, format: .chatCompletions, deployment: model.id) ?? fallback
                        },
                    ), scope: model.provider)
                case .responses:
                    await APIRegistry.shared.register(ResponsesProviderWithModelHeaders(inner: OpenAIResponsesProvider(
                        webSocketClient: nil,
                        defaultBaseURL: endpoint,
                        urlBuilder: { model, _, fallback in
                            azureEndpoint(model.baseURL, format: .responses, deployment: model.id) ?? fallback
                        },
                    )), scope: model.provider)
                }
            } else if let base = ProviderRegistration.extra(AgentSignInField.baseURL.rawValue, in: credentials),
                      let normalized = ProviderRegistration.appendingV1(
                          base, enabled: ProviderRegistration.extra(AgentSignInField.appendV1.rawValue, in: credentials) != "false"
                      )
            {
                model.baseURL = normalized
            }
        }
        guard CredentialProviderID.isOpenAICompatible(storeID) else {
            return ResolvedAuth(
                model: model,
                modelLabel: resolved.modelLabel,
                authResolver: resolved.authResolver,
                providerSlots: resolved.providerSlots,
                authResolvers: resolved.authResolvers,
            )
        }
        // The registry's transport is shared. Bind the key to this resolution
        // so another account verification cannot replace an in-flight key.
        return ResolvedAuth(
            model: model,
            modelLabel: resolved.modelLabel,
            authResolver: { _, _ in
                ResolvedProviderAuth(token: credentials.access, scheme: azure ? .apiKeyHeader("api-key") : .bearer)
            },
            providerSlots: resolved.providerSlots,
            authResolvers: resolved.authResolvers,
        )
    }

    /// 只重建 Azure 的路径，保留 `api-version` 等原有查询参数。
    public static func azureEndpoint(_ base: String, format: AgentAPIFormat?, deployment: String = "") -> URL? {
        guard var url = URLComponents(string: base), url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false, url.user == nil, url.password == nil, url.fragment == nil
        else { return nil }
        var path = url.percentEncodedPath.split(separator: "/").map(String.init)
        for suffix in [["chat", "completions"], ["responses"], ["models"]] where path.suffix(suffix.count).elementsEqual(suffix) {
            path.removeLast(suffix.count)
            break
        }
        let existingDeployment: String?
        if let index = path.lastIndex(of: "deployments"), index > 0, path[index - 1] == "openai" {
            existingDeployment = path.dropFirst(index + 1).first
            path.removeSubrange(index...)
        } else {
            existingDeployment = nil
        }
        if path.isEmpty { path = ["openai"] }
        switch format {
        case .chatCompletions:
            if path.last == "openai" {
                guard let encodedDeployment = existingDeployment ?? deployment.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")),
                      !encodedDeployment.isEmpty, encodedDeployment != ".", encodedDeployment != ".."
                else { return nil }
                path += ["deployments", encodedDeployment]
            }
            path += ["chat", "completions"]
        case .responses: path.append("responses")
        case nil: path.append("models")
        }
        url.percentEncodedPath = "/" + path.joined(separator: "/")
        return url.url
    }

    /// Reads a non-empty string extra, the same rule DeepSeek uses.
    public static func extra(_ key: String, in credentials: OAuthCredentials) -> String? {
        guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }

    /// 依 Minis 的 `appendV1Suffix` 规范端点地址：开启时先去掉地址尾部的
    /// `/v1` 再统一加回，避免用户填了 `/v1` 后重复；关闭时原样返回。只处理
    /// 路径，查询串（Azure 的 api-version）保留。
    public static func appendingV1(_ base: String, enabled: Bool) -> String? {
        guard var components = URLComponents(string: base),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path = String(path.dropLast()) }
        if enabled {
            if path.hasSuffix("/v1") { path = String(path.dropLast(3)) }
            path += "/v1"
        }
        components.path = path
        return components.string
    }

    /// The catalog a store id's models are filed under, when the two names
    /// differ (a store id is `openai-api-key`, its catalog `openai`). Nil is an
    /// endpoint the catalogs do not key, read from every provider's copy.
    static func catalogKey(storeID: String) -> String? {
        switch storeID {
        case CredentialProviderID.openAICompatible: nil
        case "openai-api-key": "openai"
        case "anthropic-api-key": "anthropic"
        case "google-api-key": "google"
        case CredentialProviderID.deepSeek: "deepseek"
        default: storeID
        }
    }
}

public enum DeepSeekProvider {
    public static let baseURL = "https://api.deepseek.com"
    public static let defaultModel = "deepseek-flash"

    public static func isOfficial(_ credentials: OAuthCredentials) -> Bool {
        guard let base = extra("baseUrl", in: credentials) else { return false }
        return URLComponents(string: base)?.host?.lowercased() == "api.deepseek.com"
    }

    /// Only documented aliases inherit Flash's capabilities. Unknown IDs keep
    /// their original configuration, and the selected wire ID is never renamed.
    static func applyingCatalog(to original: Model) -> Model {
        let catalogID: String = switch original.id {
        case "deepseek-v4-flash", "deepseek-v4-flash-vision-exp": defaultModel
        default: original.id
        }
        guard var model = ModelsCatalog.model(provider: "deepseek", id: catalogID) else { return original }
        model.id = original.id
        model.api = original.api
        model.provider = original.provider
        model.baseURL = original.baseURL
        model.headers = original.headers
        return model
    }

    static func extra(_ key: String, in credentials: OAuthCredentials) -> String? {
        guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
        return value
    }
}
