import ApelinProtocol
import Foundation
import os.log

extension Notification.Name {
    static let providerBalancesChanged = Notification.Name("wiki.qaq.apelin.providerBalancesChanged")
}

/// The app's last read of every provider balance. The worker owns the
/// network and the short cache; this store is only the figure the composer's
/// ring and the balance page both draw, so a manual refresh on the page is
/// seen by the ring without a second request. The ring itself shows only
/// while the selected provider publishes a balance; switching providers
/// refreshes it when the last read is older than `autoInterval`.
@MainActor
final class ProviderBalanceStore {
    static let shared = ProviderBalanceStore()

    /// 自动刷新的间隔：进入聊天页或切换供应商时如果距上次查询超过它，
    /// 就立刻查一次。太快会打满服务商的余额接口，太慢则数字失去参考价值。
    private static let autoInterval: TimeInterval = 5 * 60

    private(set) var balances: [ProviderBalance] = []
    private var inFlight: Task<[ProviderBalance], Never>?
    private var lastRefresh: Date?

    /// 距上次查询是否已超过自动间隔。选中支持查询的供应商时由此决定
    /// 是否立刻查一次。
    func stale() -> Bool {
        guard let lastRefresh else { return true }
        return Date().timeIntervalSince(lastRefresh) >= Self.autoInterval
    }

    /// Reads the balances once, joining a request already running. A failed
    /// request keeps the last figures rather than replacing them with empty.
    @discardableResult
    func refresh(force: Bool = false) async -> [ProviderBalance] {
        if let inFlight {
            return await inFlight.value
        }
        lastRefresh = Date()
        let previous = balances
        let task = Task<[ProviderBalance], Never> {
            do {
                let response = try await ApelinService.app.agentProviderBalances(force: force).balances
                Logger(subsystem: "wiki.qaq.apelin", category: "Balance")
                    .info("余额刷新成功：\(response.count, privacy: .public) 条 \(force ? "强制" : "自动", privacy: .public)")
                return response
            } catch {
                Logger(subsystem: "wiki.qaq.apelin", category: "Balance")
                    .error("余额刷新失败：\(String(describing: error), privacy: .public)")
                return previous
            }
        }
        inFlight = task
        let next = await task.value
        inFlight = nil
        balances = next
        Logger(subsystem: "wiki.qaq.apelin", category: "Balance")
            .info("余额存储更新：共 \(next.count, privacy: .public) 条，\(next.map { "\($0.provider.rawValue)=\($0.amount)\($0.currency)" }.joined(separator: ", "), privacy: .public)")
        NotificationCenter.default.post(name: .providerBalancesChanged, object: nil)
        return next
    }

    /// The figure the composer draws: the selected provider's own balance.
    /// The selected provider with no balance of its own still shows the one
    /// figure that exists — an account the reader signed in to later, such as
    /// DeepSeek's, is what the pill names, and the tap opens every provider's
    /// page. Only when nothing reports a balance at all does it hide.
    func current(for provider: AgentProvider?) -> ProviderBalance? {
        if let provider, let own = balances.first(where: { $0.provider == provider }) {
            return own
        }
        let fallback = balances.min { $0.updatedAt < $1.updatedAt }
        Logger(subsystem: "wiki.qaq.apelin", category: "Balance")
            .debug("胶囊取值：provider=\(provider?.rawValue ?? "nil", privacy: .public)，取到 \(fallback.map { "\($0.amount)\($0.currency)" } ?? "无", privacy: .public)")
        return fallback
    }
}
