import Foundation
import KWWKAI
import ApelinProtocol

public protocol KWWKQuotaUsageProvider: Sendable {
    func usage(for storeID: String, credentials: OAuthCredentials) async throws -> [OAuthUsageWindow]?
}

public struct DefaultKWWKQuotaUsageProvider: KWWKQuotaUsageProvider {
    public init() {}
    public func usage(for storeID: String, credentials: OAuthCredentials) async throws -> [OAuthUsageWindow]? {
        guard let reader = OAuthUsage.readers[storeID] else { return nil }
        return try await reader.usage(credentials, using: URLSessionHTTPClient.shared)
    }
}

public protocol QuotaHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data)
}

public final class URLSessionQuotaTransport: QuotaHTTPTransport, @unchecked Sendable {
    public static let shared = URLSessionQuotaTransport()
    private let session: URLSession
    public init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 25
        session = URLSession(configuration: config, delegate: QuotaRedirectHold(), delegateQueue: nil)
    }
    public func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw QuotaAdapterError.invalidResponse }
        return (http, data)
    }
}

/// 额度接口只访问原始请求地址，绝不把授权请求跟随重定向发送。
final class QuotaRedirectHold: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public enum QuotaAdapterError: Error, Sendable {
    case invalidResponse
    case unauthorized
    case rateLimited(retryAfterSeconds: Int?)
    case endpointUnsupported(status: Int)
    case httpStatus(Int, summary: String)
    case undecodable
    case missingAccountIdentifier
    case relayProbeExhausted

    public var isPermanentEndpointFailure: Bool {
        switch self {
        case .endpointUnsupported, .relayProbeExhausted: true
        case let .httpStatus(status, _): status == 404 || status == 405 || status == 410 || status == 501
        default: false
        }
    }
}

public struct QuotaQueryResult: Sendable {
    public var snapshot: AgentQuotaSnapshot
    public var endpointKey: String?
    public var relayProbeKind: RelayProbeKind?
    public init(snapshot: AgentQuotaSnapshot, endpointKey: String? = nil, relayProbeKind: RelayProbeKind? = nil) {
        self.snapshot = snapshot
        self.endpointKey = endpointKey
        self.relayProbeKind = relayProbeKind
    }
}

/// 主动额度查询适配器，遵循 OpenMinis 额度定义。
public enum QuotaAdapters {
    private static let posix = Locale(identifier: "en_US_POSIX")

    public static func resolvedBaseURL(for provider: AgentProvider, credentials: OAuthCredentials) -> String? {
        if case let .string(value)? = credentials.extras[AgentSignInField.baseURL.rawValue] {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        switch provider.kind {
        case .deepSeek: return "https://api.deepseek.com"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .openAI: return "https://api.openai.com"
        case .anthropic: return "https://api.anthropic.com"
        case .google: return "https://generativelanguage.googleapis.com"
        default: return nil
        }
    }

    public static func query(provider: AgentProvider, poolID: String, accountLabel: String?, credentials: OAuthCredentials, usesAPIKey: Bool, cachedRelayProbe: RelayProbeKind?, transport: any QuotaHTTPTransport, kwwkUsage: any KWWKQuotaUsageProvider = DefaultKWWKQuotaUsageProvider(), now: Date = Date()) async throws -> QuotaQueryResult {
        let baseURL = resolvedBaseURL(for: provider, credentials: credentials)
        let host = baseURL.flatMap { URLComponents(string: $0)?.host?.lowercased() }
        // 优先采用 OAuth 订阅接口。
        if !usesAPIKey {
            switch provider {
            case .anthropicOAuth:
                let snap = try await queryClaudeOAuth(poolID: poolID, provider: provider, accountLabel: accountLabel, credentials: credentials, transport: transport, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "https://api.anthropic.com/api/oauth/usage")
            case .openAICodex:
                let snap = try await queryCodexOAuth(poolID: poolID, provider: provider, accountLabel: accountLabel, credentials: credentials, transport: transport, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "https://chatgpt.com/backend-api/wham/usage")
            case .kimiCoding:
                let snap = try await queryKimiCode(siteURL: "https://api.kimi.com/coding/v1/usages", poolID: poolID, provider: provider, accountLabel: accountLabel, credentials: credentials, transport: transport, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "https://api.kimi.com/coding/v1/usages")
            case .kimiCodingGlobal:
                let snap = try await queryKimiCode(siteURL: "https://api.kimi.ai/coding/v1/usages", poolID: poolID, provider: provider, accountLabel: accountLabel, credentials: credentials, transport: transport, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "https://api.kimi.ai/coding/v1/usages")
            case .githubCopilot:
                let snap = try await queryGitHubCopilot(poolID: poolID, provider: provider, accountLabel: accountLabel, credentials: credentials, transport: transport, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "https://api.github.com/copilot_internal/user")
            case .workBuddy, .workBuddyAI:
                let snap = try await queryWorkBuddy(poolID: poolID, provider: provider, accountLabel: accountLabel, credentials: credentials, transport: transport, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "workbuddy:credits")
            case .trae:
                let snap = try await queryTraeCN(poolID: poolID, provider: provider, accountLabel: accountLabel, credentials: credentials, transport: transport, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage")
            case .cursor, .kiro, .qoder, .qoderCN, .xai:
                let snap = try await queryKWWKSubscription(poolID: poolID, provider: provider, storeID: provider.storeID, accountLabel: accountLabel, credentials: credentials, kwwkUsage: kwwkUsage, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "kwwk:\(provider.storeID)")
            case .openRouter:
                let snap = try await queryOpenRouter(poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: credentials.access, transport: transport, now: now)
                return QuotaQueryResult(snapshot: snap, endpointKey: "https://openrouter.ai/api/v1")
            default:
                return QuotaQueryResult(snapshot: billingOnlySnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, baseURL: baseURL, now: now))
            }
        }
        // 特定提供商的 API 密钥余额接口。
        if host == "100milionseek.top", let baseURL {
            return try await queryTokenQuota(baseURL: baseURL, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: credentials.access, transport: transport, now: now)
        }
        if provider == .deepSeek || host == "api.deepseek.com" {
            let snap = try await queryDeepSeek(poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: credentials.access, transport: transport, now: now)
            return QuotaQueryResult(snapshot: snap, endpointKey: "https://api.deepseek.com")
        }
        if host == "api.moonshot.cn" || host == "api.moonshot.ai" {
            let currency = host == "api.moonshot.cn" ? "CNY" : "USD"
            let endpoint = "https://\(host!)/v1/users/me/balance"
            let snap = try await queryMoonshot(endpoint: endpoint, currency: currency, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: credentials.access, transport: transport, now: now)
            return QuotaQueryResult(snapshot: snap, endpointKey: "https://\(host!)")
        }
        if host == "api.siliconflow.cn" || host == "api.siliconflow.com" {
            let currency = host == "api.siliconflow.cn" ? "CNY" : "USD"
            let endpoint = "https://\(host!)/v1/user/info"
            let snap = try await querySiliconFlow(endpoint: endpoint, currency: currency, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: credentials.access, transport: transport, now: now)
            return QuotaQueryResult(snapshot: snap, endpointKey: "https://\(host!)")
        }
        if provider == .openRouter || host == "openrouter.ai" {
            let snap = try await queryOpenRouter(poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: credentials.access, transport: transport, now: now)
            return QuotaQueryResult(snapshot: snap, endpointKey: "https://openrouter.ai/api/v1")
        }
        // 自定义中转或非官方端点探测。
        let isCustomRelay: Bool = switch provider.kind {
        case .openAICompatible: true
        case .openAI: host != nil && host != "api.openai.com"
        case .anthropic: host != nil && host != "api.anthropic.com"
        default: false
        }
        if isCustomRelay, let baseURL, let rootURL = QuotaPoolIdentity.normalizedRelayRootURL(from: baseURL) {
            let endpointKey = QuotaPoolIdentity.normalizedEndpointKey(baseURL: baseURL) ?? rootURL.absoluteString
            return try await queryRelay(rootURL: rootURL, endpointKey: endpointKey, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: credentials.access, cachedProbe: cachedRelayProbe, transport: transport, now: now)
        }
        return QuotaQueryResult(snapshot: billingOnlySnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, baseURL: baseURL, now: now))
    }

