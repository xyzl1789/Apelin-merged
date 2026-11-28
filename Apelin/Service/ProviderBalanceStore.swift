import ApelinCore
import ApelinProtocol
import Foundation
import os.log

extension Notification.Name {
    static let providerBalancesChanged = Notification.Name("wiki.qaq.apelin.providerBalancesChanged")
}

/// 胶囊、原余额卡片及账号额度页共用新线路；磁盘只保存脱敏快照与账号/池绑定。
@MainActor
final class ProviderBalanceStore {
    static let shared = ProviderBalanceStore()
    private static let autoInterval: TimeInterval = 5 * 60
    private let logger = Logger(subsystem: "wiki.qaq.apelin", category: "Balance")
    private var records = PreservedList<AgentQuotaDisplayRecord>()
    private var writable = true
    private var generation = UUID()
    private var bindings: [String: String] = [:]
    private var inFlight: Task<[ProviderBalance], Never>?
    /// 尝试时间只用于自动查询限频，绝不用于显示「更新时间」。
    private var lastAttempt: Date?
    private let folder: DataFolder
    private let service: ApelinService
    private var file: URL { folder.root.appendingPathComponent("QuotaDisplay.json") }

    init(folder: DataFolder = .app, service: ApelinService = .app) {
        self.folder = folder
        self.service = service
        do {
            let data = try Data(contentsOf: file)
            do {
                records = try JSONCoding.decode(PreservedList<AgentQuotaDisplayRecord>.self, from: data)
            } catch {
                writable = UnreadableFile.setAside(file) != nil
            }
        } catch {
            let missing = (error as NSError).domain == NSCocoaErrorDomain
                && (error as NSError).code == NSFileReadNoSuchFileError
            writable = missing
        }
        for record in records.items {
            bindings[key(record.provider, record.accountID)] = record.poolID
        }
    }

    var balances: [ProviderBalance] { records.items.flatMap(\.balances) }
    var quotas: [AgentQuotaSnapshot] { records.items.map(\.snapshot) }

    func stale() -> Bool {
        guard let lastAttempt else { return true }
        return Date().timeIntervalSince(lastAttempt) >= Self.autoInterval
    }

    private func key(_ provider: AgentProvider, _ accountID: String) -> String {
        provider.rawValue + ":" + accountID
    }

    /// 仅接受完整账号列表作清理依据；网络失败、额度空返回不是账号退出。
    func reconcile(accounts: [AgentAccount]) {
        let signedIn = accounts.filter { $0.signedIn && $0.poolID != nil }
        let next = Dictionary(signedIn.map {
            (key($0.provider, $0.storeID ?? $0.provider.rawValue), $0.poolID!)
        }, uniquingKeysWith: { _, latest in latest })
        if next != bindings {
            generation = UUID()
            bindings = next
            lastAttempt = nil
        }
        let previous = records.items
        records.items.removeAll { record in !signedIn.contains(where: record.matches) }
        if previous != records.items { publish() }
    }

    /// 配置保存成功先使旧请求失效；是否换池由完整账号列表决定，同池重登保留有效数字。
    func configurationChanged() {
        generation = UUID()
        lastAttempt = nil
    }

    /// 退出成功时撤销对应绑定，同时作废所有等待中的旧回包。
    func invalidate(provider: AgentProvider, accountID: String?) {
        let id = accountID ?? provider.rawValue
        generation = UUID()
        bindings.removeValue(forKey: key(provider, id))
        records.items.removeAll { $0.provider == provider && $0.accountID == id }
        lastAttempt = nil
        publish()
    }

