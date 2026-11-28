import ApelinProtocol
import Foundation

/// 金额、百分比及重置时间分别格式化，金额始终保留两位小数。
enum QuotaFormatting {
    static func decimalText(_ value: Decimal, maxFractionDigits: Int = 2, minFractionDigits: Int = 0) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = minFractionDigits
        formatter.maximumFractionDigits = maxFractionDigits
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    static func balanceAmountText(_ balance: AgentQuotaBalance, amount: Decimal?) -> String {
        if balance.isUnlimited { return String(localized: "不限额", table: "Quota") }
        guard let amount else { return String(localized: "暂无数据", table: "Quota") }
        if let currency = balance.currency, !currency.isEmpty {
            let formatter = NumberFormatter()
            formatter.numberStyle = .currency
            formatter.currencyCode = currency
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            return formatter.string(from: amount as NSDecimalNumber)
                ?? "\(currency) \(decimalText(amount, maxFractionDigits: 2, minFractionDigits: 2))"
        }
        let number = decimalText(amount, maxFractionDigits: 4)
        return "\(number) \(balance.unitLabel ?? String(localized: "额度", table: "Quota"))"
    }

    static func percentText(_ percent: Decimal) -> String {
        "\(decimalText(max(0, min(100, percent)), maxFractionDigits: 1))%"
    }

    static func shortWindowLabel(_ window: AgentQuotaWindow) -> String {
        switch window.id {
        case "fiveHour": String(localized: "5小时", table: "Quota")
        case "sevenDay": String(localized: "7天", table: "Quota")
        case "overage": String(localized: "超额用量", table: "Quota")
        default: window.label
        }
    }

    static func summaryText(for snapshot: AgentQuotaSnapshot) -> String? {
        let unavailable = ![AgentQuotaStatus.available, .exhausted].contains(snapshot.status)
        let suffix = unavailable ? " · 上次数据" : ""
        if snapshot.kind == .balance, let balance = snapshot.balances.first(where: \.isAvailable) ?? snapshot.balances.first {
            return balanceAmountText(balance, amount: balance.remaining ?? balance.total) + suffix
        }
        let windows = snapshot.windows.prefix(2).map {
            "\(shortWindowLabel($0)) \(percentText($0.usedPercent))"
        }
        if !windows.isEmpty { return windows.joined(separator: " · ") + suffix }
        if let balance = snapshot.balances.first(where: \.isAvailable) ?? snapshot.balances.first {
            return balanceAmountText(balance, amount: balance.remaining ?? balance.total) + suffix
        }
        if unavailable { return String(localized: "无法查询用量", table: "Quota") }
        return snapshot.status == .exhausted ? String(localized: "额度已用尽", table: "Quota") : nil
    }

    static func statusText(for status: AgentQuotaStatus) -> String {
        switch status {
        case .available: String(localized: "可用", table: "Quota")
        case .exhausted: String(localized: "额度已用尽", table: "Quota")
        case .cooldown, .circuitBroken, .unsupported, .error: String(localized: "无法查询用量", table: "Quota")
        }
    }

    static func sourceText(for snapshot: AgentQuotaSnapshot) -> String {
        switch snapshot.source {
        case .activeAPI: String(localized: "主动查询", table: "Quota")
        case .passiveHeaders: String(localized: "响应头", table: "Quota")
        case .billingLink: String(localized: "官方账单页", table: "Quota")
        case .probedRelay:
            switch snapshot.relayKind {
            case "sub2api": "Sub2API"
            case "newapi": "New API"
            case "openaiBilling": "OpenAI Billing"
            default: String(localized: "中转探测", table: "Quota")
            }
        }
    }

    static func resetText(for date: Date, now: Date = Date()) -> String {
        guard date > now else { return String(localized: "正在重置", table: "Quota") }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return String(localized: "重置时间：\(formatter.localizedString(for: date, relativeTo: now))", table: "Quota")
    }

    /// 有额度池身份时只接受精确结果，绝不把另一账号的用量当作本账号。
    static func snapshot(for account: AgentAccount, in quotas: [AgentQuotaSnapshot]) -> AgentQuotaSnapshot? {
        let matches = quotas.filter { $0.provider == account.provider }
        if let poolID = account.poolID {
            return matches.first { $0.poolID == poolID }
        }
        if let label = account.account {
            let labeled = matches.filter { $0.accountLabel == label }
            return labeled.count == 1 ? labeled.first : nil
        }
        return account.storeID == nil && matches.count == 1 ? matches.first : nil
    }
}
