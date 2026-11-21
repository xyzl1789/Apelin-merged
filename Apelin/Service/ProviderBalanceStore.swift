import ApelinProtocol
import Foundation
import os.log

extension Notification.Name {
    static let providerBalancesChanged = Notification.Name("wiki.qaq.apelin.providerBalancesChanged")
}

/// App 保存的每个连接最近一次余额。网络与短缓存归 worker；这个 store 只
/// 保存胶囊与余额页共用的数字，所以余额页的手动刷新胶囊立刻可见，不必再
/// 请求一次。胶囊只画当前选中连接自己的数字，不支持查询时显示「--」；
/// 切换连接后若上次读取已超过 `autoInterval`，就为支持的连接刷新一次。
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

    /// 胶囊只画当前选中连接自己的余额；这个连接不支持查询、还没查到或
    /// 根本没选中时，返回 nil，胶囊显示「--」，绝不借别的连接的数字来充数。
    /// 点开胶囊仍能看到所有能查到余额的连接。
    func current(for provider: AgentProvider?) -> ProviderBalance? {
        guard let provider else { return nil }
        return balances.first { $0.provider == provider }
    }
}
