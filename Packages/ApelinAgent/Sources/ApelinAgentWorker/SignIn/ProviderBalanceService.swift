import ApelinAgent
import ApelinCore
import ApelinProtocol
import CryptoKit
import Foundation
import KWWKAI

/// 各服务商余额的只读查询：密钥留在凭据 worker 里，回给 App 的只有金额、
/// 单位、时间和脱敏后的错误分类。一个地址没有余额接口就是「不显示」，
/// 绝不是余额为 0。
enum ProviderBalanceService {
    private static let maximumBodyBytes = 64 * 1024
    private static let timeoutSeconds = 15
    private static let cacheTTL: TimeInterval = 5 * 60
    private static let maximumAmountLength = 38
    private static let maximumUnitLength = 32
    private static let userAgent = "Apelin-Balance/1.0"

    /// 一次查询的结果：金额文字、单位、圆环比例、探测出的中转站类型，以及
    /// （可选）总额度。
    struct Figure: Sendable {
        var amount: String
        var unit: String
        var fraction: Double?
        var relayKind: String?
    }

    /// 一次只读 GET 的回执。只有按 token 计量的站点需要响应头，其余家族
    /// 仍只看响应体；headers 只放白名单里的额度字段，绝不带其它头。
    struct Reply: Sendable {
        var body: Data
        var headers: [String: String]
    }

    /// 一个连接的余额接口：只对 HTTPS、已配置的域名发 GET，不跟随重定向。
    /// `recognize` 只认响应结构，不读原始文本；认不出返回 nil，由调用方继续
    /// 探测下一个候选。`fallbackPath` 是主地址认得出结构但取不到金额时补查的
    /// 第二个地址（OpenRouter 的 credits）。
    struct Adapter: Sendable {
        var path: String
        var header: (String, String)?
        var recognize: @Sendable (Data) -> Bool
        var parse: @Sendable (Data) -> Figure?
        var fallbackPath: String?

        init(path: String, header: (String, String)? = nil,
             recognize: @escaping @Sendable (Data) -> Bool,
             parse: @escaping @Sendable (Data) -> Figure?,
             fallbackPath: String? = nil) {
            self.path = path
            self.header = header
            self.recognize = recognize
            self.parse = parse
            self.fallbackPath = fallbackPath
        }
    }

    /// 自定义中转站的探测家族，按探测顺序排列。类型名只用于展示与记忆，
    /// 端点路径是公开的固定字符串，绝不由用户输入的路径拼出。
    /// tokenQuota 放最后：`/v1/models` 只要密钥就 200，不能抢在计费家族前面。
    enum RelayFamily: String, Sendable, CaseIterable {
        case sub2api, newAPI, openAIBilling, tokenQuota

        var path: String {
            switch self {
            case .sub2api: "/v1/usage"
            case .newAPI: "/api/usage/token"
            case .openAIBilling: "/v1/dashboard/billing/subscription"
            case .tokenQuota: "/v1/models"
            }
        }

        var label: String {
            switch self {
            case .sub2api: "Sub2API"
            case .newAPI: "New API"
            case .openAIBilling: "OpenAI-compatible billing"
            case .tokenQuota: "今日 token 配额"
            }
        }

        var display: String {
            switch self {
            case .tokenQuota: label
            default: "\(label) · \(path)"
            }
        }

        var memoryKey: String { rawValue }
    }

    /// 按 token 计量的站点用的响应头白名单：只把这些值交给解析，其它头
    /// （含任何鉴权或 Cookie）都不离开 worker。
    private static let quotaHeaders = ["x-quota-limit", "x-quota-used", "x-quota-remaining"]

    /// 探测类型的记忆：24 小时内只访问已认出的家族；上次失败或过期则全探测。
    private struct RelayMemory: Codable, Sendable {
        var family: String
        var probedAt: Date
    }

    private static let relayMemoryTTL: TimeInterval = 24 * 3600

    /// 网络错误只留下分类，绝不把服务器文本、URL query 或密钥带出去。
    private enum Problem: Error {
        case offline
        case unauthorized
        case rateLimited
        case refused
        case unexpected

