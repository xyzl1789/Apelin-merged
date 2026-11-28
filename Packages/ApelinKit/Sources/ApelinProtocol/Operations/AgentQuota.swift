import Foundation

/// 额度的十进制线协议，避免金额和百分比在 JSON 编解码中产生浮点误差。
public enum QuotaDecimalCoding {
    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    public static func encode(_ value: Decimal) -> String {
        var copy = value
        return NSDecimalString(&copy, posixLocale)
    }

    public static func decode(from decoder: any Decoder) throws -> Decimal {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self), let decimal = parse(text) {
            return decimal
        }
        if let decimal = try? container.decode(Decimal.self) { return decimal }
        if let number = try? container.decode(Double.self), number.isFinite { return Decimal(number) }
        throw DecodingError.dataCorruptedError(in: container, debugDescription: "额度不是有效的十进制数")
    }

    public static func parse(_ text: String) -> Decimal? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.range(of: #"^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: trimmed, locale: posixLocale), !decimal.isNaN
        else { return nil }
        return decimal
    }
}

/// 额度池的展示方式。
public enum AgentQuotaPoolKind: String, Codable, Sendable, Equatable {
    /// 货币或原始单位余额。
    case balance
    /// 滚动限流或订阅窗口。
    case window
    /// 无公开额度接口，仅提供官方账单入口。
    case billingLink
}

/// 最近快照的来源。
public enum AgentQuotaSource: String, Codable, Sendable, Equatable {
    case activeAPI
    case passiveHeaders
    case probedRelay
    case billingLink
}

/// 额度池当前可用状态。
public enum AgentQuotaStatus: String, Codable, Sendable, Equatable {
    case available
    case exhausted
    case cooldown
    case circuitBroken
    case unsupported
    case error
}

/// 单一币种或原始计量单位的余额池。
public struct AgentQuotaBalance: Codable, Sendable, Equatable, Hashable {
    public var id: String
    /// ISO 币种代码；原始中转额度为 nil。
    public var currency: String?
    /// 无币种时的单位后缀，例如 New API 的 `quota`。
    public var unitLabel: String?
    public var isAvailable: Bool
    public var total: Decimal?
    public var granted: Decimal?
    public var toppedUp: Decimal?
    public var used: Decimal?
    public var remaining: Decimal?
    public var isUnlimited: Bool

    public init(
        id: String,
        currency: String? = nil,
        unitLabel: String? = nil,
        isAvailable: Bool = true,
        total: Decimal? = nil,
        granted: Decimal? = nil,
        toppedUp: Decimal? = nil,
        used: Decimal? = nil,
        remaining: Decimal? = nil,
        isUnlimited: Bool = false,
    ) {
        self.id = id
        self.currency = currency
        self.unitLabel = unitLabel
        self.isAvailable = isAvailable
        self.total = total
        self.granted = granted
        self.toppedUp = toppedUp
        self.used = used
        self.remaining = remaining
        self.isUnlimited = isUnlimited
    }

    private enum CodingKeys: String, CodingKey {
        case id, currency, unitLabel, isAvailable, total, granted, toppedUp, used, remaining, isUnlimited
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        currency = try c.decodeIfPresent(String.self, forKey: .currency)
        unitLabel = try c.decodeIfPresent(String.self, forKey: .unitLabel)
        isAvailable = try c.decodeIfPresent(Bool.self, forKey: .isAvailable) ?? true
        total = try Self.decodeOptionalDecimal(c, forKey: .total)
        granted = try Self.decodeOptionalDecimal(c, forKey: .granted)
        toppedUp = try Self.decodeOptionalDecimal(c, forKey: .toppedUp)
        used = try Self.decodeOptionalDecimal(c, forKey: .used)
        remaining = try Self.decodeOptionalDecimal(c, forKey: .remaining)
        isUnlimited = try c.decodeIfPresent(Bool.self, forKey: .isUnlimited) ?? false
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encodeIfPresent(currency, forKey: .currency)
        try c.encodeIfPresent(unitLabel, forKey: .unitLabel)
        try c.encode(isAvailable, forKey: .isAvailable)
        try c.encodeIfPresent(total.map(QuotaDecimalCoding.encode), forKey: .total)
        try c.encodeIfPresent(granted.map(QuotaDecimalCoding.encode), forKey: .granted)
        try c.encodeIfPresent(toppedUp.map(QuotaDecimalCoding.encode), forKey: .toppedUp)
        try c.encodeIfPresent(used.map(QuotaDecimalCoding.encode), forKey: .used)
        try c.encodeIfPresent(remaining.map(QuotaDecimalCoding.encode), forKey: .remaining)
        try c.encode(isUnlimited, forKey: .isUnlimited)
    }

    private static func decodeOptionalDecimal(_ c: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys) throws -> Decimal? {
        guard c.contains(key), try !c.decodeNil(forKey: key) else { return nil }
        return try QuotaDecimalCoding.decode(from: c.superDecoder(forKey: key))
    }
}

/// 归一化至 0…100 百分比的滚动窗口。
public struct AgentQuotaWindow: Codable, Sendable, Equatable, Hashable {
    public var id: String
    public var label: String
    public var usedPercent: Decimal
    public var windowSeconds: Int?
    public var resetsAt: Date?
    public var status: String?