    /// 所有入口都走这里；请求前后核对账号绑定，换池、退出期间的结果不得落盘。
    @discardableResult
    func loadQuotas(provider: AgentProvider? = nil, accountID: String? = nil, manual: Bool = false) async throws -> [AgentQuotaSnapshot] {
        let started = generation
        lastAttempt = Date()
        let accounts: [AgentAccount]
        do { accounts = try await service.agentAccountList().accounts }
        catch {
            if generation == started, !(error is CancellationError) { markStale(provider: provider, accountID: accountID) }
            throw error
        }
        guard generation == started else { throw CancellationError() }
        reconcile(accounts: accounts)
        let token = generation
        lastAttempt = Date()
        do {
            let response = try await service.agentProviderQuota(
                provider: provider, mode: manual ? .manualRefresh : .attentionGated,
                foreground: true, force: manual, accountID: accountID
            )
            guard generation == token else { throw CancellationError() }
            let latest = try await service.agentAccountList().accounts
            guard generation == token else { throw CancellationError() }
            reconcile(accounts: latest)
            guard generation == token else { throw CancellationError() }
            let returnedPools = Set(response.quotas.map(\.poolID))
            let targets = latest.filter {
                $0.signedIn && (
                    ((provider == nil || $0.provider == provider)
                        && (accountID == nil || ($0.storeID ?? $0.provider.rawValue) == accountID))
                        || $0.poolID.map(returnedPools.contains) == true
                )
            }
            for account in targets {
                let id = account.storeID ?? account.provider.rawValue
                guard let poolID = account.poolID else { continue }
                let index = records.items.firstIndex { $0.matches(account) }
                if var next = response.quotas.first(where: { $0.provider == account.provider && $0.poolID == poolID })
                    ?? response.quotas.first(where: { $0.poolID == poolID })
                {
                    next.provider = account.provider
                    next.accountLabel = account.account
                    if let index { records.items[index].merge(next) }
                    else {
                        var initial = next
                        // 无数字时不能把 HTTP 成功或账单链接时间当作余额更新时间。
                        if !AgentQuotaDisplayRecord.hasFigures(next) { initial.updatedAt = nil }
                        records.items.append(AgentQuotaDisplayRecord(accountID: id, snapshot: initial))
                    }
                } else if let index {
                    markStale(at: index)
                }
            }
            publish()
            return quotas
        } catch {
            if generation == token, !(error is CancellationError) {
                markStale(provider: provider, accountID: accountID)
                logger.error("额度刷新失败，保留最近有效数据")
            }
            throw error
        }
    }

    private func markStale(provider: AgentProvider?, accountID: String?) {
        for index in records.items.indices where
            (provider == nil || records.items[index].provider == provider)
                && (accountID == nil || records.items[index].accountID == accountID)
        { markStale(at: index) }
        publish()
    }

    private func markStale(at index: Int) {
        records.items[index].snapshot.status = .error
        records.items[index].snapshot.errorSummary = "刷新失败，保留上次数据"
    }

    @discardableResult
    func refresh(force: Bool = false) async -> [ProviderBalance] {
        if let inFlight { return await inFlight.value }
        let task = Task<[ProviderBalance], Never> {
            do { _ = try await self.loadQuotas(manual: force) }
            catch { /* 失败不清数字，成功时间保持不变。 */ }
            return self.balances
        }
        inFlight = task
        let next = await task.value
        inFlight = nil
        return next
    }

    private func publish() {
        if writable {
            do {
                try folder.makeLevels(to: folder.root)
                var saved = records
                // 错误文本和账单链接只用于当前页面，不在客户端二次持久化。
                for index in saved.items.indices {
                    saved.items[index].snapshot.errorSummary = nil
                    saved.items[index].snapshot.billingURL = nil
                }
                try JSONCoding.encoder(pretty: true).encode(saved).write(to: file, options: .atomic)
            } catch {
                logger.error("额度缓存未能保存，内存数据仍保留")
            }
        }
        NotificationCenter.default.post(name: .providerBalancesChanged, object: nil)
    }

    /// 无账号标识的旧会话只取首账号；不同账号或不同池绝不借用。
    func current(for provider: AgentProvider?, accountID: String? = nil) -> ProviderBalance? {
        guard let provider else { return nil }
        let candidates = balances.filter {
            $0.provider == provider && (accountID?.isEmpty == false
                ? $0.accountID == accountID : !$0.accountID.contains(AgentAccountID.separator))
        }
        return candidates.first(where: \.isMonetary) ?? candidates.first
    }
}