        var text: String {
            switch self {
            case .offline: "网络不可用"
            case .unauthorized: "密钥无效或没有余额权限"
            case .rateLimited: "查询过于频繁"
            case .refused: "服务商没有提供余额"
            case .unexpected: "余额暂时无法读取"
            }
        }
    }

    private struct Cached: Codable, Sendable {
        var amount: String
        var unit: String
        var fraction: Double?
        var updatedAt: Date
        var relayKind: String?
    }

    /// 并发查询同一个连接时合并；这里只按连接的缓存键去重，App 与详情页
    /// 的两次请求还由 AccountDesk 的 in-flight Task 合并。
    static func lookup(
        force: Bool,
        accounts: [(String, OAuthCredentials)],
        dataRoot: URL,
    ) async throws -> AgentProviderBalancesResponse {
        let directory = dataRoot.appendingPathComponent("Usage", isDirectory: true)
            .appendingPathComponent("Balances", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var lines: [ProviderBalance] = []
        for (storeID, credential) in accounts {
            guard let provider = Self.provider(for: storeID) else { continue }
            // OAuth 订阅连接没有可直接查询的余额接口；明确关闭的适配器也不查。
            guard ProviderModels.usesAPIKey(provider, credentials: credential),
                  Self.adapterOff(credential) == false,
                  let base = Self.baseURL(provider: provider, credentials: credential),
                  Self.adapter(host: base.host, provider: provider) != nil
            else { continue }
            let key = Self.cacheKey(storeID: storeID, base: base, credential: credential)
            let file = directory.appendingPathComponent(key + ".json", isDirectory: false)
            let memoryFile = directory.appendingPathComponent(key + ".relay.json", isDirectory: false)
            let cached = Self.read(file)
            let age = cached.map { Date().timeIntervalSince($0.updatedAt) } ?? .infinity
            if !force, let cached, age < cacheTTL {
                lines.append(Self.line(storeID: storeID, provider: provider, host: base.host,
                                       figure: Figure(amount: cached.amount, unit: cached.unit,
                                                      fraction: cached.fraction, relayKind: cached.relayKind),
                                       updatedAt: cached.updatedAt, stale: false, problem: nil))
                continue
            }
            // 自定义中转站：从记忆里取 24 小时内认出的家族，只查它一个端点。
            let hint: RelayFamily? = if base.isRelay {
                Self.relayHint(file: memoryFile, now: Date())
            } else {
                nil
            }
            do {
                let result: Figure
                if base.isRelay {
                    let probed = try await Self.readRelay(base: base, credential: credential, hint: hint)
                    result = probed.figure
                    if probed.fresh {
                        Self.saveRelayMemory(probed.family, file: memoryFile, now: Date())
                    }
                } else {
                    guard let adapter = Self.adapter(host: base.host, provider: provider) else { throw Problem.refused }
                    result = try await Self.readFigure(base: base, credential: credential, adapter: adapter)
                }
                let now = Date()
                let item = Cached(amount: result.amount, unit: result.unit, fraction: result.fraction,
                                  updatedAt: now, relayKind: result.relayKind)
                try? JSONCoding.encode(item).write(to: file, options: .atomic)
                lines.append(Self.line(storeID: storeID, provider: provider, host: base.host,
                                       figure: result, updatedAt: now, stale: false, problem: nil))
            } catch {
                // 本来支持、只是这次没查到：保留圆环，显示上次缓存或失败说明。
                let problem = (error as? Problem) ?? .unexpected
                let fallback = cached.map {
                    Figure(amount: $0.amount, unit: $0.unit, fraction: $0.fraction, relayKind: $0.relayKind)
                } ?? Figure(amount: "--", unit: "", fraction: nil, relayKind: nil)
                lines.append(Self.line(storeID: storeID, provider: provider, host: base.host,
                                       figure: fallback, updatedAt: cached?.updatedAt ?? Date(),
                                       stale: true, problem: problem.text))
            }
        }
        return AgentProviderBalancesResponse(balances: lines)
    }

    /// 一个 store id 对应的 provider；编号的兼容端点也算 openAICompatible。
    private static func provider(for storeID: String) -> AgentProvider? {
        if let number = CredentialProviderID.endpointNumber(storeID) {
            return .openAICompatibleEndpoint(number)
        }
        return AgentProvider.allCases.first { $0.storeID == storeID }
    }

    private static func adapterOff(_ credential: OAuthCredentials) -> Bool {
        guard case let .string(value)? = credential.extras["balanceAdapter"] else { return false }
        return value.lowercased() == "off"
    }

    /// 一个连接的根地址。官方域名保留原路径（它们的 adapter 用绝对路径，
    /// URL 相对根解析时路径会被替换，因此保留与否都不影响官方查询）；自定义
    /// 中转站剥掉末尾的 /v1 但保留 /gw/v1 这类路径前缀，再在其后拼家族端点。
    struct Base: Sendable {
        var host: String
        var scheme: String
        var root: URL
        var isRelay: Bool
    }

    /// 官方余额域名：命中的走固定 adapter，其余自定义的走中转站探测。
    private static let officialBalanceHosts: Set<String> = [
        "api.deepseek.com", "api.moonshot.cn", "api.siliconflow.cn", "openrouter.ai",
    ]

    /// 兼容模式手填的 baseURL 优先；没有则用该服务商表单的默认值。
    static func baseURL(provider: AgentProvider, credentials: OAuthCredentials) -> Base? {
        let configured: String? = if case let .string(value)? = credentials.extras[AgentSignInField.baseURL.rawValue],
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            value
        } else {
            // 留空的可选字段存的是空字符串，与「没填」同义：回退默认值。
            nil
        }
        let fallback = provider.keyFields.first { $0.field == .baseURL }?.defaultValue
            ?? (provider == .openRouter ? "https://openrouter.ai/api/v1" : nil)
        guard let text = configured ?? fallback,
              var parts = URLComponents(string: text),
              parts.scheme?.lowercased() == "https",
              let host = parts.host?.lowercased(), !host.isEmpty
        else { return nil }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        let isRelay = !officialBalanceHosts.contains(host)
        if isRelay {
            var path = parts.path
            while path.hasSuffix("/") { path.removeLast() }
            if path.lowercased().hasSuffix("/v1") { path.removeLast(3) }
            while path.hasSuffix("/") { path.removeLast() }
            parts.path = path
        }
        guard let url = parts.url else { return nil }
        return Base(host: host, scheme: parts.scheme?.lowercased() ?? "https", root: url, isRelay: isRelay)
    }

