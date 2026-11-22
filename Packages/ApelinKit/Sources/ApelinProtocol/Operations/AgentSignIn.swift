import Foundation

/// Reads every credential file in `console/inbox/credentials/` once, stores
/// each in the keychain (service `wiki.qaq.apelin.agent`) and deletes the
/// file. A file is `<provider-store-id>.json` holding kwwk's credential
/// shape, or a kwwk `auth.json` map of store id to credential. Contents are
/// never logged or answered.
public struct AgentCredentialImportRequest: OperationRequest {
    public typealias Response = AgentCredentialImportResponse
    public static let operation = AppOperation.agentCredentialImport
    public init() {}
}

public struct AgentCredentialImportResponse: Codable, Sendable, Equatable {
    /// kwwk store ids now in the keychain, from this import.
    public var stored: [String]
    /// One line per file that could not be used: its name and why.
    public var rejected: [String]
    /// Every store id the keychain holds after the import.
    public var available: [String]

    public init(stored: [String] = [], rejected: [String] = [], available: [String] = []) {
        self.stored = stored
        self.rejected = rejected
        self.available = available
    }
}

// MARK: - Sign-in

//
// Signing in to a provider runs kwwk's own flow in apelin-agent's
// `credential-import` instance, the one executable that holds the keychain
// group the sessions read; the app only shows what the flow asks for and
// hands back what the user supplies. Sign-in events never return secrets.
// The app-only configuration editor reads saved API fields in a direct reply.
// AGENTS.md ▸ Decisions ▸ Agent sign-in.

/// How a provider's sign-in reaches the user.
public enum AgentSignInMethod: String, Codable, Sendable {
    /// A one-time code the user confirms or enters on the provider's page
    /// (an RFC 8628 device flow: GitHub, Kimi, xAI): a `deviceCode` event.
    case deviceCode
    /// The provider's page in the browser: an `authorize` event. The page
    /// either redirects to a loopback listener in apelin-agent
    /// (`acceptsCallbackURL` when a pasted address can stand in for it) or
    /// the flow asks the provider until the user has signed in.
    case browser
    /// A key the user types: an `input` event, answered by
    /// `agentSignInRespond`.
    case apiKey
}

/// The request shape an OpenAI-compatible endpoint speaks. These are kwwk's
/// `Model.api` values, stored verbatim as the `apiFormat` extra so resolution
/// can pick the matching transport.
public enum AgentAPIFormat: String, Codable, Sendable, CaseIterable {
    case chatCompletions = "openai-completions"
    case responses = "openai-responses"

    /// The fallback title a form sends with the option; the app draws its own
    /// localized name for each known value.
    public var displayTitle: String {
        switch self {
        case .chatCompletions: "Chat Completions"
        case .responses: "Responses"
        }
    }
}

/// 图像生成走哪个端点，照抄 Minis 的 `ImageEndpointMode`：
///   - `auto`：先试 `/v1/images/generations`，4xx 时回退 `/v1/chat/completions`；
///   - `imagesGenerations`：只用 `/v1/images/generations`；
///   - `chatCompletions`：只用 `/v1/chat/completions`（多模态输出）。
public enum AgentImageEndpointMode: String, Codable, Sendable, CaseIterable {
    case auto
    case imagesGenerations = "images_generations"
    case chatCompletions = "chat_completions"

    /// 表单选项的兜底标题；界面按 known value 显示本地化名。
    public var displayTitle: String {
        switch self {
        case .auto: "Auto"
        case .imagesGenerations: "Images Generations"
        case .chatCompletions: "Chat Completions"
        }
    }
}

/// The values `agentSignInRespond` carries, by their wire names.
public enum AgentSignInField: String, Codable, Sendable, CaseIterable {
    /// The key itself (kwwk's `access`).
    case apiKey
    /// An API endpoint (kwwk's `baseUrl` extra).
    case baseURL = "baseUrl"
    /// The model an OpenAI-compatible endpoint serves by default (kwwk's
    /// `defaultModel` extra).
    case defaultModel
    /// Which request shape an OpenAI-compatible endpoint speaks: kwwk's
    /// `openai-completions` or `openai-responses`, kept as an `apiFormat`
    /// extra. Absent means Chat Completions, as before.
    case apiFormat
    /// 是否自动在自定义端点地址后附加 `/v1`（Minis 的 `appendV1Suffix`，默认开）。
    case appendV1
    /// 自定义 User-Agent；留空时用默认的 Minis 客户端标识。
    case customUserAgent
    /// Azure OpenAI 模式：用 `api-key` 头与 deployments 路径（Minis 的 `azureMode`）。
    case azure
    /// 图像生成使用的端点（Minis 的 `imageEndpointMode`）。
    case imageEndpointMode
    /// The address the browser was sent back to, pasted by the user when
    /// the loopback listener could not be reached.
    case callbackURL
}

