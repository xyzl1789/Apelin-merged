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

    /// 一次查询的结果：金额文字、单位、圆环比例，以及（可选）总额度。
    private struct Figure: Sendable {
        var amount: String
        var unit: String
        var fraction: Double?
    }

    /// 一个连接的余额接口：只对 HTTPS、白名单域名发 GET，不跟随重定向。
    private struct Adapter: Sendable {
        var path: String
        var header: (String, String)?
        var parse: @Sendable (Data) -> Figure?
        /// limit_remaining 为空时补查的第二个地址。
        var fallbackPath: String?
    }

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
                  let adapter = Self.adapter(host: base.host, provider: provider)
            else { continue }
            let key = Self.cacheKey(storeID: storeID, base: base, credential: credential)
            let file = directory.appendingPathComponent(key + ".json", isDirectory: false)
            let cached = Self.read(file)
            let age = cached.map { Date().timeIntervalSince($0.updatedAt) } ?? .infinity
            if !force, let cached, age < cacheTTL {
                lines.append(Self.line(storeID: storeID, provider: provider, host: base.host,
                                       figure: Figure(amount: cached.amount, unit: cached.unit, fraction: cached.fraction),
                                       updatedAt: cached.updatedAt, stale: false, problem: nil))
                continue
            }
            do {
                let figure = try await Self.readFigure(base: base, credential: credential, adapter: adapter)
                let now = Date()
                let item = Cached(amount: figure.amount, unit: figure.unit, fraction: figure.fraction, updatedAt: now)
                try? JSONCoding.encode(item).write(to: file, options: .atomic)
                lines.append(Self.line(storeID: storeID, provider: provider, host: base.host,
                                       figure: figure, updatedAt: now, stale: false, problem: nil))
            } catch {
                // 本来支持、只是这次没查到：保留圆环，显示上次缓存或失败说明。
                let problem = (error as? Problem) ?? .unexpected
                let fallback = cached.map { Figure(amount: $0.amount, unit: $0.unit, fraction: $0.fraction) }
                    ?? Figure(amount: "--", unit: "", fraction: nil)
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

    /// 兼容模式手填的 baseURL 优先；没有则用该服务商表单的默认值。
    private static func baseURL(provider: AgentProvider, credentials: OAuthCredentials) -> (host: String, scheme: String, root: URL)? {
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
        parts.path = ""
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        guard let url = parts.url else { return nil }
        return (host, parts.scheme?.lowercased() ?? "https", url)
    }

    /// 按域名匹配，不区分「原生」与「兼容模式」。排除官方不提供余额的域名。
    private static func adapter(host: String, provider: AgentProvider) -> Adapter? {
        switch host {
        case "api.deepseek.com":
            return Adapter(path: "/user/balance", header: nil, parse: { data in
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
                return Figure(amount: Self.text(total), unit: Self.cleanUnit(unit ?? "CNY"), fraction: nil)
            }, fallbackPath: nil)
        case "api.moonshot.cn":
            return Adapter(path: "/v1/users/me/balance", header: nil, parse: { data in
                guard let value = json(data)?["data"]?["available_balance"],
                      let amount = Self.decimal(value) else { return nil }
                return Figure(amount: Self.text(amount), unit: "CNY", fraction: nil)
            }, fallbackPath: nil)
        case "api.siliconflow.cn":
            return Adapter(path: "/v1/user/info", header: nil, parse: { data in
                guard let value = json(data)?["data"]?["totalBalance"],
                      let amount = Self.decimal(value) else { return nil }
                return Figure(amount: Self.text(amount), unit: "CNY", fraction: nil)
            }, fallbackPath: nil)
        case "openrouter.ai":
            return Adapter(path: "/api/v1/key", header: nil, parse: { data in
                guard let object = json(data)?["data"] else { return nil }
                let remaining = object["limit_remaining"]
                if remaining == nil || remaining == .null {
                    return nil // 交给 /api/v1/credits 补查
                }
                guard let amount = Self.decimal(remaining) else { return nil }
                let limit = Self.decimal(object["limit"])
                let fraction = limit.flatMap { $0 > 0 ? Self.ratio(amount / $0) : nil }
                return Figure(amount: Self.text(amount), unit: "USD", fraction: fraction)
            }, fallbackPath: "/api/v1/credits")
        default:
            // 中转站兜底：只接受有 /v1/usage 且明文声明余额的响应。
            guard provider == .openAICompatible || provider.kind == .openAICompatible else { return nil }
            return Adapter(path: "/v1/usage", header: nil, parse: { data in
                guard let object = json(data)?["data"] else { return nil }
                let value = object["balance"] ?? object["remaining"]
                guard let amount = Self.decimal(value) else { return nil }
                let unit = Self.cleanUnit(object["unit"]?.stringValue ?? "")
                return Figure(amount: Self.text(amount), unit: unit, fraction: nil)
            }, fallbackPath: nil)
        }
    }

    /// 只发只读 GET：禁止重定向、响应体限长、独立 ephemeral session。
    private static func readFigure(
        base: (host: String, scheme: String, root: URL),
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

    private static func request(
        base: (host: String, scheme: String, root: URL),
        credential: OAuthCredentials,
        adapter: Adapter,
        path: String,
    ) async throws -> Figure? {
        guard let url = URL(string: path, relativeTo: base.root)?.absoluteURL else { throw Problem.unexpected }
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeoutSeconds))
        request.httpMethod = "GET"
        request.setValue("Bearer \(credential.access)", forHTTPHeaderField: "Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let (name, value) = adapter.header {
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
        guard (200 ... 299).contains(http.statusCode) else { throw Self.problem(status: http.statusCode) }
        var body = Data()
        for try await byte in bytes {
            guard body.count < maximumBodyBytes else { throw Problem.unexpected }
            body.append(byte)
        }
        return adapter.parse(body)
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

    private static func cacheKey(storeID: String, base: (host: String, scheme: String, root: URL), credential: OAuthCredentials) -> String {
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