    /// 按域名匹配，不区分「原生」与「兼容模式」。排除官方不提供余额的域名。
    private static func adapter(host: String, provider: AgentProvider) -> Adapter? {
        switch host {
        case "api.deepseek.com":
            return Adapter(path: "/user/balance", recognize: { _ in true }, parse: { data in
                guard let object = json(data), case let .array(list)? = object["balance_infos"] else { return nil }
                var total: Decimal = 0
                var unit: String?
                var found = false
                for entry in list {
                    guard let amount = Self.decimal(entry["total_balance"]),
                          let currency = entry["currency"]?.stringValue, !currency.isEmpty else { continue }
                    total += amount
                    unit = currency
                    found = true
                }
                guard found else { return nil }
                return Figure(amount: Self.text(total), unit: Self.cleanUnit(unit ?? "CNY"), fraction: nil, relayKind: nil)
            }, fallbackPath: nil)
        case "api.moonshot.cn":
            return Adapter(path: "/v1/users/me/balance", recognize: { data in
                json(data)?["data"]?["available_balance"] != nil
            }, parse: { data in
                guard let value = json(data)?["data"]?["available_balance"],
                      let amount = Self.decimal(value) else { return nil }
                return Figure(amount: Self.text(amount), unit: "CNY", fraction: nil, relayKind: nil)
            }, fallbackPath: nil)
        case "api.siliconflow.cn":
            return Adapter(path: "/v1/user/info", recognize: { data in
                json(data)?["data"]?["totalBalance"] != nil
            }, parse: { data in
                guard let value = json(data)?["data"]?["totalBalance"],
                      let amount = Self.decimal(value) else { return nil }
                return Figure(amount: Self.text(amount), unit: "CNY", fraction: nil, relayKind: nil)
            }, fallbackPath: nil)
        case "openrouter.ai":
            return Adapter(path: "/api/v1/key", recognize: { data in
                json(data)?["data"] != nil
            }, parse: { data in
                guard let object = json(data)?["data"] else { return nil }
                let remaining = object["limit_remaining"]
                if remaining == nil || remaining == .null {
                    return nil // 交给 /api/v1/credits 补查
                }
                guard let amount = Self.decimal(remaining) else { return nil }
                let limit = Self.decimal(object["limit"])
                let fraction = limit.flatMap { $0 > 0 ? Self.ratio(amount / $0) : nil }
                return Figure(amount: Self.text(amount), unit: "USD", fraction: fraction, relayKind: nil)
            }, fallbackPath: "/api/v1/credits")
        default:
            // 自定义中转站由 readRelay 顺序探测；这里只让兼容模式通过 lookup 的守卫。
            guard provider == .openAICompatible || provider.kind == .openAICompatible else { return nil }
            return Adapter(path: "", recognize: { _ in false }, parse: { _ in nil }, fallbackPath: nil)
        }
    }