/// One tool description returned by a live, read-only MCP `tools/list` request.
public struct AgentMCPToolSummary: Codable, Sendable, Equatable {
    public var name: String
    public var description: String?

    public init(name: String, description: String? = nil) {
        self.name = name
        self.description = description
    }
}

/// Fetches a configured MCP server's current tools list. Only the server name
/// crosses the app/worker boundary; URL and authentication headers stay in the
/// protected MCP settings file and the reply contains no credentials.
public struct AgentMCPToolsRequest: OperationRequest {
    public typealias Response = AgentMCPToolsResponse
    public static let operation = AppOperation.agentMCPTools
    public var serverName: String

    public init(serverName: String) {
        self.serverName = serverName
    }
}

public struct AgentMCPToolsResponse: Codable, Sendable, Equatable {
    public var serverName: String
    public var tools: [AgentMCPToolSummary]

    public init(serverName: String, tools: [AgentMCPToolSummary] = []) {
        self.serverName = serverName
        self.tools = tools
    }
}

/// A read-only balance lookup for every signed-in provider account whose
/// endpoint publishes one. The reply never carries a credential, a URL with a
/// query, or the server's own text: the app draws a figure, not a response.
/// `force` skips the worker's short cache; an automatic refresh does not.
public struct AgentProviderBalancesRequest: OperationRequest {
    public typealias Response = AgentProviderBalancesResponse
    public static let operation = AppOperation.agentProviderBalances
    public var force: Bool
    public init(force: Bool = false) {
        self.force = force
    }
}

/// One provider account's balance line, safe to show and to cache.
public struct ProviderBalance: Codable, Sendable, Equatable {
    /// The account's store id, never its key.
    public var accountID: String
    /// The provider's own name for the account, already local to the app.
    public var provider: AgentProvider
    /// What the page calls it: the endpoint's host, never a key.
    public var label: String
    /// The amount as the provider spelled it, decimal text at most 38 digits.
    public var amount: String
    /// A short currency or unit mark, at most 32 characters.
    public var currency: String
    /// How full the ring draws: remaining / granted, 0 ... 1, or nil for a
    /// figure with no ceiling to draw against.
    public var fraction: Double?
    /// When the figure was read, or last read successfully.
    public var updatedAt: Date
    /// The last lookup failed: the amount is the cached one, not a fresh read.
    public var stale: Bool
    /// A short, redacted reason for the failure, never the server's text.
    public var problem: String?
    /// 自定义中转站被探测出的类型（如「New API · /api/usage/token」）；官方
    /// 服务商或没探明时为 nil。展示时照原样显示，不含密钥或完整 URL。
    public var relayKind: String?

    public init(accountID: String, provider: AgentProvider, label: String,
                amount: String, currency: String, fraction: Double?,
                updatedAt: Date, stale: Bool, problem: String?, relayKind: String? = nil) {
        self.accountID = accountID
        self.provider = provider
        self.label = label
        self.amount = amount
        self.currency = currency
        self.fraction = fraction
        self.updatedAt = updatedAt
        self.stale = stale
        self.problem = problem
        self.relayKind = relayKind
    }
}

/// Only accounts whose endpoints have a balance adapter are named here. An
/// empty list means "nothing to draw", never "every balance is zero".
public struct AgentProviderBalancesResponse: Codable, Sendable, Equatable {
    public var balances: [ProviderBalance]
    public init(balances: [ProviderBalance] = []) {
        self.balances = balances
    }
}

