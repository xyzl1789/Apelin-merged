import Foundation
import ApelinProtocol

public struct PassiveQuotaObservation: Sendable, Equatable {
    public var provider: AgentProvider
    public var storeID: String
    public var windows: [AgentQuotaWindow]
    public var balances: [AgentQuotaBalance]
    public var planName: String?
    public var isExhausted: Bool

    public init(provider: AgentProvider, storeID: String, windows: [AgentQuotaWindow], balances: [AgentQuotaBalance] = [], planName: String? = nil, isExhausted: Bool = false) {
        self.provider = provider
        self.storeID = storeID
        self.windows = windows
        self.balances = balances
        self.planName = planName
        self.isExhausted = isExhausted
    }
}

/// 解析 Anthropic/Codex OAuth 响应头，包括 429 响应；不阻塞请求流。
public enum PassiveQuotaHeaderParser {
    public static func lowercasedHeaders(from response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (rawKey, rawValue) in response.allHeaderFields {
            guard let key = (rawKey as? String)?.lowercased() else { continue }
            if key.hasPrefix("anthropic-ratelimit-unified-") || key.hasPrefix("x-codex-") {
                result[key] = String(describing: rawValue).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return result
    }

    public static func parse(storeID: String, statusCode: Int, headers: [String: String], now: Date = Date()) -> PassiveQuotaObservation? {
        let normalized = Dictionary(
            headers.map { ($0.key.lowercased(), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) },
            uniquingKeysWith: { _, latest in latest },
        )
        switch storeID {
        case CredentialProviderID.anthropicOAuth: return parseAnthropic(statusCode: statusCode, headers: normalized, now: now)
        case "openai-codex": return parseCodex(statusCode: statusCode, headers: normalized, now: now)
        default: return nil
        }
    }

    // MARK: - Anthropic 统一限流响应头

    private static func parseAnthropic(statusCode: Int, headers: [String: String], now: Date) -> PassiveQuotaObservation? {
        let unified = headers.filter { $0.key.hasPrefix("anthropic-ratelimit-unified-") }
        guard !unified.isEmpty else { return nil }
        var windows: [AgentQuotaWindow] = []
        let specs: [(prefix: String, id: String, label: String, seconds: Int?)] = [
            ("anthropic-ratelimit-unified-5h", "fiveHour", "5 小时窗口", 5 * 3600),
            ("anthropic-ratelimit-unified-7d", "sevenDay", "每周窗口", 7 * 86400),
            ("anthropic-ratelimit-unified-overage", "overage", "超额窗口", nil),
        ]
        for spec in specs {
            let status = unified["\(spec.prefix)-status"]?.lowercased()
            let reset = parseResetDate(unified["\(spec.prefix)-reset"], afterSeconds: nil, now: now)
            let rawUtil = unified["\(spec.prefix)-utilization"].flatMap(QuotaDecimalCoding.parse)
            if let rawUtil {
                windows.append(AgentQuotaWindow(id: spec.id, label: spec.label, usedPercent: normalizedAnthropicHeaderPercent(rawUtil), windowSeconds: spec.seconds, resetsAt: reset, status: status))
            } else if statusCode == 429, status == "rejected", spec.id != "overage" {
                windows.append(AgentQuotaWindow(id: spec.id, label: spec.label, usedPercent: 100, windowSeconds: spec.seconds, resetsAt: reset, status: status))
            }
        }

        // 缺少 5 小时或 7 天前缀时，回退到通用单窗口响应头。
        if windows.isEmpty {
            let claim = unified["anthropic-ratelimit-unified-representative-claim"]?.lowercased()
            let status = unified["anthropic-ratelimit-unified-status"]?.lowercased()
            let reset = parseResetDate(unified["anthropic-ratelimit-unified-reset"], afterSeconds: nil, now: now)
            let rawUtil = unified["anthropic-ratelimit-unified-utilization"].flatMap(QuotaDecimalCoding.parse)
            let (id, label, seconds): (String, String, Int?) = switch claim {
            case "five_hour", "5h": ("fiveHour", "5 小时窗口", 5 * 3600)
            case "seven_day", "7d", "weekly": ("sevenDay", "每周窗口", 7 * 86400)
            case let other? where !other.isEmpty: (other, other.replacingOccurrences(of: "_", with: " ").capitalized, nil)
            default: ("primary", "限流窗口", nil)
            }
            if let rawUtil {
                windows.append(AgentQuotaWindow(id: id, label: label, usedPercent: normalizedAnthropicHeaderPercent(rawUtil), windowSeconds: seconds, resetsAt: reset, status: status))
            } else if statusCode == 429, status == "rejected" {
                windows.append(AgentQuotaWindow(id: id, label: label, usedPercent: 100, windowSeconds: seconds, resetsAt: reset, status: status))
            }
        }
        guard !windows.isEmpty else { return nil }
        let overageStatus = unified["anthropic-ratelimit-unified-overage-status"]?.lowercased()
        let overageAllows = overageStatus == "allowed" || overageStatus == "allowed_warning"
        let overallRejected = unified["anthropic-ratelimit-unified-status"]?.lowercased() == "rejected"
        let windowRejected = windows.contains { $0.id != "overage" && ($0.status == "rejected" || $0.usedPercent >= 100) }
        let exhausted = (statusCode == 429 && (overallRejected || windowRejected) && !overageAllows) || (windowRejected && !overageAllows)
        return PassiveQuotaObservation(provider: .anthropicOAuth, storeID: CredentialProviderID.anthropicOAuth, windows: windows, isExhausted: exhausted)
    }

    /// 响应头利用率通常是 0…1；大于 2 时按百分数处理。
    public static func normalizedAnthropicHeaderPercent(_ raw: Decimal) -> Decimal {
        let ratio = raw > Decimal(2) ? (raw / Decimal(100)) : raw
        return max(0, min(100, ratio * Decimal(100)))
    }

    // MARK: - Codex 限流响应头

    private static func parseCodex(statusCode: Int, headers: [String: String], now: Date) -> PassiveQuotaObservation? {
        let codex = headers.filter { $0.key.hasPrefix("x-codex-") }
        guard !codex.isEmpty else { return nil }
        var windows: [AgentQuotaWindow] = []
        for slot in ["primary", "secondary"] {
            let prefix = "x-codex-\(slot)"
            guard let rawPercent = codex["\(prefix)-used-percent"].flatMap(QuotaDecimalCoding.parse) else { continue }
            let minutes = codex["\(prefix)-window-minutes"].flatMap(Int.init)
            let seconds = minutes.flatMap { $0 > 0 ? $0 * 60 : nil }
            let resetAt = parseResetDate(codex["\(prefix)-reset-at"], afterSeconds: codex["\(prefix)-reset-after-seconds"], now: now)
            let (id, label): (String, String) = switch seconds {
            case 18000: ("fiveHour", "5 小时窗口")
            case 604_800: ("sevenDay", "每周窗口")
            default: (slot, slot == "primary" ? "主要窗口" : "次要窗口")
            }
            windows.append(AgentQuotaWindow(id: id, label: label, usedPercent: max(0, min(100, rawPercent)), windowSeconds: seconds, resetsAt: resetAt))
        }
        var balances: [AgentQuotaBalance] = []
        let hasCredits = codex["x-codex-credits-has-credits"]?.lowercased() == "true"
        let unlimited = codex["x-codex-credits-unlimited"]?.lowercased() == "true"
        let creditBalance = codex["x-codex-credits-balance"].flatMap(QuotaDecimalCoding.parse)
        if hasCredits || unlimited || creditBalance != nil {
            balances.append(AgentQuotaBalance(id: "codex-credits", currency: "USD", isAvailable: unlimited || ((creditBalance ?? 0) > 0), total: creditBalance, remaining: creditBalance, isUnlimited: unlimited))
        }
        let planName = codex["x-codex-plan-type"].flatMap { $0.isEmpty ? nil : $0 }
        guard !windows.isEmpty || !balances.isEmpty || planName != nil else { return nil }
        let hasAvailableCredits = balances.contains { $0.isAvailable || $0.isUnlimited }
        let exhausted = ((statusCode == 429) || windows.contains { $0.usedPercent >= 100 }) && !hasAvailableCredits
        return PassiveQuotaObservation(provider: .openAICodex, storeID: "openai-codex", windows: windows, balances: balances, planName: planName, isExhausted: exhausted)
    }

    private static func parseResetDate(_ rawReset: String?, afterSeconds: String?, now: Date) -> Date? {
        if let rawReset, !rawReset.isEmpty, let date = QuotaAdapters.parseTimestamp(rawReset) { return date }
        if let afterSeconds, let delta = QuotaDecimalCoding.parse(afterSeconds) {
            let secs = NSDecimalNumber(decimal: delta).doubleValue
            if secs.isFinite, secs >= 0 { return now.addingTimeInterval(secs) }
        }
        return nil
    }
}
