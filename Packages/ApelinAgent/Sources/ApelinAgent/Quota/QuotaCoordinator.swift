import Foundation
import KWWKAI
import ApelinProtocol

public struct QuotaAccountDescriptor: Sendable {
    public var provider: AgentProvider
    public var storeID: String
    public var accountLabel: String?
    public var credentials: OAuthCredentials
    public var usesAPIKey: Bool

    public init(provider: AgentProvider, storeID: String, accountLabel: String?, credentials: OAuthCredentials, usesAPIKey: Bool) {
        self.provider = provider
        self.storeID = storeID
        self.accountLabel = accountLabel
        self.credentials = credentials
        self.usesAPIKey = usesAPIKey
    }
}

/// 按额度池 SingleFlight 去重；前后台统一 30 秒刷新门禁、30 秒手动防抖，
/// 失败指数退避与永久端点失败的 24 小时熔断。
public actor QuotaCoordinator {
    public static let foregroundOrdinaryInterval: TimeInterval = 30
    public static let foregroundSubscriptionInterval: TimeInterval = 30
    public static let backgroundInterval: TimeInterval = 30
    public static let manualDebounceInterval: TimeInterval = 30
    public static let circuitBreakerDuration: TimeInterval = 24 * 60 * 60
    public static let baseBackoffSeconds: TimeInterval = 60
    public static let maxBackoffSeconds: TimeInterval = 30 * 60

    private let store: QuotaCacheStore
    private let transport: any QuotaHTTPTransport
    private let kwwkUsage: any KWWKQuotaUsageProvider
    private let clock: @Sendable () -> Date
    private var inFlight: [String: Task<AgentQuotaSnapshot, Never>] = [:]
    private var generations: [String: QuotaQueryGeneration] = [:]

    /// 作废在途查询并清除该池；旧请求即使忽略取消，也不能写回缓存。
    public func forget(poolID: String) {
        generations.removeValue(forKey: poolID)?.invalidate()
        inFlight.removeValue(forKey: poolID)?.cancel()
        store.clearPool(poolID: poolID)
    }

    /// 领取奖励后只作废查询时效，保留最近数字；旧在途请求不能覆盖新余额。
    public func invalidate(poolID: String) {
        generations.removeValue(forKey: poolID)?.invalidate()
        inFlight.removeValue(forKey: poolID)?.cancel()
        store.invalidatePool(poolID: poolID)
    }

    public init(store: QuotaCacheStore, transport: any QuotaHTTPTransport = URLSessionQuotaTransport.shared, kwwkUsage: any KWWKQuotaUsageProvider = DefaultKWWKQuotaUsageProvider(), clock: @escaping @Sendable () -> Date = Date.init) {
        self.store = store
        self.transport = transport
        self.kwwkUsage = kwwkUsage
        self.clock = clock
    }

    public func snapshots(for accounts: [QuotaAccountDescriptor], mode: AgentQuotaFetchMode, foreground: Bool, force: Bool) async -> [AgentQuotaSnapshot] {
        await withTaskGroup(of: (Int, AgentQuotaSnapshot).self) { group in
            for (index, account) in accounts.enumerated() {
                group.addTask {
                    let snapshot = await self.snapshot(for: account, mode: mode, foreground: foreground, force: force)
                    return (index, snapshot)
                }
            }
            var ordered = Array<AgentQuotaSnapshot?>(repeating: nil, count: accounts.count)
            for await (index, snapshot) in group { ordered[index] = snapshot }
            return ordered.compactMap { $0 }
        }
    }

    public func snapshot(for account: QuotaAccountDescriptor, mode: AgentQuotaFetchMode, foreground: Bool, force: Bool) async -> AgentQuotaSnapshot {
        let now = clock()
        let poolID = QuotaPoolIdentity.poolID(provider: account.provider, storeID: account.storeID, credentials: account.credentials, usesAPIKey: account.usesAPIKey)
        let baseURL = QuotaAdapters.resolvedBaseURL(for: account.provider, credentials: account.credentials)
        let endpointKey = baseURL.flatMap(QuotaPoolIdentity.normalizedEndpointKey(baseURL:))
        let cached = store.pool(for: poolID)
        // 升级前的 WorkBuddy 窗口和 Trae 账单链接不得继续命中成功缓存或熔断。
        let needsCreditMigration = [AgentProvider.workBuddy, .workBuddyAI, .trae].contains(account.provider)
            && cached.map { $0.snapshot.kind != .balance } == true
        let existing = needsCreditMigration ? nil : cached
        let endpointChanged = existing?.endpointKey != nil && endpointKey != nil && existing?.endpointKey != endpointKey

        // 只读缓存模式绝不发起网络请求。
        if mode == .cachedOnly {
            return projectedSnapshot(existing: existing, account: account, poolID: poolID, baseURL: baseURL, now: now)
        }
        // 没有公开接口的提供商仅返回账单入口。
        if !supportsNetworkQuery(account: account, baseURL: baseURL) {
            let billing = QuotaAdapters.billingOnlySnapshot(poolID: poolID, provider: account.provider, accountLabel: account.accountLabel, baseURL: baseURL, now: now)
            store.upsertPool(PersistedQuotaPool(poolID: poolID, endpointKey: endpointKey, snapshot: billing), secretToScrub: account.credentials.access)
            return billing
        }
        // 端点未改变时才复用旧门禁。
        if !endpointChanged, let existing {
            if mode == .manualRefresh {
                if let lastManual = existing.lastManualRefreshAt {
                    let debounceUntil = lastManual.addingTimeInterval(Self.manualDebounceInterval)
                    if now < debounceUntil {
                        return projectedSnapshot(existing: existing, account: account, poolID: poolID, baseURL: baseURL, manualDebounceOverride: debounceUntil, now: now)
                    }
                }
                if !force, let brokenUntil = existing.circuitBrokenUntil, now < brokenUntil {
                    return projectedSnapshot(existing: existing, account: account, poolID: poolID, baseURL: baseURL, nextAllowedOverride: brokenUntil, now: now)
                }
            } else {
                if let brokenUntil = existing.circuitBrokenUntil, now < brokenUntil {
                    return projectedSnapshot(existing: existing, account: account, poolID: poolID, baseURL: baseURL, nextAllowedOverride: brokenUntil, now: now)
                }
                if let cooldownUntil = existing.cooldownUntil, now < cooldownUntil {
                    return projectedSnapshot(existing: existing, account: account, poolID: poolID, baseURL: baseURL, nextAllowedOverride: cooldownUntil, now: now)
                }
                let isSubscription = QuotaPoolIdentity.isOAuthSubscription(account.provider) && !account.usesAPIKey
                let stalenessInterval: TimeInterval = if !foreground {
                    Self.backgroundInterval
                } else if isSubscription {
                    Self.foregroundSubscriptionInterval
                } else { Self.foregroundOrdinaryInterval }
                let lastFetch = foreground
                    ? (existing.lastForegroundFetchAt ?? existing.snapshot.updatedAt)
                    : (existing.lastBackgroundFetchAt ?? existing.lastForegroundFetchAt ?? existing.snapshot.updatedAt)
                if let lastFetch, now.timeIntervalSince(lastFetch) < stalenessInterval {
                    // 刷新间隔门禁不占用 nextAllowedAt，该字段仅表示冷却和熔断。
                    return projectedSnapshot(existing: existing, account: account, poolID: poolID, baseURL: baseURL, now: now)
                }
            }
        }
        // 同一个额度池只发起一次请求，结果映射回各调用方的提供商和账号。
        if let running = inFlight[poolID] {
            var shared = await running.value
            shared.provider = account.provider
            shared.accountLabel = account.accountLabel ?? shared.accountLabel
            return shared
        }
        let generation = QuotaQueryGeneration()
        generations[poolID] = generation
        let task = Task<AgentQuotaSnapshot, Never> { [store, transport, kwwkUsage, clock] in
            await Self.executeQuery(account: account, poolID: poolID, baseURL: baseURL, endpointKey: endpointKey,
                existing: endpointChanged ? nil : existing, mode: mode, foreground: foreground, force: force,
                store: store, transport: transport, kwwkUsage: kwwkUsage, generation: generation, now: clock())
        }
        inFlight[poolID] = task
        let result = await task.value
        if generations[poolID] === generation {
            inFlight[poolID] = nil
            generations[poolID] = nil
        }
        return result
    }

    private func supportsNetworkQuery(account: QuotaAccountDescriptor, baseURL: String?) -> Bool {
        let host = baseURL.flatMap { URLComponents(string: $0)?.host?.lowercased() }
        if !account.usesAPIKey {
            switch account.provider {
            case .anthropicOAuth, .openAICodex, .kimiCoding, .kimiCodingGlobal, .openRouter,
                 .githubCopilot, .cursor, .kiro, .qoder, .qoderCN, .workBuddy, .workBuddyAI, .trae, .xai:
                return true
            default: return false
            }
        }
        if account.provider == .deepSeek || account.provider == .openRouter { return true }
        if let host, ["api.deepseek.com", "api.moonshot.cn", "api.moonshot.ai", "api.siliconflow.cn", "api.siliconflow.com", "openrouter.ai"].contains(host) { return true }
        switch account.provider.kind {
        case .openAICompatible: return baseURL.flatMap(QuotaPoolIdentity.normalizedRelayRootURL(from:)) != nil
        case .openAI: return host != nil && host != "api.openai.com" && baseURL.flatMap(QuotaPoolIdentity.normalizedRelayRootURL(from:)) != nil
        case .anthropic: return host != nil && host != "api.anthropic.com" && baseURL.flatMap(QuotaPoolIdentity.normalizedRelayRootURL(from:)) != nil
        default: return false
        }
    }

    private func projectedSnapshot(existing: PersistedQuotaPool?, account: QuotaAccountDescriptor, poolID: String, baseURL: String?, nextAllowedOverride: Date? = nil, manualDebounceOverride: Date? = nil, now: Date) -> AgentQuotaSnapshot {
        guard var snap = existing?.snapshot else {
            return QuotaAdapters.billingOnlySnapshot(poolID: poolID, provider: account.provider, accountLabel: account.accountLabel, baseURL: baseURL, now: now)
        }
        snap.provider = account.provider
        snap.accountLabel = account.accountLabel ?? snap.accountLabel
        snap.nextAllowedAt = nextAllowedOverride
        let activeManualDebounce = existing?.lastManualRefreshAt.flatMap { last -> Date? in
            let until = last.addingTimeInterval(Self.manualDebounceInterval)
            return now < until ? until : nil
        }
        snap.manualDebounceUntil = manualDebounceOverride ?? activeManualDebounce
        if let brokenUntil = existing?.circuitBrokenUntil, now < brokenUntil {
            snap.status = .circuitBroken
            snap.circuitBrokenUntil = brokenUntil
            snap.nextAllowedAt = snap.nextAllowedAt ?? brokenUntil
        } else if let cooldownUntil = existing?.cooldownUntil, now < cooldownUntil {
            snap.status = .cooldown
            snap.cooldownUntil = cooldownUntil
            snap.nextAllowedAt = snap.nextAllowedAt ?? cooldownUntil
        }
        return snap
    }

    private static func executeQuery(account: QuotaAccountDescriptor, poolID: String, baseURL: String?, endpointKey: String?, existing: PersistedQuotaPool?, mode: AgentQuotaFetchMode, foreground: Bool, force: Bool, store: QuotaCacheStore, transport: any QuotaHTTPTransport, kwwkUsage: any KWWKQuotaUsageProvider, generation: QuotaQueryGeneration, now: Date) async -> AgentQuotaSnapshot {
        let cachedProbe: RelayProbeKind? = (!force ? endpointKey.flatMap { store.cachedRelayProbe(for: $0, now: now) } : nil)
        do {
            let result = try await QuotaAdapters.query(provider: account.provider, poolID: poolID, accountLabel: account.accountLabel,
                credentials: account.credentials, usesAPIKey: account.usesAPIKey, cachedRelayProbe: cachedProbe,
                transport: transport, kwwkUsage: kwwkUsage, now: now)
            if let key = result.endpointKey, let probeKind = result.relayProbeKind {
                generation.performIfCurrent {
                    store.storeRelayProbe(endpointKey: key, kind: probeKind, now: now)
                }
            }
            var snap = result.snapshot
            snap.nextAllowedAt = nil
            let activeManualDebounce = existing?.lastManualRefreshAt.flatMap { last -> Date? in
                let until = last.addingTimeInterval(Self.manualDebounceInterval)
                return now < until ? until : nil
            }
            snap.manualDebounceUntil = mode == .manualRefresh ? now.addingTimeInterval(Self.manualDebounceInterval) : activeManualDebounce
            let pool = PersistedQuotaPool(poolID: poolID, endpointKey: result.endpointKey ?? endpointKey, snapshot: snap,
                lastForegroundFetchAt: foreground ? now : existing?.lastForegroundFetchAt,
                lastBackgroundFetchAt: foreground ? existing?.lastBackgroundFetchAt : now,
                lastManualRefreshAt: mode == .manualRefresh ? now : existing?.lastManualRefreshAt,
                consecutiveFailures: 0, cooldownUntil: nil, circuitBrokenUntil: nil)
            generation.performIfCurrent {
                store.upsertPool(pool, secretToScrub: account.credentials.access)
            }
            return store.pool(for: poolID)?.snapshot ?? snap
        } catch let error as QuotaAdapterError {
            if case .relayProbeExhausted = error, let endpointKey {
                generation.performIfCurrent {
                    store.storeRelayProbe(endpointKey: endpointKey, kind: .unsupported, now: now)
                }
            }
            let failures = (existing?.consecutiveFailures ?? 0) + 1
            let isPermanent = error.isPermanentEndpointFailure
            let circuitBrokenUntil: Date? = isPermanent ? now.addingTimeInterval(Self.circuitBreakerDuration) : nil
            let cooldownUntil: Date?
            if isPermanent { cooldownUntil = nil } else if case let .rateLimited(retryAfter) = error, let retryAfter, retryAfter > 0 {
                cooldownUntil = now.addingTimeInterval(TimeInterval(retryAfter))
            } else {
                let exponent = min(5, max(0, failures - 1))
                let delay = min(Self.maxBackoffSeconds, Self.baseBackoffSeconds * pow(2.0, Double(exponent)))
                cooldownUntil = now.addingTimeInterval(delay)
            }
            let status: AgentQuotaStatus = isPermanent ? .circuitBroken : .cooldown
            let fallbackKind: AgentQuotaPoolKind = [AgentProvider.workBuddy, .workBuddyAI, .trae].contains(account.provider)
                ? .balance : (QuotaPoolIdentity.isOAuthSubscription(account.provider) && !account.usesAPIKey ? .window : .balance)
            let activeManualDebounce = existing?.lastManualRefreshAt.flatMap { last -> Date? in
                let until = last.addingTimeInterval(Self.manualDebounceInterval)
                return now < until ? until : nil
            }
            let manualDebounceUntil = mode == .manualRefresh ? now.addingTimeInterval(Self.manualDebounceInterval) : activeManualDebounce
            let snap = AgentQuotaSnapshot(poolID: poolID, provider: account.provider, accountLabel: account.accountLabel,
                kind: existing?.snapshot.kind ?? fallbackKind, source: existing?.snapshot.source ?? .activeAPI, status: status,
                balances: existing?.snapshot.balances ?? [], creditPackages: existing?.snapshot.creditPackages, windows: existing?.snapshot.windows ?? [],
                planName: existing?.snapshot.planName, relayKind: existing?.snapshot.relayKind,
                billingURL: existing?.snapshot.billingURL ?? QuotaPoolIdentity.billingURL(for: account.provider, baseURL: baseURL),
                updatedAt: existing?.snapshot.updatedAt ?? now, nextAllowedAt: circuitBrokenUntil ?? cooldownUntil,
                manualDebounceUntil: manualDebounceUntil, cooldownUntil: cooldownUntil, circuitBrokenUntil: circuitBrokenUntil,
                errorSummary: errorSummary(for: error))
            let pool = PersistedQuotaPool(poolID: poolID, endpointKey: endpointKey, snapshot: snap,
                lastForegroundFetchAt: existing?.lastForegroundFetchAt, lastBackgroundFetchAt: existing?.lastBackgroundFetchAt,
                lastManualRefreshAt: mode == .manualRefresh ? now : existing?.lastManualRefreshAt,
                consecutiveFailures: failures, cooldownUntil: cooldownUntil, circuitBrokenUntil: circuitBrokenUntil)
            generation.performIfCurrent {
                store.upsertPool(pool, secretToScrub: account.credentials.access)
            }
            return store.pool(for: poolID)?.snapshot ?? snap
        } catch {
            let failures = (existing?.consecutiveFailures ?? 0) + 1
            let exponent = min(5, max(0, failures - 1))
            let delay = min(Self.maxBackoffSeconds, Self.baseBackoffSeconds * pow(2.0, Double(exponent)))
            let cooldownUntil = now.addingTimeInterval(delay)
            let fallbackKind: AgentQuotaPoolKind = [AgentProvider.workBuddy, .workBuddyAI, .trae].contains(account.provider)
                ? .balance : (QuotaPoolIdentity.isOAuthSubscription(account.provider) && !account.usesAPIKey ? .window : .balance)
            let activeManualDebounce = existing?.lastManualRefreshAt.flatMap { last -> Date? in
                let until = last.addingTimeInterval(Self.manualDebounceInterval)
                return now < until ? until : nil
            }
            let manualDebounceUntil = mode == .manualRefresh ? now.addingTimeInterval(Self.manualDebounceInterval) : activeManualDebounce
            let snap = AgentQuotaSnapshot(poolID: poolID, provider: account.provider, accountLabel: account.accountLabel,
                kind: existing?.snapshot.kind ?? fallbackKind, source: existing?.snapshot.source ?? .activeAPI, status: .error,
                balances: existing?.snapshot.balances ?? [], creditPackages: existing?.snapshot.creditPackages, windows: existing?.snapshot.windows ?? [],
                planName: existing?.snapshot.planName, relayKind: existing?.snapshot.relayKind,
                billingURL: existing?.snapshot.billingURL ?? QuotaPoolIdentity.billingURL(for: account.provider, baseURL: baseURL),
                updatedAt: existing?.snapshot.updatedAt ?? now, nextAllowedAt: cooldownUntil,
                manualDebounceUntil: manualDebounceUntil, cooldownUntil: cooldownUntil, errorSummary: "查询额度时发生网络错误。")
            let pool = PersistedQuotaPool(poolID: poolID, endpointKey: endpointKey, snapshot: snap,
                lastForegroundFetchAt: existing?.lastForegroundFetchAt, lastBackgroundFetchAt: existing?.lastBackgroundFetchAt,
                lastManualRefreshAt: mode == .manualRefresh ? now : existing?.lastManualRefreshAt,
                consecutiveFailures: failures, cooldownUntil: cooldownUntil, circuitBrokenUntil: nil)
            generation.performIfCurrent {
                store.upsertPool(pool, secretToScrub: account.credentials.access)
            }
            return store.pool(for: poolID)?.snapshot ?? snap
        }
    }

    private static func errorSummary(for error: QuotaAdapterError) -> String {
        switch error {
        case .invalidResponse: "提供商返回了无效 HTTP 响应。"
        case .unauthorized: "身份验证被拒绝（401/403）。"
        case let .rateLimited(seconds): seconds.map { "请求受限，请在 \($0) 秒后重试。" } ?? "请求受限（429）。"
        case let .endpointUnsupported(status): "端点不支持此查询（HTTP \(status)），已暂停 24 小时。"
        case let .httpStatus(_, summary): summary
        case .undecodable: "无法解析响应格式。"
        case .missingAccountIdentifier: "缺少 ChatGPT 账号标识。"
        case .relayProbeExhausted: "未检测到支持的账单或用量端点，已暂停 24 小时。"
        }
    }
}

/// 使失效动作与缓存写入互斥，封住“检查后失效、失效后写入”的竞态。
private final class QuotaQueryGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current = true

    func invalidate() {
        lock.withLock { current = false }
    }

    func performIfCurrent(_ action: () -> Void) {
        lock.withLock {
            guard current else { return }
            action()
        }
    }
}