/// One provider as the sign-in screen lists it. Never a secret: no token,
/// no key, not even part of one.
public struct AgentAccount: Codable, Sendable, Equatable {
    public var provider: AgentProvider
    /// How `agentSignIn` signs in when it names no method.
    public var method: AgentSignInMethod
    /// The other methods `agentSignIn` takes for this provider (OpenRouter's
    /// typed key beside its browser sign-in). Absent when there are none.
    public var alternativeMethods: [AgentSignInMethod]?
    public var signedIn: Bool
    /// What tells the account apart without a secret: an API key's
    /// endpoint host. Absent for a subscription sign-in.
    public var account: String?
    /// When a sign-in that cannot renew itself lapses. Absent when it
    /// renews (a refresh token) or never lapses (an API key).
    public var expiresAt: Date?
    /// Model identifiers from this signed-in provider, never credentials.
    public var models: [String]?
    /// The completed sign-in used a typed API key, including alternate methods.
    public var usesAPIKey: Bool?
    /// Known reasoning levels from the provider catalog, keyed by model ID.
    public var reasoningEfforts: [String: [AgentReasoningEffort]]?
    /// Processing tiers the provider catalog lists, keyed by model ID; a
    /// model it does not name is offered none.
    public var serviceTiers: [String: [AgentServiceTier]]?
    /// What each model was read as, keyed by model ID: the catalog entry found
    /// for a name the provider does not describe itself, so the settings page
    /// can show a relay's models with the figures they really have.
    public var capabilities: [String: AgentModelCapabilities]?
    public var isAPIKeyAccount: Bool {
        usesAPIKey ?? (method == .apiKey)
    }

    public init(
        provider: AgentProvider,
        method: AgentSignInMethod,
        alternativeMethods: [AgentSignInMethod]? = nil,
        signedIn: Bool,
        account: String? = nil,
        expiresAt: Date? = nil,
        models: [String]? = nil,
        usesAPIKey: Bool? = nil,
        reasoningEfforts: [String: [AgentReasoningEffort]]? = nil,
        serviceTiers: [String: [AgentServiceTier]]? = nil,
        capabilities: [String: AgentModelCapabilities]? = nil,
    ) {
        self.provider = provider
        self.method = method
        self.alternativeMethods = alternativeMethods
        self.signedIn = signedIn
        self.account = account
        self.expiresAt = expiresAt
        self.models = models
        self.usesAPIKey = usesAPIKey
        self.reasoningEfforts = reasoningEfforts
        self.serviceTiers = serviceTiers
        self.capabilities = capabilities
    }
}

/// Every provider Apelin's sessions can use, signed in or not, in the
/// order kwwk lists its logins: subscriptions, then keys.
public struct AgentAccountListRequest: OperationRequest {
    public typealias Response = AgentAccountListResponse
    public static let operation = AppOperation.agentAccountList
    /// Model ids this device keeps for a provider and the agent's own list does
    /// not: a custom endpoint's model, saved in the app's settings and never
    /// in the credentials. Keyed by the provider's id (`AgentProvider.rawValue`,
    /// `openAICompatible`). The catalogs are read over these too, so a relay's
    /// model is named and measured like one of the provider's own.
    public var extraModels: [String: [String]]?
    /// True for a caller that wants only the models it named: each signed-in
    /// account then answers with the `extraModels` of its own provider and
    /// nothing else, and an account it named none for has no model. Requested
    /// IDs are preserved for every provider, including live or custom models
    /// absent from bundled catalogs.
    /// Absent keeps the whole list, with `extraModels` added to it.
    public var onlyExtraModels: Bool?
    public init(extraModels: [String: [String]]? = nil, onlyExtraModels: Bool? = nil) {
        self.extraModels = extraModels
        self.onlyExtraModels = onlyExtraModels
    }
}

public struct AgentAccountListResponse: Codable, Sendable, Equatable {
    public var accounts: [AgentAccount]
    public init(accounts: [AgentAccount] = []) {
        self.accounts = accounts
    }
}

/// Reads a saved API-key configuration only for the app's editing form.
/// This direct reply is never an account-list field or a persisted task event.
public struct AgentAPIConfigurationRequest: OperationRequest {
    public typealias Response = AgentAPIConfigurationResponse
    public static let operation = AppOperation.agentAPIConfiguration
    public var provider: AgentProvider
    public init(provider: AgentProvider) {
        self.provider = provider
    }
}

public struct AgentAPIConfigurationResponse: Codable, Sendable {
    public var values: [String: String]
    public init(values: [String: String]) {
        self.values = values
    }
}

public struct AgentModelListRequest: OperationRequest {
    public typealias Response = AgentModelListResponse
    public static let operation = AppOperation.agentModelList
    public var provider: AgentProvider
    public init(provider: AgentProvider) {
        self.provider = provider
    }
}

public struct AgentModelListResponse: Codable, Sendable {
    public var models: [String]
    public init(models: [String]) {
        self.models = models
    }
}

/// A cancellable provider task. Only model IDs and progress cross the wire.
public struct AgentModelActivateRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.agentModelActivate
    public var provider: AgentProvider
    public var models: [String]
    public init(provider: AgentProvider, models: [String]) {
        self.provider = provider; self.models = models
    }
}