    /// 只发只读 GET：禁止重定向、响应体限长、独立 ephemeral session。
    private static func readFigure(
        base: Base,
        credential: OAuthCredentials,
        adapter: Adapter,
    ) async throws -> Figure {
        if let figure = try await request(base: base, credential: credential, adapter: adapter, path: adapter.path) {
            return figure
        }
        if let fallback = adapter.fallbackPath,
           let figure = try await request(base: base, credential: credential, adapter: adapter, path: fallback) {
            return figure
        }
        throw Problem.refused
    }

    /// 自定义中转站：按记忆的家族（没有就按 sub2api → newAPI → openAIBilling）
    /// 顺序探测。结构认得出就用那个家族解析；全认不出才报 refused。所有家族
    /// 都拒绝密钥时直接报 unauthorized，不当成「没有余额接口」。
    private static func readRelay(
        base: Base,
        credential: OAuthCredentials,
        hint: RelayFamily?,
    ) async throws -> (figure: Figure, family: RelayFamily, fresh: Bool) {
        var families = RelayFamily.allCases
        if let hint, let index = families.firstIndex(of: hint) {
            families = [hint] + families.enumerated().filter { $0.offset != index }.map(\.element)
        }
        var errors: [Problem] = []
        for family in families {
            do {
                let figure: Figure
                if family == .tokenQuota {
                    guard let reply = try await rawRequest(base: base, credential: credential,
                                                           path: family.path, collectHeaders: Self.quotaHeaders),
                          let parsed = Self.parseTokenQuota(reply.headers)
                    else { throw Problem.refused }
                    figure = parsed
                } else {
                    let adapter = relayAdapter(family)
                    guard let reply = try await rawRequest(base: base, credential: credential, path: family.path),
                          adapter.recognize(reply.body),
                          let parsed = adapter.parse(reply.body)
                    else { throw Problem.refused }
                    figure = parsed
                }
                var result = figure
                if family == .openAIBilling,
                   let usage = try? await rawRequest(base: base, credential: credential,
                                                     path: "/v1/dashboard/billing/usage")
                {
                    result = parseOpenAIUsage(usage.body, into: result)
                }
                result.relayKind = family.display
                return (result, family, hint != family)
            } catch let problem as Problem {
                errors.append(problem)
                // 已认出的家族这次只是拒绝密钥：直接报，别再挨个试。
                if hint == family, problem == .unauthorized { throw problem }
            } catch {
                errors.append(.unexpected)
            }
        }
        if !errors.isEmpty, errors.allSatisfy({ $0 == .unauthorized }) { throw Problem.unauthorized }
        throw Problem.refused
    }