    public static func billingOnlySnapshot(poolID: String, provider: AgentProvider, accountLabel: String?, baseURL: String?, now: Date = Date()) -> AgentQuotaSnapshot {
        AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .billingLink, source: .billingLink, status: .unsupported, billingURL: QuotaPoolIdentity.billingURL(for: provider, baseURL: baseURL), updatedAt: now)
    }

    // MARK: - 100milionseek 代币额度响应头

    private static func queryTokenQuota(baseURL: String, poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, transport: any QuotaHTTPTransport, now: Date) async throws -> QuotaQueryResult {
        guard let rootURL = QuotaPoolIdentity.normalizedRelayRootURL(from: baseURL),
              rootURL.scheme?.lowercased() == "https", rootURL.host?.lowercased() == "100milionseek.top"
        else { throw QuotaAdapterError.invalidResponse }
        let url = rootURL.appendingPathComponent("v1/models")
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (response, _) = try await transport.send(req)
        guard response.url?.scheme?.lowercased() == "https", response.url?.host?.lowercased() == "100milionseek.top" else { throw QuotaAdapterError.invalidResponse }
        if response.statusCode == 401 || response.statusCode == 403 { throw QuotaAdapterError.unauthorized }
        if response.statusCode == 429 { throw QuotaAdapterError.rateLimited(retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)) }
        guard (200 ..< 300).contains(response.statusCode) else { throw QuotaAdapterError.httpStatus(response.statusCode, summary: "HTTP \(response.statusCode)") }
        var headers: [String: String] = [:]
        for field in ["x-quota-limit", "x-quota-used", "x-quota-remaining"] {
            headers[field] = response.value(forHTTPHeaderField: field)
        }
        guard let balance = parseTokenQuota(headers) else { throw QuotaAdapterError.undecodable }
        let snapshot = AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance, source: .activeAPI,
            status: balance.isAvailable ? .available : .exhausted, balances: [balance], relayKind: "tokenQuota", updatedAt: now)
        return QuotaQueryResult(snapshot: snapshot, endpointKey: QuotaPoolIdentity.normalizedEndpointKey(baseURL: baseURL))
    }

    /// 总量与剩余量缺一不可；用量可推导，但提供时必须与两者一致。
    /// 严格校验完整十进制文本，拒绝负值和假余额，不做货币舍入。
    static func parseTokenQuota(_ headers: [String: String]) -> AgentQuotaBalance? {
        let normalized = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, latest in latest })
        func number(_ value: String?) -> Decimal? {
            guard let value else { return nil }
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count <= 128,
                  text.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil
            else { return nil }
            return QuotaDecimalCoding.parse(text)
        }
        guard let total = number(normalized["x-quota-limit"]), total > 0,
              let remaining = number(normalized["x-quota-remaining"]), remaining >= 0, remaining <= total
        else { return nil }
        let used = total - remaining
        if let rawUsed = normalized["x-quota-used"] {
            guard let reported = number(rawUsed), reported >= 0, reported == used else { return nil }
        }
        return AgentQuotaBalance(id: "token-quota", currency: nil, unitLabel: "tokens", isAvailable: remaining > 0, total: total, used: used, remaining: remaining)
    }

    // MARK: - DeepSeek

    private static func queryDeepSeek(poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        var req = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await sendChecked(req, transport: transport)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaAdapterError.undecodable }
        let isAvailable = boolValue(root["is_available"]) ?? true
        let infos = root["balance_infos"] as? [[String: Any]] ?? []
        var balances: [AgentQuotaBalance] = []
        for info in infos {
            guard let currency = (info["currency"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(), !currency.isEmpty else { continue }
            let total = decimalValue(info["total_balance"])
            let granted = decimalValue(info["granted_balance"])
            let toppedUp = decimalValue(info["topped_up_balance"])
            balances.append(AgentQuotaBalance(id: currency, currency: currency, isAvailable: isAvailable && ((total ?? 0) > 0), total: total, granted: granted, toppedUp: toppedUp, remaining: total))
        }
        if balances.isEmpty { throw QuotaAdapterError.undecodable }
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance, source: .activeAPI, status: isAvailable ? .available : .exhausted, balances: balances, billingURL: QuotaPoolIdentity.billingURL(for: provider), updatedAt: now)
    }

    // MARK: - Moonshot

    private static func queryMoonshot(endpoint: String, currency: String, poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        guard let url = URL(string: endpoint) else { throw QuotaAdapterError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await sendChecked(req, transport: transport)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaAdapterError.undecodable }
        let payload = (root["data"] as? [String: Any]) ?? root
        let available = decimalValue(payload["available_balance"])
        let voucher = decimalValue(payload["voucher_balance"])
        let cash = decimalValue(payload["cash_balance"])
        guard available != nil || voucher != nil || cash != nil else { throw QuotaAdapterError.undecodable }
        let remaining = available ?? ((voucher ?? 0) + (cash ?? 0))
        let isAvailable = remaining > 0
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance, source: .activeAPI, status: isAvailable ? .available : .exhausted,
            balances: [AgentQuotaBalance(id: currency, currency: currency, isAvailable: isAvailable, total: remaining, granted: voucher, toppedUp: cash, remaining: remaining)],
            billingURL: QuotaPoolIdentity.billingURL(for: provider, baseURL: endpoint), updatedAt: now)
    }

    // MARK: - SiliconFlow（只读取余额，不读取个人资料）

    private static func querySiliconFlow(endpoint: String, currency: String, poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        guard let url = URL(string: endpoint) else { throw QuotaAdapterError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await sendChecked(req, transport: transport)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = root["data"] as? [String: Any] else { throw QuotaAdapterError.undecodable }
        // 故意忽略姓名、邮箱、用户标识、头像和角色等资料。
        let balance = decimalValue(payload["balance"])
        let chargeBalance = decimalValue(payload["chargeBalance"] ?? payload["charge_balance"])
        let totalBalance = decimalValue(payload["totalBalance"] ?? payload["total_balance"])
        guard balance != nil || chargeBalance != nil || totalBalance != nil else { throw QuotaAdapterError.undecodable }
        let remaining = totalBalance ?? balance ?? chargeBalance ?? 0
        let isAvailable = remaining > 0
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance, source: .activeAPI, status: isAvailable ? .available : .exhausted,
            balances: [AgentQuotaBalance(id: currency, currency: currency, isAvailable: isAvailable, total: totalBalance ?? remaining, granted: balance, toppedUp: chargeBalance, remaining: remaining)],
            billingURL: QuotaPoolIdentity.billingURL(for: provider, baseURL: endpoint), updatedAt: now)
    }

    // MARK: - OpenRouter（并发查询密钥与余额）

    private static func queryOpenRouter(poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        func makeRequest(_ path: String) -> URLRequest {
            var req = URLRequest(url: URL(string: "https://openrouter.ai/api/v1/\(path)")!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            return req
        }
        async let keyData = tryOptionalSend(makeRequest("key"), transport: transport)
        async let creditsData = tryOptionalSend(makeRequest("credits"), transport: transport)
        let (keyResult, creditsResult) = await (keyData, creditsData)
        if case let .failure(err) = keyResult, case let .failure(err2) = creditsResult {
            throw err2 is QuotaAdapterError ? err2 : err
        }
        var balances: [AgentQuotaBalance] = []
        var planName: String?
        if case let .success(data) = creditsResult,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = root["data"] as? [String: Any] {
            let totalCredits = decimalValue(payload["total_credits"])
            let totalUsage = decimalValue(payload["total_usage"])
            if totalCredits != nil || totalUsage != nil {
                let remaining = (totalCredits ?? 0) - (totalUsage ?? 0)
                balances.append(AgentQuotaBalance(id: "openrouter-credits", currency: "USD", isAvailable: remaining > 0, total: totalCredits, used: totalUsage, remaining: remaining))
            }
        }
        if case let .success(data) = keyResult,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let payload = root["data"] as? [String: Any] {
            if boolValue(payload["is_free_tier"]) ?? false { planName = "免费方案" }
            let limit = decimalValue(payload["limit"])
            let limitRemaining = decimalValue(payload["limit_remaining"])
            let usage = decimalValue(payload["usage"])
            if limit != nil || limitRemaining != nil || usage != nil {
                let remaining = limitRemaining ?? limit.map { $0 - (usage ?? 0) }
                let unlimitedKey = (limit == nil && limitRemaining == nil)
                balances.append(AgentQuotaBalance(id: "openrouter-key", currency: "USD", unitLabel: limit == nil ? "密钥用量" : "密钥限额", isAvailable: unlimitedKey || ((remaining ?? 0) > 0), total: limit, used: usage, remaining: remaining, isUnlimited: unlimitedKey))
            }
        }
        guard !balances.isEmpty else { throw QuotaAdapterError.undecodable }
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance, source: .activeAPI,
            status: balances.contains { $0.isAvailable || $0.isUnlimited } ? .available : .exhausted,
            balances: balances, planName: planName, billingURL: QuotaPoolIdentity.billingURL(for: provider), updatedAt: now)
    }

    // MARK: - ChatGPT / Codex OAuth

    private static func queryCodexOAuth(poolID: String, provider: AgentProvider, accountLabel: String?, credentials: OAuthCredentials, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        let accountId: String
        if case let .string(stored)? = credentials.extras["accountId"], !stored.isEmpty { accountId = stored }
        else if let claimed = OpenAICodexOAuthProvider.extractAccountId(fromJWT: credentials.access) { accountId = claimed }
        else { throw QuotaAdapterError.missingAccountIdentifier }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "User-Agent")
        req.setValue("codex_cli_rs", forHTTPHeaderField: "Originator")
        req.setValue(accountId, forHTTPHeaderField: "ChatGPT-Account-Id")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await sendChecked(req, transport: transport)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaAdapterError.undecodable }
        var windows: [AgentQuotaWindow] = []
        if let rateLimit = root["rate_limit"] as? [String: Any] {
            windows.append(contentsOf: parseCodexRateLimit(rateLimit, prefixID: nil, prefixName: nil))
        }
        for item in root["additional_rate_limits"] as? [[String: Any]] ?? [] {
            let feature = (item["metered_feature"] as? String) ?? (item["limit_name"] as? String)
            guard let feature, !feature.isEmpty, let limit = item["rate_limit"] as? [String: Any] else { continue }
            windows.append(contentsOf: parseCodexRateLimit(limit, prefixID: feature, prefixName: item["limit_name"] as? String ?? feature))
        }
        var balances: [AgentQuotaBalance] = []
        if let credits = root["credits"] as? [String: Any] {
            let hasCredits = boolValue(credits["has_credits"]) ?? false
            let unlimited = boolValue(credits["unlimited"]) ?? false
            let balance = decimalValue(credits["balance"])
            if hasCredits || unlimited || balance != nil {
                balances.append(AgentQuotaBalance(id: "codex-credits", currency: "USD", isAvailable: unlimited || ((balance ?? 0) > 0), total: balance, remaining: balance, isUnlimited: unlimited))
            }
        }
        let planName = (root["plan_type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let exhausted = windows.contains { $0.usedPercent >= 100 } && !(balances.contains { $0.isAvailable || $0.isUnlimited })
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .window, source: .activeAPI, status: exhausted ? .exhausted : .available, balances: balances, windows: windows, planName: planName, billingURL: QuotaPoolIdentity.billingURL(for: provider), updatedAt: now)
    }

    private static func parseCodexRateLimit(_ limit: [String: Any], prefixID: String?, prefixName: String?) -> [AgentQuotaWindow] {
        var result: [AgentQuotaWindow] = []
        let slots: [(String, [String: Any]?)] = [("primary", limit["primary_window"] as? [String: Any]), ("secondary", limit["secondary_window"] as? [String: Any])]
        for (slot, obj) in slots {
            guard let obj, let used = decimalValue(obj["used_percent"]) else { continue }
            let seconds = intValue(obj["limit_window_seconds"])
            if let seconds, seconds <= 0 { continue }
            let resetAt = dateFromUnix(obj["reset_at"])
            let id: String
            let label: String
            if let prefixID {
                id = "\(prefixID):\(slot)"
                label = windowDisplayLabel(seconds: seconds, prefix: prefixName ?? prefixID, fallbackSlot: slot)
            } else {
                switch seconds {
                case 18000: id = "fiveHour"; label = "5 小时窗口"
                case 604_800: id = "sevenDay"; label = "每周窗口"
                default: id = slot; label = windowDisplayLabel(seconds: seconds, prefix: nil, fallbackSlot: slot)
                }
            }
            result.append(AgentQuotaWindow(id: id, label: label, usedPercent: used, windowSeconds: seconds, resetsAt: resetAt))
        }
        return result
    }

    // MARK: - Claude OAuth（主动接口利用率是 0…100）

    private static func queryClaudeOAuth(poolID: String, provider: AgentProvider, accountLabel: String?, credentials: OAuthCredentials, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-cli/\(ProviderVariants.claudeCodeVersion)", forHTTPHeaderField: "User-Agent")
        req.setValue("cli", forHTTPHeaderField: "x-app")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let data = try await sendChecked(req, transport: transport)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaAdapterError.undecodable }
        var windows: [AgentQuotaWindow] = []
        var sharedFiveHour: AgentQuotaWindow?
        var sharedSevenDay: AgentQuotaWindow?
        var scopedSeen: Set<String> = []
        for item in root["limits"] as? [[String: Any]] ?? [] {
            let kind = item["kind"] as? String
            guard let percent = decimalValue(item["percent"] ?? item["used_percentage"] ?? item["utilization"]) else { continue }
            let resetsAt = parseTimestamp(item["resets_at"])
            switch kind {
            case "session":
                if sharedFiveHour == nil { sharedFiveHour = AgentQuotaWindow(id: "fiveHour", label: "5 小时窗口", usedPercent: percent, windowSeconds: 5 * 3600, resetsAt: resetsAt) }
            case "weekly_all":
                if sharedSevenDay == nil { sharedSevenDay = AgentQuotaWindow(id: "sevenDay", label: "每周窗口", usedPercent: percent, windowSeconds: 7 * 86400, resetsAt: resetsAt) }
            case "weekly_scoped":
                let displayName = (((item["scope"] as? [String: Any])?["model"] as? [String: Any])?["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                guard let displayName, !displayName.isEmpty else { continue }
                let id = "anthropic:weekly:\(displayName.lowercased())"
                guard scopedSeen.insert(id).inserted else { continue }
                windows.append(AgentQuotaWindow(id: id, label: "\(displayName)（每周）", usedPercent: percent, windowSeconds: 7 * 86400, resetsAt: resetsAt))
            default: continue
            }
        }
        if sharedFiveHour == nil, let fiveHour = root["five_hour"] as? [String: Any], let pct = decimalValue(fiveHour["used_percentage"] ?? fiveHour["utilization"]) {
            sharedFiveHour = AgentQuotaWindow(id: "fiveHour", label: "5 小时窗口", usedPercent: pct, windowSeconds: 5 * 3600, resetsAt: parseTimestamp(fiveHour["resets_at"]))
        }
        if sharedSevenDay == nil, let sevenDay = root["seven_day"] as? [String: Any], let pct = decimalValue(sevenDay["used_percentage"] ?? sevenDay["utilization"]) {
            sharedSevenDay = AgentQuotaWindow(id: "sevenDay", label: "每周窗口", usedPercent: pct, windowSeconds: 7 * 86400, resetsAt: parseTimestamp(sevenDay["resets_at"]))
        }
        var ordered: [AgentQuotaWindow] = []
        if let sharedFiveHour { ordered.append(sharedFiveHour) }
        if let sharedSevenDay { ordered.append(sharedSevenDay) }
        ordered.append(contentsOf: windows)
        var balances: [AgentQuotaBalance] = []
        if let extra = root["extra_usage"] as? [String: Any], boolValue(extra["is_enabled"]) == true {
            let monthlyLimit = decimalValue(extra["monthly_limit"]).map { $0 / Decimal(100) }
            let usedCredits = decimalValue(extra["used_credits"]).map { $0 / Decimal(100) }
            let remaining = monthlyLimit.map { $0 - (usedCredits ?? 0) }
            if monthlyLimit != nil || usedCredits != nil {
                balances.append(AgentQuotaBalance(id: "claude-extra-usage", currency: "USD", isAvailable: (remaining ?? 1) > 0, total: monthlyLimit, used: usedCredits, remaining: remaining, isUnlimited: monthlyLimit == nil))
            }
        }
        let exhausted = (sharedFiveHour?.usedPercent ?? 0) >= 100 || (sharedSevenDay?.usedPercent ?? 0) >= 100
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .window, source: .activeAPI, status: exhausted ? .exhausted : .available, balances: balances, windows: ordered, billingURL: QuotaPoolIdentity.billingURL(for: provider), updatedAt: now)
    }

    // MARK: - Kimi Code（不伪造 User-Agent）

    private static func queryKimiCode(siteURL: String, poolID: String, provider: AgentProvider, accountLabel: String?, credentials: OAuthCredentials, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        guard let url = URL(string: siteURL) else { throw QuotaAdapterError.invalidResponse }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // 不给 Kimi Code 设置自定义或伪造的 User-Agent。
        let data = try await sendChecked(req, transport: transport)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaAdapterError.undecodable }
        struct Candidate { let seconds: Int; let usedPercent: Decimal; let resetsAt: Date? }
        var candidates: [Candidate] = []
        for item in root["limits"] as? [[String: Any]] ?? [] {
            let window = item["window"] as? [String: Any] ?? [:]
            let detail = item["detail"] as? [String: Any] ?? item
            guard let seconds = kimiWindowSeconds(window, fallback: detail), let pct = kimiUsedPercent(detail) else { continue }
            candidates.append(Candidate(seconds: seconds, usedPercent: pct, resetsAt: kimiResetDate(detail, now: now)))
        }
        func nearest(to target: Int, tolerance: Int) -> Candidate? {
            candidates.filter { abs($0.seconds - target) <= tolerance }.min { abs($0.seconds - target) < abs($1.seconds - target) }
        }
        var windows: [AgentQuotaWindow] = []
        if let fiveHour = nearest(to: 5 * 3600, tolerance: 1800) {
            windows.append(AgentQuotaWindow(id: "fiveHour", label: "5 小时窗口", usedPercent: fiveHour.usedPercent, windowSeconds: fiveHour.seconds, resetsAt: fiveHour.resetsAt))
        }
        if let sevenDay = nearest(to: 7 * 86400, tolerance: 86400) {
            windows.append(AgentQuotaWindow(id: "sevenDay", label: "每周窗口", usedPercent: sevenDay.usedPercent, windowSeconds: sevenDay.seconds, resetsAt: sevenDay.resetsAt))
        } else if let summary = root["usage"] as? [String: Any], let pct = kimiUsedPercent(summary) {
            windows.append(AgentQuotaWindow(id: "sevenDay", label: "每周窗口", usedPercent: pct, windowSeconds: 7 * 86400, resetsAt: kimiResetDate(summary, now: now)))
        }
        if let usages = root["usages"] as? [String: Any] {
            for (key, id, label, seconds) in [("limit_5h", "fiveHour", "5 小时窗口", 5 * 3600), ("limit_7d", "sevenDay", "每周窗口", 7 * 86400)] {
                if let entry = usages[key] as? [String: Any], let ratio = decimalValue(entry["used_ratio"]) {
                    let pct = ratio * Decimal(100)
                    let reset = kimiResetDate(entry, now: now)
                    if let idx = windows.firstIndex(where: { $0.id == id }) {
                        windows[idx].usedPercent = max(windows[idx].usedPercent, pct)
                        windows[idx].resetsAt = windows[idx].resetsAt ?? reset
                    } else { windows.append(AgentQuotaWindow(id: id, label: label, usedPercent: pct, windowSeconds: seconds, resetsAt: reset)) }
                }
            }
            if let monthly = usages["limit_month_total"] as? [String: Any], let ratio = decimalValue(monthly["used_ratio"]) {
                windows.append(AgentQuotaWindow(id: "month_total", label: "每月总额度", usedPercent: ratio * Decimal(100), resetsAt: kimiResetDate(monthly, now: now)))
            }
            if let coding = usages["limit_month_code"] as? [String: Any], let ratio = decimalValue(coding["used_ratio"]) {
                windows.append(AgentQuotaWindow(id: "month_code", label: "Kimi Code 每月额度", usedPercent: ratio * Decimal(100), resetsAt: kimiResetDate(coding, now: now)))
            }
        }
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .window, source: .activeAPI,
            status: windows.contains { $0.usedPercent >= 100 } ? .exhausted : .available,
            windows: windows, billingURL: QuotaPoolIdentity.billingURL(for: provider), updatedAt: now)
    }

    // MARK: - GitHub Copilot

    private static func queryGitHubCopilot(poolID: String, provider: AgentProvider, accountLabel: String?, credentials: OAuthCredentials, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        var req = URLRequest(url: URL(string: "https://api.github.com/copilot_internal/user")!)
        req.httpMethod = "GET"
        req.setValue("Bearer \(credentials.access)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("vscode/1.107.0", forHTTPHeaderField: "Editor-Version")
        req.setValue("copilot-chat/0.35.0", forHTTPHeaderField: "Editor-Plugin-Version")
        req.setValue("GitHubCopilotChat/0.35.0", forHTTPHeaderField: "User-Agent")
        let data = try await sendChecked(req, transport: transport)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaAdapterError.undecodable }
        let planName = (root["copilot_plan"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resetAt = parseTimestamp(root["quota_reset_date_utc"] ?? root["quota_reset_date"])
        var windows: [AgentQuotaWindow] = []
        var balances: [AgentQuotaBalance] = []
        if let snapshots = root["quota_snapshots"] as? [String: Any] {
            let specs: [(key: String, id: String, label: String)] = [("premium_interactions", "copilot-premium", "高级请求"), ("chat", "copilot-chat", "对话"), ("completions", "copilot-completions", "补全")]
            for spec in specs {
                guard let entry = snapshots[spec.key] as? [String: Any] else { continue }
                let unlimited = boolValue(entry["unlimited"]) ?? false
                let entitlement = decimalValue(entry["entitlement"])
                let remaining = decimalValue(entry["remaining"])
                let percentRemaining = decimalValue(entry["percent_remaining"])
                let usedPercent: Decimal
                if unlimited { usedPercent = 0 }
                else if let percentRemaining { usedPercent = max(0, min(100, Decimal(100) - percentRemaining)) }
                else if let entitlement, entitlement > 0, let remaining { usedPercent = max(0, min(100, ((entitlement - remaining) / entitlement) * Decimal(100))) }
                else { continue }
                windows.append(AgentQuotaWindow(id: spec.id, label: spec.label, usedPercent: usedPercent, windowSeconds: 30 * 86400, resetsAt: resetAt, status: unlimited ? "unlimited" : nil))
                if !unlimited, let entitlement, let remaining {
                    balances.append(AgentQuotaBalance(id: spec.id, currency: nil, unitLabel: "次请求", isAvailable: remaining > 0, total: entitlement, used: max(0, entitlement - remaining), remaining: remaining, isUnlimited: false))
                }
            }
        }
        guard !windows.isEmpty || !balances.isEmpty else { throw QuotaAdapterError.undecodable }
        let exhausted = !windows.isEmpty && windows.allSatisfy { $0.usedPercent >= 100 && $0.status != "unlimited" }
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .window, source: .activeAPI, status: exhausted ? .exhausted : .available, balances: balances, windows: windows, planName: planName, billingURL: QuotaPoolIdentity.billingURL(for: provider), updatedAt: now)
    }

    // MARK: - kwwk OAuthUsage 桥接（Cursor、Kiro、Qoder、WorkBuddy、xAI）

    private static func queryKWWKSubscription(poolID: String, provider: AgentProvider, storeID: String, accountLabel: String?, credentials: OAuthCredentials, kwwkUsage: any KWWKQuotaUsageProvider, now: Date) async throws -> AgentQuotaSnapshot {
        let rawWindows: [OAuthUsageWindow]
        do {
            guard let fetched = try await kwwkUsage.usage(for: storeID, credentials: credentials) else { throw QuotaAdapterError.endpointUnsupported(status: 404) }
            rawWindows = fetched
        } catch let error as OAuthUsageError {
            switch error {
            case let .rateLimited(seconds): throw QuotaAdapterError.rateLimited(retryAfterSeconds: seconds)
            case let .unavailable(_, status?, detail):
                if status == 401 || status == 403 { throw QuotaAdapterError.unauthorized }
                if status == 404 || status == 405 || status == 410 || status == 501 { throw QuotaAdapterError.endpointUnsupported(status: status) }
                throw QuotaAdapterError.httpStatus(status, summary: detail.isEmpty ? "HTTP \(status)" : detail)
            case let .unavailable(_, nil, detail): throw QuotaAdapterError.httpStatus(0, summary: detail)
            }
        }
        let windows: [AgentQuotaWindow] = rawWindows.enumerated().map { index, item in
            let id: String
            if let limitID = item.limitID, !limitID.isEmpty { id = "\(limitID):\(item.window.rawValue)" }
            else {
                switch item.window {
                case .fiveHour: id = "fiveHour"
                case .sevenDay: id = "sevenDay"
                case .primary: id = index == 0 ? "primary" : "primary:\(index)"
                case .secondary: id = "secondary:\(index)"
                }
            }
            let baseName = item.limitName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let label: String
            if let baseName, !baseName.isEmpty {
                switch item.window {
                case .fiveHour: label = "\(baseName)（5 小时）"
                case .sevenDay: label = "\(baseName)（7 天）"
                case .primary, .secondary: label = baseName
                }
            } else {
                switch item.window {
                case .fiveHour: label = "5 小时窗口"
                case .sevenDay: label = "每周窗口"
                case .primary: label = "主要窗口"
                case .secondary: label = "次要窗口"
                }
            }
            let rounded = Decimal(string: String(format: "%.2f", item.usedPercent), locale: posix) ?? Decimal(item.usedPercent)
            let resetsAt = item.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0) / 1000.0) }
            return AgentQuotaWindow(id: id, label: label, usedPercent: rounded, windowSeconds: item.windowSeconds, resetsAt: resetsAt)
        }
        let exhausted = !windows.isEmpty && windows.contains { $0.usedPercent >= 100 }
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .window, source: .activeAPI, status: exhausted ? .exhausted : .available, windows: windows, billingURL: QuotaPoolIdentity.billingURL(for: provider), updatedAt: now)
    }

    // MARK: - 中转探测：Sub2API → New API → OpenAI Billing

    private static func queryRelay(rootURL: URL, endpointKey: String, poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, cachedProbe: RelayProbeKind?, transport: any QuotaHTTPTransport, now: Date) async throws -> QuotaQueryResult {
        if let cachedProbe {
            switch cachedProbe {
            case .sub2api:
                if let snap = try await probeSub2API(rootURL: rootURL, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: apiKey, transport: transport, now: now) { return QuotaQueryResult(snapshot: snap, endpointKey: endpointKey, relayProbeKind: .sub2api) }
            case .newapi:
                if let snap = try await probeNewAPI(rootURL: rootURL, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: apiKey, transport: transport, now: now) { return QuotaQueryResult(snapshot: snap, endpointKey: endpointKey, relayProbeKind: .newapi) }
            case .openAIBilling:
                if let snap = try await probeOpenAIBilling(rootURL: rootURL, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: apiKey, transport: transport, now: now) { return QuotaQueryResult(snapshot: snap, endpointKey: endpointKey, relayProbeKind: .openAIBilling) }
            case .unsupported: throw QuotaAdapterError.relayProbeExhausted
            }
        }
        if let snap = try await probeSub2API(rootURL: rootURL, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: apiKey, transport: transport, now: now) { return QuotaQueryResult(snapshot: snap, endpointKey: endpointKey, relayProbeKind: .sub2api) }
        if let snap = try await probeNewAPI(rootURL: rootURL, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: apiKey, transport: transport, now: now) { return QuotaQueryResult(snapshot: snap, endpointKey: endpointKey, relayProbeKind: .newapi) }
        if let snap = try await probeOpenAIBilling(rootURL: rootURL, poolID: poolID, provider: provider, accountLabel: accountLabel, apiKey: apiKey, transport: transport, now: now) { return QuotaQueryResult(snapshot: snap, endpointKey: endpointKey, relayProbeKind: .openAIBilling) }
        throw QuotaAdapterError.relayProbeExhausted
    }

    static func probeSub2API(rootURL: URL, poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot? {
        var req = URLRequest(url: rootURL.appendingPathComponent("v1/usage"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = try await sendProbe(req, transport: transport), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let payload = (root["data"] as? [String: Any]) ?? root
        let sub = payload["subscription"] as? [String: Any]
        let remaining = decimalValue(payload["remaining"] ?? payload["balance"] ?? sub?["remaining"])
        let used = decimalValue(payload["used"] ?? payload["usage"] ?? sub?["used"])
        let total = decimalValue(payload["limit"] ?? payload["total"] ?? payload["quota"] ?? sub?["limit"])
        let planName = (payload["planName"] as? String) ?? (payload["plan_name"] as? String) ?? (sub?["plan_name"] as? String)
        let isActive = boolValue(payload["isActive"] ?? payload["is_active"])
        let unit = (payload["unit"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard remaining != nil || total != nil || used != nil || isActive != nil || sub != nil else { return nil }
        let currency = (payload["currency"] as? String)?.uppercased() ?? (unit == nil || unit == "USD" ? "USD" : nil)
        let effectiveRemaining = remaining ?? total.map { $0 - (used ?? 0) }
        let available = (isActive ?? true) && ((effectiveRemaining ?? 1) > 0)
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance, source: .probedRelay, status: available ? .available : .exhausted,
            balances: [AgentQuotaBalance(id: "sub2api", currency: currency, unitLabel: currency == nil ? (unit ?? "quota") : nil, isAvailable: available, total: total, used: used, remaining: effectiveRemaining)],
            planName: planName, relayKind: "sub2api", updatedAt: now)
    }

    static func probeNewAPI(rootURL: URL, poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot? {
        var req = URLRequest(url: rootURL.appendingPathComponent("api/usage/token"))
        req.httpMethod = "GET"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let data = try await sendProbe(req, transport: transport), let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        // New API 常见响应外层为 code 或 success 布尔值与 data。
        if let code = boolValue(root["code"]), code == false { return nil }
        if let success = boolValue(root["success"]), success == false { return nil }
        let payload = (root["data"] as? [String: Any]) ?? root
        let unlimited = boolValue(payload["unlimited_quota"]) ?? false
        let availableQuota = decimalValue(payload["total_available"] ?? payload["remain_quota"])
        let usedQuota = decimalValue(payload["total_used"] ?? payload["used_quota"])
        let grantedQuota = decimalValue(payload["total_granted"] ?? payload["quota"])
        guard availableQuota != nil || usedQuota != nil || grantedQuota != nil || payload["unlimited_quota"] != nil else { return nil }
        let total = grantedQuota ?? availableQuota.flatMap { avail in usedQuota.map { avail + $0 } }
        let isAvailable = unlimited || ((availableQuota ?? 0) > 0)
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance, source: .probedRelay, status: isAvailable ? .available : .exhausted,
            balances: [AgentQuotaBalance(id: "newapi-quota", currency: nil, unitLabel: "quota", isAvailable: isAvailable, total: unlimited ? nil : total, granted: unlimited ? nil : grantedQuota, used: usedQuota, remaining: unlimited ? nil : availableQuota, isUnlimited: unlimited)],
            planName: (payload["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), relayKind: "newapi", updatedAt: now)
    }

    static func probeOpenAIBilling(rootURL: URL, poolID: String, provider: AgentProvider, accountLabel: String?, apiKey: String, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot? {
        func request(_ path: String) -> URLRequest {
            var request = URLRequest(url: rootURL.appendingPathComponent(path))
            request.httpMethod = "GET"
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            return request
        }
        let formatter = DateFormatter()
        formatter.locale = posix
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        let start = Calendar(identifier: .gregorian).date(byAdding: .day, value: -90, to: now) ?? now
        let end = Calendar(identifier: .gregorian).date(byAdding: .day, value: 1, to: now) ?? now
        let prefixes = ["v1/dashboard/billing", "dashboard/billing"]
        for prefix in prefixes {
            guard let data = try await sendProbe(request(prefix + "/subscription"), transport: transport),
                  let subscription = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let limit = decimalValue(subscription["hard_limit_usd"] ?? subscription["system_hard_limit_usd"] ?? subscription["soft_limit_usd"])
            else { continue }
            let unlimited = limit >= Decimal(100_000_000)
            var used: Decimal?
            // 用量优先访问与订阅相同的前缀；混合部署可再试另一种路径。
            for usagePrefix in [prefix] + prefixes.filter({ $0 != prefix }) {
                var components = URLComponents(url: request(usagePrefix + "/usage").url!, resolvingAgainstBaseURL: false)!
                components.queryItems = [URLQueryItem(name: "start_date", value: formatter.string(from: start)), URLQueryItem(name: "end_date", value: formatter.string(from: end))]
                var usageRequest = request(usagePrefix + "/usage")
                usageRequest.url = components.url
                if let usageData = try await sendProbe(usageRequest, transport: transport),
                   let usage = try? JSONSerialization.jsonObject(with: usageData) as? [String: Any],
                   let cents = decimalValue(usage["total_usage"]) {
                    used = cents / Decimal(100)
                    break
                }
            }
            // 查不到消费量不等于尚未消费，不能把总限额伪装成剩余余额。
            guard unlimited || used != nil else { throw QuotaAdapterError.undecodable }
            let remaining = unlimited ? nil : used.map { limit - $0 }
            let available = unlimited || (remaining ?? 0) > 0
            return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance, source: .probedRelay, status: available ? .available : .exhausted,
                balances: [AgentQuotaBalance(id: "openai-billing", currency: "USD", isAvailable: available, total: unlimited ? nil : limit, used: used, remaining: remaining, isUnlimited: unlimited)],
                planName: (subscription["plan"] as? [String: Any])?["title"] as? String, relayKind: "openaiBilling", updatedAt: now)
        }
        return nil
    }

    // MARK: - HTTP 与解析辅助方法

    static func sendChecked(_ request: URLRequest, transport: any QuotaHTTPTransport) async throws -> Data {
        let (response, data) = try await transport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw QuotaAdapterError.unauthorized }
        if response.statusCode == 429 { throw QuotaAdapterError.rateLimited(retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)) }
        if response.statusCode == 404 || response.statusCode == 405 || response.statusCode == 410 || response.statusCode == 501 { throw QuotaAdapterError.endpointUnsupported(status: response.statusCode) }
        guard (200 ..< 300).contains(response.statusCode) else { throw QuotaAdapterError.httpStatus(response.statusCode, summary: "HTTP \(response.statusCode)") }
        guard data.count <= 4 * 1024 * 1024 else { throw QuotaAdapterError.undecodable }
        return data
    }

    private static func sendProbe(_ request: URLRequest, transport: any QuotaHTTPTransport) async throws -> Data? {
        let (response, data) = try await transport.send(request)
        if response.statusCode == 401 || response.statusCode == 403 { throw QuotaAdapterError.unauthorized }
        if response.statusCode == 429 { throw QuotaAdapterError.rateLimited(retryAfterSeconds: response.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)) }
        guard (200 ..< 300).contains(response.statusCode), data.count <= 4 * 1024 * 1024 else { return nil }
        return data
    }

    private static func tryOptionalSend(_ request: URLRequest, transport: any QuotaHTTPTransport) async -> Result<Data, Error> {
        do { return try .success(await sendChecked(request, transport: transport)) } catch { return .failure(error) }
    }

    public static func decimalValue(_ value: Any?) -> Decimal? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return nil }
            let decimal = number.decimalValue
            return decimal.isNaN ? nil : decimal
        }
        if let text = value as? String { return QuotaDecimalCoding.parse(text) }
        return nil
    }

    public static func boolValue(_ value: Any?) -> Bool? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
        if let bool = value as? Bool { return bool }
        if let text = value as? String {
            switch text.lowercased() {
            case "true", "1", "yes": return true
            case "false", "0", "no": return false
            default: return nil
            }
        }
        return nil
    }

    public static func intValue(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.intValue }
        if let text = value as? String { return Int(text) }
        return nil
    }

    private static func dateFromUnix(_ value: Any?) -> Date? {
        guard let num = decimalValue(value) else { return nil }
        let dbl = NSDecimalNumber(decimal: num).doubleValue
        guard dbl.isFinite, dbl > 0 else { return nil }
        return dbl > 1e12 ? Date(timeIntervalSince1970: dbl / 1000) : Date(timeIntervalSince1970: dbl)
    }

    public static func parseTimestamp(_ value: Any?) -> Date? {
        if let date = dateFromUnix(value) { return date }
        guard let raw = value as? String else { return nil }
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dot = text.firstIndex(of: "."), let zone = text[dot...].firstIndex(where: { "Z+-".contains($0) }) { text.removeSubrange(dot ..< zone) }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: text)
    }

    private static func kimiWindowSeconds(_ window: [String: Any], fallback: [String: Any]) -> Int? {
        guard let duration = intValue(window["duration"]) ?? intValue(fallback["duration"]), duration > 0 else { return nil }
        let unit = ((window["timeUnit"] as? String) ?? (fallback["timeUnit"] as? String) ?? "").uppercased()
        if unit.contains("MINUTE") { return duration * 60 }
        if unit.contains("HOUR") { return duration * 3600 }
        if unit.contains("DAY") { return duration * 86400 }
        return duration
    }

    private static func kimiUsedPercent(_ detail: [String: Any]) -> Decimal? {
        guard let limit = decimalValue(detail["limit"]), limit > 0 else { return nil }
        let used = decimalValue(detail["used"]) ?? decimalValue(detail["remaining"]).map { limit - $0 }
        guard let used else { return nil }
        return (used / limit) * Decimal(100)
    }

    private static func kimiResetDate(_ detail: [String: Any], now: Date) -> Date? {
        for key in ["reset_at", "resetAt", "reset_time", "resetTime"] { if let date = parseTimestamp(detail[key]) { return date } }
        for key in ["reset_in", "resetIn", "ttl"] { if let seconds = intValue(detail[key]), seconds > 0 { return now.addingTimeInterval(TimeInterval(seconds)) } }
        return nil
    }

    private static func windowDisplayLabel(seconds: Int?, prefix: String?, fallbackSlot: String) -> String {
        let base: String = switch seconds {
        case 18000: "5 小时"
        case 604_800: "每周"
        case let sec? where sec >= 86400: "\(sec / 86400) 天"
        case let sec? where sec >= 3600: "\(sec / 3600) 小时"
        case let sec? where sec >= 60: "\(sec / 60) 分钟"
        default: fallbackSlot == "primary" ? "主要" : (fallbackSlot == "secondary" ? "次要" : fallbackSlot)
        }
        if let prefix, !prefix.isEmpty { return "\(prefix)（\(base)）" }
        return "\(base)窗口"
    }
}