    public var remainingPercent: Decimal { max(0, min(100, 100 - usedPercent)) }

    public init(id: String, label: String, usedPercent: Decimal, windowSeconds: Int? = nil, resetsAt: Date? = nil, status: String? = nil) {
        self.id = id
        self.label = label
        self.usedPercent = max(0, min(100, usedPercent))
        self.windowSeconds = windowSeconds
        self.resetsAt = resetsAt
        self.status = status
    }

    private enum CodingKeys: String, CodingKey { case id, label, usedPercent, windowSeconds, resetsAt, status }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        let rawUsed = try QuotaDecimalCoding.decode(from: c.superDecoder(forKey: .usedPercent))
        usedPercent = max(0, min(100, rawUsed))
        windowSeconds = try c.decodeIfPresent(Int.self, forKey: .windowSeconds)
        resetsAt = try c.decodeIfPresent(Date.self, forKey: .resetsAt)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(label, forKey: .label)
        try c.encode(QuotaDecimalCoding.encode(usedPercent), forKey: .usedPercent)
        try c.encodeIfPresent(windowSeconds, forKey: .windowSeconds)
        try c.encodeIfPresent(resetsAt, forKey: .resetsAt)
        try c.encodeIfPresent(status, forKey: .status)
    }
}

/// 已脱敏的账号额度快照，不含密钥、鉴权头或原始提供商响应。
public struct AgentQuotaSnapshot: Codable, Sendable, Equatable {
    /// 去重标识：`key:<sha256_prefix16>` 或 `oauth:<storeID>`。
    public var poolID: String
    public var provider: AgentProvider
    public var accountLabel: String?
    public var kind: AgentQuotaPoolKind
    public var source: AgentQuotaSource
    public var status: AgentQuotaStatus
    public var balances: [AgentQuotaBalance]
    public var windows: [AgentQuotaWindow]
    public var planName: String?
    public var relayKind: String?
    public var billingURL: URL?
    public var updatedAt: Date?
    public var nextAllowedAt: Date?
    public var manualDebounceUntil: Date?
    public var cooldownUntil: Date?
    public var circuitBrokenUntil: Date?
    public var errorSummary: String?

    public init(
        poolID: String, provider: AgentProvider, accountLabel: String? = nil,
        kind: AgentQuotaPoolKind, source: AgentQuotaSource, status: AgentQuotaStatus,
        balances: [AgentQuotaBalance] = [], windows: [AgentQuotaWindow] = [],
        planName: String? = nil, relayKind: String? = nil, billingURL: URL? = nil,
        updatedAt: Date? = nil, nextAllowedAt: Date? = nil, manualDebounceUntil: Date? = nil,
        cooldownUntil: Date? = nil, circuitBrokenUntil: Date? = nil, errorSummary: String? = nil,
    ) {
        self.poolID = poolID
        self.provider = provider
        self.accountLabel = accountLabel
        self.kind = kind
        self.source = source
        self.status = status
        self.balances = balances
        self.windows = windows
        self.planName = planName
        self.relayKind = relayKind
        self.billingURL = billingURL
        self.updatedAt = updatedAt
        self.nextAllowedAt = nextAllowedAt
        self.manualDebounceUntil = manualDebounceUntil
        self.cooldownUntil = cooldownUntil
        self.circuitBrokenUntil = circuitBrokenUntil
        self.errorSummary = errorSummary
    }
}

/// 协调器应用缓存与防抖的方式。
public enum AgentQuotaFetchMode: String, Codable, Sendable, Equatable {
    /// 仅返回脱敏缓存，不发起网络请求。
    case cachedOnly
    /// 超过前后台统一的 30 秒间隔后才刷新。
    case attentionGated
    /// 手动刷新；即使强制刷新，也遵守 30 秒手动防抖。
    case manualRefresh
}

/// 仅供应用调用，由凭据导入工作进程处理。
public struct AgentProviderQuotaRequest: OperationRequest {
    public typealias Response = AgentProviderQuotaResponse
    public static let operation = AppOperation.agentProviderQuota
    public var provider: AgentProvider?
    /// 精确指定账号；nil 保持按提供商或全部账号查询的旧行为。
    public var accountID: String?
    public var mode: AgentQuotaFetchMode
    /// 设置页面是否处于前台。
    public var foreground: Bool
    /// 显式绕过熔断和中转探测缓存，不绕过手动防抖。
    public var force: Bool

    public init(provider: AgentProvider? = nil, mode: AgentQuotaFetchMode = .attentionGated, foreground: Bool = true, force: Bool = false, accountID: String? = nil) {
        self.provider = provider
        self.accountID = accountID
        self.mode = mode
        self.foreground = foreground
        self.force = force
    }
}

public struct AgentProviderQuotaResponse: Codable, Sendable, Equatable {
    public var quotas: [AgentQuotaSnapshot]
    public init(quotas: [AgentQuotaSnapshot] = []) { self.quotas = quotas }
}

public extension ApelinService {
    func agentProviderQuota(provider: AgentProvider? = nil, mode: AgentQuotaFetchMode = .attentionGated, foreground: Bool = true, force: Bool = false, accountID: String? = nil) async throws -> AgentProviderQuotaResponse {
        try await send(AgentProviderQuotaRequest(provider: provider, mode: mode, foreground: foreground, force: force, accountID: accountID))
    }
}