    /// 每个家族的响应结构与金额解析。结构识别只认公开字段名，不读原始文本。
    static func relayAdapter(_ family: RelayFamily) -> Adapter {
        switch family {
        case .sub2api:
            return Adapter(path: family.path, recognize: { data in
                json(data)?["isValid"]?.boolValue != nil
            }, parse: { data in
                guard let object = json(data) else { return nil }
                var total: Decimal?
                var remaining: Decimal?
                var unlimited = false
                if (object["mode"]?.stringValue) == "quota_limited",
                   let quota = object["quota"]
                {
                    total = Self.decimal(quota["limit"])
                    remaining = Self.decimal(quota["remaining"]).map { max(0, $0) }
                } else if Self.decimal(object["balance"]) != nil {
                    remaining = Self.decimal(object["balance"])
                } else {
                    let value = Self.decimal(object["remaining"])
                    if let value, value < 0 {
                        unlimited = true
                    } else {
                        remaining = value
                    }
                }
                guard remaining != nil || total != nil || unlimited else { return nil }
                let fraction = unlimited ? nil : total.flatMap { $0 > 0 ? Self.ratio((remaining ?? 0) / $0) : nil }
                return Figure(amount: Self.text(remaining ?? total ?? 0), unit: "USD",
                              fraction: fraction, relayKind: nil)
            })
        case .newAPI:
            return Adapter(path: family.path, recognize: { data in
                guard let d = json(data)?["data"] else { return false }
                return d["total_granted"] != nil || d["total_available"] != nil
            }, parse: { data in
                guard let d = json(data)?["data"] else { return nil }
                let granted = Self.decimal(d["total_granted"])
                let available = Self.decimal(d["total_available"])
                let unlimited = (d["unlimited_quota"]?.boolValue == true) || (granted.map { $0 < 0 } ?? false)
                guard unlimited || available != nil || granted != nil else { return nil }
                let fraction = unlimited ? nil : granted.flatMap { $0 > 0 ? Self.ratio((available ?? 0) / $0) : nil }
                return Figure(amount: Self.text(available ?? granted ?? 0), unit: "quota",
                              fraction: fraction, relayKind: nil)
            })
        case .openAIBilling:
            return Adapter(path: family.path, recognize: { data in
                guard let o = Self.unwrapBilling(json(data)) else { return false }
                return o["hard_limit_usd"] != nil || o["balance"] != nil
            }, parse: { data in
                guard let sub = Self.unwrapBilling(json(data)) else { return nil }
                var total: Decimal?
                var remaining: Decimal?
                var unlimited = false
                if let balance = Self.decimal(sub["balance"]) {
                    remaining = balance
                } else if let hard = Self.decimal(sub["hard_limit_usd"]) {
                    if hard >= 100_000_000 {
                        unlimited = true
                    } else {
                        total = hard
                    }
                } else {
                    return nil
                }
                guard remaining != nil || total != nil || unlimited else { return nil }
                let fraction = unlimited ? nil : total.flatMap { $0 > 0 ? Self.ratio((remaining ?? 0) / $0) : nil }
                return Figure(amount: Self.text(remaining ?? total ?? 0), unit: "USD",
                              fraction: fraction, relayKind: nil)
            })
        case .tokenQuota:
            // 这个家族只认响应头，不认 body；readRelay 走 parseTokenQuota 分支。
            return Adapter(path: family.path, recognize: { _ in false }, parse: { _ in nil })
        }
    }

    /// 从白名单响应头读今日 token 配额。limit 与 remaining 缺一不可，
    /// 数字先按十进制文本校验，避免把畸形头画成一个假余额。
    static func parseTokenQuota(_ headers: [String: String]) -> Figure? {
        guard let limitText = headers["x-quota-limit"],
              let remainingText = headers["x-quota-remaining"],
              let limit = Decimal(string: limitText, locale: Locale(identifier: "en_US_POSIX")),
              let remainingRaw = Decimal(string: remainingText, locale: Locale(identifier: "en_US_POSIX")),
              limit > 0
        else { return nil }
        let remaining = max(0, remainingRaw)
        let fraction = Self.ratio(remaining / limit)
        return Figure(amount: Self.text(remaining), unit: "tokens",
                      fraction: fraction, relayKind: nil)
    }

    /// OpenAI 计费兼容的补查：`/usage` 里的 total_usage 单位是美分。
    private static func parseOpenAIUsage(_ data: Data, into figure: Figure) -> Figure {
        var result = figure
        guard let object = Self.unwrapBilling(json(data)) else { return result }
        let cents = Self.decimal(object["total_usage"]).map { $0 / 100 }
        let spent = cents ?? Self.decimal(object["used_usd"])
        if let spent, let total = Self.decimal(object["hard_limit_usd"]), total > 0 {
            result.fraction = Self.ratio(max(0, (total - spent) / total))
        }
        return result
    }

