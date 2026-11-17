import ApelinProtocol
import Foundation

extension Notification.Name {
    static let providerBalancesChanged = Notification.Name("wiki.qaq.apelin.providerBalancesChanged")
}

/// The app's last read of every provider balance. The worker owns the
/// network and the short cache; this store is only the figure the composer's
/// ring and the balance page both draw, so a manual refresh on the page is
/// seen by the ring without a second request.
@MainActor
final class ProviderBalanceStore {
    static let shared = ProviderBalanceStore()

    private(set) var balances: [ProviderBalance] = []
    private var inFlight: Task<[ProviderBalance], Never>?

    /// Reads the balances once, joining a request already running. A failed
    /// request keeps the last figures rather than replacing them with empty.
    @discardableResult
    func refresh(force: Bool = false) async -> [ProviderBalance] {
        if let inFlight {
            return await inFlight.value
        }
        let previous = balances
        let task = Task<[ProviderBalance], Never> {
            do {
                return try await ApelinService.app.agentProviderBalances(force: force).balances
            } catch {
                return previous
            }
        }
        inFlight = task
        let next = await task.value
        inFlight = nil
        balances = next
        NotificationCenter.default.post(name: .providerBalancesChanged, object: nil)
        return next
    }

    /// The figure the composer draws: the selected provider's own balance.
    /// A provider without a queried balance gets none at all — the button hides
    /// rather than borrowing another provider's figure.
    func current(for provider: AgentProvider?) -> ProviderBalance? {
        guard let provider else { return nil }
        return balances.first(where: { $0.provider == provider })
    }
}