/// Starts a sign-in: a task of kind `signIn`, read with `agentAttach`.
/// Its events are `deviceCode` {code, verificationURL, pageHoldsCode},
/// `authorize` {url, acceptsCallbackURL} or `input` {fields: [{key,
/// required, secure, defaultValue?, placeholder?}]}, then `state`. A new
/// sign-in ends the one still running, which ends `cancelled`; one left
/// alone ends `failed` after `AgentSignInRequest.timeoutSeconds`.
public struct AgentSignInRequest: OperationRequest {
    public typealias Response = TaskHandle
    public static let operation = AppOperation.agentSignIn
    /// How long a sign-in waits for the user: GitHub's device code lasts
    /// fifteen minutes, and so does every other flow here.
    public static let timeoutSeconds = 15 * 60

    public var provider: AgentProvider
    /// One of the account's `alternativeMethods`; nil is its `method`. Any
    /// other is refused `badRequest` before the task is accepted.
    public var method: AgentSignInMethod?

    public init(provider: AgentProvider, method: AgentSignInMethod? = nil) {
        self.provider = provider
        self.method = method
    }
}

/// What the user supplied for a running sign-in: the fields its `input`
/// event asked for, or `callbackURL` for a browser flow. Sent once; the
/// worker keeps it only as long as the flow needs it and never repeats it,
/// in a reply, an event or a log. A value that will not do is refused with
/// `badRequest` naming the field, and the sign-in goes on waiting.
public struct AgentSignInRespondRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSignInRespond
    public var taskID: TaskID
    /// Keyed by `AgentSignInField` raw values.
    public var values: [String: String]
    /// False when setup proceeds to model selection before verification.
    /// Absent preserves the original verify-before-save behavior.
    public var verifyModel: Bool?

    public init(taskID: TaskID, values: [String: String], verifyModel: Bool? = nil) {
        self.taskID = taskID
        self.values = values
        self.verifyModel = verifyModel
    }

    public init(taskID: TaskID, fields: [AgentSignInField: String], verifyModel: Bool? = nil) {
        self.init(
            taskID: taskID,
            values: Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) }),
            verifyModel: verifyModel,
        )
    }
}

public struct AgentSignInCancelRequest: TaskCancelRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSignInCancel
    public var taskID: TaskID
    public init(taskID: TaskID) {
        self.taskID = taskID
    }
}

/// Forgets the provider's keychain item. Signing out of a provider that is
/// not signed in is no error.
public struct AgentSignOutRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSignOut
    public var provider: AgentProvider
    public init(provider: AgentProvider) {
        self.provider = provider
    }
}

public extension ApelinService {
    func agentAccountList(
        extraModels: [String: [String]]? = nil,
        onlyExtraModels: Bool? = nil,
    ) async throws -> AgentAccountListResponse {
        try await send(AgentAccountListRequest(extraModels: extraModels, onlyExtraModels: onlyExtraModels))

    }

    func agentAPIConfiguration(provider: AgentProvider) async throws -> AgentAPIConfigurationResponse {
        try await send(AgentAPIConfigurationRequest(provider: provider))
    }

    func agentModelList(provider: AgentProvider) async throws -> AgentModelListResponse {
        try await send(AgentModelListRequest(provider: provider))
    }

    func agentModelActivate(provider: AgentProvider, models: [String]) async throws -> TaskHandle {
        try await send(AgentModelActivateRequest(provider: provider, models: models))
    }

    func agentSignIn(provider: AgentProvider, method: AgentSignInMethod? = nil) async throws -> TaskHandle {
        try await send(AgentSignInRequest(provider: provider, method: method))
    }

    func agentSignInRespond(taskID: TaskID, fields: [AgentSignInField: String], verifyModel: Bool? = nil) async throws {
        _ = try await send(AgentSignInRespondRequest(taskID: taskID, fields: fields, verifyModel: verifyModel))
    }

    func agentSignInCancel(taskID: TaskID) async throws {
        _ = try await send(AgentSignInCancelRequest(taskID: taskID))
    }

    func agentSignOut(provider: AgentProvider) async throws {
        _ = try await send(AgentSignOutRequest(provider: provider))
    }
}

public extension ApelinService {
    func agentMCPTools(serverName: String) async throws -> AgentMCPToolsResponse {
        try await send(AgentMCPToolsRequest(serverName: serverName))
    }
}

public extension ApelinService {
    func agentCredentialImport() async throws -> AgentCredentialImportResponse {
        try await send(AgentCredentialImportRequest())
    }

    func agentProviderBalances(force: Bool = false) async throws -> AgentProviderBalancesResponse {
        try await send(AgentProviderBalancesRequest(force: force))
    }
}