    private static func unwrapBilling(_ object: ApelinCore.JSONValue?) -> ApelinCore.JSONValue? {
        guard let object else { return nil }
        if let inner = object["data"] { return inner }
        return object
    }

    private static func relayHint(file: URL, now: Date) -> RelayFamily? {
        guard let data = try? Data(contentsOf: file),
              let memory = try? JSONCoding.decoder().decode(RelayMemory.self, from: data),
              now.timeIntervalSince(memory.probedAt) < relayMemoryTTL,
              let family = RelayFamily(rawValue: memory.family)
        else { return nil }
        return family
    }

    private static func saveRelayMemory(_ family: RelayFamily, file: URL, now: Date) {
        let memory = RelayMemory(family: family.memoryKey, probedAt: now)
        try? JSONCoding.encode(memory).write(to: file, options: .atomic)
    }

    private static func request(
        base: Base,
        credential: OAuthCredentials,
        adapter: Adapter,
        path: String,
    ) async throws -> Figure? {
        guard let reply = try await rawRequest(base: base, credential: credential, path: path, header: adapter.header)
        else { return nil }
        return adapter.parse(reply.body)
    }

    /// 发出一次只读 GET，2xx 返回回执（响应体 + 白名单响应头）；404/405/501
    /// 视为「没有这个接口」返回 nil（继续探测），其他错误抛 Problem。
    private static func rawRequest(
        base: Base,
        credential: OAuthCredentials,
        path: String,
        header: (String, String)? = nil,
        collectHeaders: [String]? = nil,
    ) async throws -> Reply? {
        let url: URL
        if base.isRelay {
            // 中转站：端点路径拼到 root 的路径后面，保留 /gw 这类前缀。
            let rootPath = base.root.path.hasSuffix("/") ? String(base.root.path.dropLast()) : base.root.path
            guard var components = URLComponents(url: base.root, resolvingAgainstBaseURL: false) else {
                throw Problem.unexpected
            }
            components.path = rootPath + path
            guard let resolved = components.url else { throw Problem.unexpected }
            url = resolved
        } else {
            // 官方域名：adapter 用绝对路径，替换整个路径。
            guard let resolved = URL(string: path, relativeTo: base.root)?.absoluteURL else {
                throw Problem.unexpected
            }
            url = resolved
        }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeoutSeconds))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.access)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (name, value) = header {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(timeoutSeconds)
        let session = URLSession(configuration: configuration, delegate: RedirectHold(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw Self.problem(error)
        }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else { throw Problem.unexpected }
        if http.statusCode == 404 || http.statusCode == 405 || http.statusCode == 501 { return nil }
        guard (200 ... 299).contains(http.statusCode) else { throw Self.problem(status: http.statusCode) }
        var body = Data()
        for try await byte in bytes {
            guard body.count < maximumBodyBytes else { throw Problem.unexpected }
            body.append(byte)
        }
        var headers: [String: String] = [:]
        if let collectHeaders {
            for name in collectHeaders {
                if let value = http.value(forHTTPHeaderField: name) {
                    headers[name.lowercased()] = value
                }
            }
        }
        return Reply(body: body, headers: headers)
    }

    private static func problem(status: Int) -> Problem {
        switch status {
        case 401, 403: .unauthorized
        case 429: .rateLimited
        case 404, 405, 501: .refused
        default: .unexpected
        }
    }

    private static func problem(_ error: Error) -> Problem {
        let code = (error as? URLError)?.code
        switch code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
             .dataNotAllowed:
            return .offline
        default:
            return .unexpected
        }
    }

    // MARK: - 数值与缓存

    /// JSON 数字先按原始文本读回，避免 Double 丢精度；金额最多 38 位。
    private static func decimal(_ value: ApelinCore.JSONValue?) -> Decimal? {
        guard let value else { return nil }
        let text: String?
        switch value {
        case let .string(value): text = value
        case let .number(value): text = String(value)
        case .null, .bool, .array, .object: return nil
        }
        guard let text, text.count <= maximumAmountLength,
              let number = Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")),
              NSDecimalNumber(decimal: number).doubleValue.isFinite else { return nil }
        return number
    }

    private static func text(_ value: Decimal) -> String {
        var number = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &number, 4, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }

    private static func ratio(_ value: Decimal) -> Double {
        min(max(NSDecimalNumber(decimal: value).doubleValue, 0), 1)
    }

    private static func cleanUnit(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= maximumUnitLength ? trimmed : ""
    }

    private static func json(_ data: Data) -> ApelinCore.JSONValue? {
        // JSONValue 把数字读成 Double；金额先给裸数字加引号，保留原始十进制
        // 文本，再由 Decimal 解析。字符串、对象和数组都原样不动。
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let quoted = Self.quoteNumbers(in: text)
        return try? JSONCoding.decoder().decode(ApelinCore.JSONValue.self, from: Data(quoted.utf8))
    }

    /// 给对象值位置的裸数字加引号。只处理 -?digits(.digits)?([eE][+-]?digits)?，
    /// 不改动字符串内部、键、布尔值与 null。
    private static func quoteNumbers(in text: String) -> String {
        var out = ""
        var index = text.startIndex
        var inString = false
        var escaped = false
        while index < text.endIndex {
            let character = text[index]
            if inString {
                out.append(character)
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = text.index(after: index)
                continue
            }
            if character == "\"" {
                inString = true
                out.append(character)
                index = text.index(after: index)
                continue
            }
            let isStart = character == "-" || (character >= "0" && character <= "9")
            if isStart, let end = Self.numberEnd(in: text, from: index) {
                out.append("\"")
                out.append(contentsOf: text[index ..< end])
                out.append("\"")
                index = end
            } else {
                out.append(character)
                index = text.index(after: index)
            }
        }
        return out
    }

    private static func numberEnd(in text: String, from start: String.Index) -> String.Index? {
        var index = start
        if text[index] == "-" {
            index = text.index(after: index)
            guard index < text.endIndex else { return nil }
        }
        var digits = 0
        while index < text.endIndex, text[index] >= "0", text[index] <= "9" {
            digits += 1
            index = text.index(after: index)
        }
        guard digits > 0 else { return nil }
        if index < text.endIndex, text[index] == "." {
            index = text.index(after: index)
            var fraction = 0
            while index < text.endIndex, text[index] >= "0", text[index] <= "9" {
                fraction += 1
                index = text.index(after: index)
            }
            guard fraction > 0 else { return nil }
        }
        if index < text.endIndex, text[index] == "e" || text[index] == "E" {
            index = text.index(after: index)
            if index < text.endIndex, text[index] == "+" || text[index] == "-" {
                index = text.index(after: index)
            }
            var exponent = 0
            while index < text.endIndex, text[index] >= "0", text[index] <= "9" {
                exponent += 1
                index = text.index(after: index)
            }
            guard exponent > 0 else { return nil }
        }
        return index
    }

    private static func cacheKey(storeID: String, base: Base, credential: OAuthCredentials) -> String {
        let material = [
            storeID, base.root.absoluteString, userAgent, base.host, credential.access,
        ].joined(separator: "\u{1f}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func read(_ url: URL) -> Cached? {
        // persisted-read: 一个坏文件只落回一次网络查询，不会被写回成空状态。
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONCoding.decoder().decode(Cached.self, from: data)
    }

    private static func line(storeID: String, provider: AgentProvider, host: String,
                             figure: Figure, updatedAt: Date, stale: Bool, problem: String?) -> ProviderBalance {
        ProviderBalance(
            accountID: storeID,
            provider: provider,
            label: host,
            amount: figure.amount,
            currency: figure.unit,
            fraction: figure.fraction,
            updatedAt: updatedAt,
            stale: stale,
            problem: problem,
            relayKind: figure.relayKind,
        )
    }
}

///  handing every redirect back unfollowed：余额查询不跟着跳到别处。
private final class RedirectHold: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _: URLSession,
        task _: URLSessionTask,
        willPerformHTTPRedirection _: HTTPURLResponse,
        newRequest _: URLRequest,
    ) async -> URLRequest? {
        nil
    }
}
