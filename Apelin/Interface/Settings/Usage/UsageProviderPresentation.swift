import ApelinCore
import ApelinProtocol
import Foundation

/// 两个统计入口统一从本机读取最新备注，备注不进入 worker 的凭据或请求。
enum UsageProviderPresentation {
    static var note: String {
        String(localized: "When adding multiple model providers with the same API address, give each a different note to distinguish their usage.")
    }

    static func summaries(_ records: [UsageRecord], includingCache: Bool = false) -> [UsageProviderSummary] {
        var titles: [String: String] = [:]
        for identity in Set(records.compactMap(\.providerIdentity)) {
            guard let provider = AgentProvider(rawValue: identity.accountID) else { continue }
            if let note = Preferences.ProviderNotes.note(for: provider),
               !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                titles[identity.accountID] = note
            } else if provider.kind != .openAICompatible {
                titles[identity.accountID] = provider.displayName
            }
            // 自定义端点无备注时交给共享汇总显示域名，不显示通用协议名称。
        }
        return UsageProviderSummary.summarize(
            records,
            titles: titles,
            unknown: String(localized: "未知供应商"),
            includingCache: includingCache,
        )
    }
}
