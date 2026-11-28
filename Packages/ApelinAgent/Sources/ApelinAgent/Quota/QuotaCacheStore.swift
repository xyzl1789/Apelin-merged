import Foundation
import Darwin
import ApelinCore
import ApelinProtocol

public enum RelayProbeKind: String, Codable, Sendable, Equatable {
    case sub2api
    case newapi
    case openAIBilling
    case unsupported
}

public struct PersistedRelayProbe: Codable, Sendable, Equatable {
    public var endpointKey: String
    public var kind: RelayProbeKind
    public var probedAt: Date

    public init(endpointKey: String, kind: RelayProbeKind, probedAt: Date) {
        self.endpointKey = endpointKey
        self.kind = kind
        self.probedAt = probedAt
    }
}

public struct PersistedQuotaPool: Codable, Sendable, Equatable {
    public var poolID: String
    public var endpointKey: String?
    public var snapshot: AgentQuotaSnapshot
    public var lastForegroundFetchAt: Date?
    public var lastBackgroundFetchAt: Date?
    public var lastManualRefreshAt: Date?
    public var consecutiveFailures: Int
    public var cooldownUntil: Date?
    public var circuitBrokenUntil: Date?

    public init(poolID: String, endpointKey: String? = nil, snapshot: AgentQuotaSnapshot, lastForegroundFetchAt: Date? = nil, lastBackgroundFetchAt: Date? = nil, lastManualRefreshAt: Date? = nil, consecutiveFailures: Int = 0, cooldownUntil: Date? = nil, circuitBrokenUntil: Date? = nil) {
        self.poolID = poolID
        self.endpointKey = endpointKey
        self.snapshot = snapshot
        self.lastForegroundFetchAt = lastForegroundFetchAt
        self.lastBackgroundFetchAt = lastBackgroundFetchAt
        self.lastManualRefreshAt = lastManualRefreshAt
        self.consecutiveFailures = consecutiveFailures
        self.cooldownUntil = cooldownUntil
        self.circuitBrokenUntil = circuitBrokenUntil
    }
}

/// 脱敏额度池与 24 小时中转探测缓存；不保存密钥、鉴权头或原始响应。
public final class QuotaCacheStore: @unchecked Sendable {
    public static let probeCacheTTL: TimeInterval = 24 * 60 * 60
    private let dataRoot: ApelinDataRoot
    private let lock = NSLock()
    private let redaction: LogRedaction
    private let readData: @Sendable (URL) throws -> Data

    public init(dataRoot: ApelinDataRoot) {
        self.dataRoot = dataRoot
        redaction = LogRedaction(home: dataRoot.home.path, installRoot: nil)
        readData = { try Data(contentsOf: $0) }
    }

    /// 可替换读取端，确定性验证权限或 I/O 失败时绝不覆盖旧缓存。
    init(dataRoot: ApelinDataRoot, readData: @escaping @Sendable (URL) throws -> Data) {
        self.dataRoot = dataRoot
        redaction = LogRedaction(home: dataRoot.home.path, installRoot: nil)
        self.readData = readData
    }

    private var poolsFile: URL { dataRoot.quota.appendingPathComponent("pools.json") }
    private var probesFile: URL { dataRoot.quota.appendingPathComponent("probes.json") }
    private var generationsFile: URL { dataRoot.quota.appendingPathComponent("generations.json") }

    private struct PoolGeneration: Codable {
        var poolID: String
        var token: UUID
    }

    /// 观察器构造时绑定的持久代次；无法安全读取或写入时不启用被动更新。
    public func passiveGeneration(for poolID: String) -> UUID? {
        try? withCacheLock {
            var list: PreservedList<PoolGeneration> = try readPreservedList(at: generationsFile)
            if let entry = list.items.first(where: { $0.poolID == poolID }) { return entry.token }
            let token = UUID()
            list.items.append(PoolGeneration(poolID: poolID, token: token))
            try writePreservedList(list, to: generationsFile)
            return token
        }
    }

    public func isCurrentPassiveGeneration(_ generation: UUID, for poolID: String) -> Bool {
        (try? withCacheLock { try matchesGeneration(generation, poolID: poolID) }) ?? false
    }

    /// 只能在同一个缓存锁内调用；合并与代次检查不可拆成两个操作。
    private func matchesGeneration(_ generation: UUID, poolID: String) throws -> Bool {
        let list: PreservedList<PoolGeneration> = try readPreservedList(at: generationsFile)
        return list.items.first(where: { $0.poolID == poolID })?.token == generation
    }

    // MARK: - 额度池

    public func loadPools() -> [PersistedQuotaPool] {
        (try? withCacheLock {
            let list: PreservedList<PersistedQuotaPool> = try readPreservedList(at: poolsFile)
            return list.items
        }) ?? []
    }

    public func pool(for poolID: String) -> PersistedQuotaPool? {
        loadPools().first { $0.poolID == poolID }
    }

    public func upsertPool(_ entry: PersistedQuotaPool, secretToScrub: String? = nil) {
        let cleaned = sanitizePool(entry, secretToScrub: secretToScrub)
        try? withCacheLock {
            var list: PreservedList<PersistedQuotaPool> = try readPreservedList(at: poolsFile)
            if let index = list.items.firstIndex(where: { $0.poolID == cleaned.poolID }) {
                list.items[index] = cleaned
            } else { list.items.append(cleaned) }
            try writePreservedList(list, to: poolsFile)
        }
    }

    /// 合并被动响应头并清除失败退避和冷却状态；没有缓存时创建额度池。
    @discardableResult
    public func mergePassiveUpdate(poolID: String, provider: AgentProvider, accountLabel: String?, kind: AgentQuotaPoolKind? = nil, windows: [AgentQuotaWindow], balances: [AgentQuotaBalance], planName: String?, isExhausted: Bool, now: Date = Date(), expectedGeneration: UUID? = nil) -> PersistedQuotaPool? {
        try? withCacheLock {
            if let expectedGeneration, try !matchesGeneration(expectedGeneration, poolID: poolID) { return nil }
            var list: PreservedList<PersistedQuotaPool> = try readPreservedList(at: poolsFile)
            let existing = list.items.first { $0.poolID == poolID }
            var mergedWindows = existing?.snapshot.windows ?? []
            for incoming in windows {
                if let index = mergedWindows.firstIndex(where: { $0.id == incoming.id }) {
                    mergedWindows[index] = incoming
                } else { mergedWindows.append(incoming) }
            }
            var mergedBalances = existing?.snapshot.balances ?? []
            for incoming in balances {
                if let index = mergedBalances.firstIndex(where: { $0.id == incoming.id }) {
                    mergedBalances[index] = incoming
                } else { mergedBalances.append(incoming) }
            }
            let effectiveKind = kind ?? existing?.snapshot.kind ?? (!mergedWindows.isEmpty ? .window : .balance)
            let effectiveStatus: AgentQuotaStatus = isExhausted ? .exhausted : (mergedWindows.contains { $0.usedPercent >= 100 && $0.id != "overage" } ? .exhausted : .available)
            let snapshot = AgentQuotaSnapshot(
                poolID: poolID, provider: provider, accountLabel: accountLabel ?? existing?.snapshot.accountLabel,
                kind: effectiveKind, source: .passiveHeaders, status: effectiveStatus,
                balances: mergedBalances, windows: mergedWindows, planName: planName ?? existing?.snapshot.planName,
                relayKind: existing?.snapshot.relayKind, billingURL: QuotaPoolIdentity.billingURL(for: provider),
                updatedAt: now, nextAllowedAt: nil, manualDebounceUntil: existing?.snapshot.manualDebounceUntil,
                cooldownUntil: nil, circuitBrokenUntil: nil, errorSummary: nil,
            )
            let updated = PersistedQuotaPool(
                poolID: poolID, endpointKey: existing?.endpointKey, snapshot: sanitizeSnapshot(snapshot, secretToScrub: nil),
                lastForegroundFetchAt: existing?.lastForegroundFetchAt, lastBackgroundFetchAt: existing?.lastBackgroundFetchAt,
                lastManualRefreshAt: existing?.lastManualRefreshAt, consecutiveFailures: 0, cooldownUntil: nil, circuitBrokenUntil: nil,
            )
            if let index = list.items.firstIndex(where: { $0.poolID == poolID }) {
                list.items[index] = updated
            } else { list.items.append(updated) }
            try writePreservedList(list, to: poolsFile)
            return updated
        }
    }

    public func clearPool(poolID: String) {
        try? withCacheLock {
            var generations: PreservedList<PoolGeneration> = try readPreservedList(at: generationsFile)
            let replacement = PoolGeneration(poolID: poolID, token: UUID())
            if let index = generations.items.firstIndex(where: { $0.poolID == poolID }) {
                generations.items[index] = replacement
            } else { generations.items.append(replacement) }
            // 必须先持久作废；失败时不删除池，避免清理后仍被旧观察器写回。
            try writePreservedList(generations, to: generationsFile)
            var list: PreservedList<PersistedQuotaPool> = try readPreservedList(at: poolsFile)
            list.items.removeAll { $0.poolID == poolID }
            try writePreservedList(list, to: poolsFile)
        }
    }

    // MARK: - 中转探测缓存（24 小时）

    public func cachedRelayProbe(for endpointKey: String, now: Date = Date()) -> RelayProbeKind? {
        try? withCacheLock {
            let list: PreservedList<PersistedRelayProbe> = try readPreservedList(at: probesFile)
            guard let entry = list.items.first(where: { $0.endpointKey == endpointKey }) else { return nil }
            let age = now.timeIntervalSince(entry.probedAt)
            guard age >= 0, age < Self.probeCacheTTL else { return nil }
            return entry.kind
        }
    }

    public func storeRelayProbe(endpointKey: String, kind: RelayProbeKind, now: Date = Date()) {
        try? withCacheLock {
            var list: PreservedList<PersistedRelayProbe> = try readPreservedList(at: probesFile)
            let record = PersistedRelayProbe(endpointKey: endpointKey, kind: kind, probedAt: now)
            if let index = list.items.firstIndex(where: { $0.endpointKey == endpointKey }) {
                list.items[index] = record
            } else { list.items.append(record) }
            try writePreservedList(list, to: probesFile)
        }
    }

    // MARK: - 脱敏

    private func sanitizePool(_ pool: PersistedQuotaPool, secretToScrub: String?) -> PersistedQuotaPool {
        var copy = pool
        copy.snapshot = sanitizeSnapshot(pool.snapshot, secretToScrub: secretToScrub)
        return copy
    }

    public func sanitizeSnapshot(_ snapshot: AgentQuotaSnapshot, secretToScrub: String?) -> AgentQuotaSnapshot {
        var copy = snapshot
        copy.accountLabel = snapshot.accountLabel.map { scrub($0, secret: secretToScrub, limit: 160) }
        copy.planName = snapshot.planName.map { scrub($0, secret: secretToScrub, limit: 120) }
        copy.errorSummary = snapshot.errorSummary.map { scrub($0, secret: secretToScrub, limit: 240) }
        copy.relayKind = snapshot.relayKind.map { scrub($0, secret: secretToScrub, limit: 120) }
        copy.windows = snapshot.windows.map { window in
            var cleaned = window
            cleaned.id = scrub(window.id, secret: secretToScrub, limit: 160)
            cleaned.label = scrub(window.label, secret: secretToScrub, limit: 160)
            cleaned.status = window.status.map { scrub($0, secret: secretToScrub, limit: 120) }
            return cleaned
        }
        copy.balances = snapshot.balances.map { balance in
            var cleaned = balance
            cleaned.id = scrub(balance.id, secret: secretToScrub, limit: 160)
            cleaned.currency = balance.currency.map { scrub($0, secret: secretToScrub, limit: 32) }
            cleaned.unitLabel = balance.unitLabel.map { scrub($0, secret: secretToScrub, limit: 120) }
            return cleaned
        }
        return copy
    }

    private func scrub(_ text: String, secret: String?, limit: Int) -> String {
        var value = text
        if let secret = secret?.trimmingCharacters(in: .whitespacesAndNewlines), secret.count >= 4 {
            value = value.replacingOccurrences(of: secret, with: LogRedaction.redacted)
        }
        return redaction.text(value, limit: limit)
    }

    // MARK: - 跨实例和跨工作进程的串行访问

    private func withCacheLock<Result>(_ body: () throws -> Result) throws -> Result {
        try lock.withLock {
            try DataFolder(root: dataRoot.url).makeLevels(to: dataRoot.quota)
            let lockURL = dataRoot.quota.appendingPathComponent(".cache.lock")
            let fd = open(lockURL.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
            guard fd >= 0 else { throw cachePOSIXError() }
            defer { close(fd) }
            var metadata = stat()
            guard fstat(fd, &metadata) == 0, (metadata.st_mode & S_IFMT) == S_IFREG else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            // 独立打开的描述符在同一进程中也互斥，NSLock 则保护同一个实例。
            while flock(fd, LOCK_EX) != 0 {
                guard errno == EINTR else { throw cachePOSIXError() }
            }
            defer { _ = flock(fd, LOCK_UN) }
            return try body()
        }
    }

    private func cachePOSIXError() -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }

    // MARK: - 保留不可解码元素的安全读写

    private func readPreservedList<Element: Codable>(at url: URL) throws -> PreservedList<Element> {
        let data: Data
        do {
            data = try readData(url)
        } catch let error as NSError {
            // 只有文件确实不存在才返回空；权限或 I/O 失败不能伪装成空缓存。
            if (error.domain == NSCocoaErrorDomain && (error.code == NSFileReadNoSuchFileError || error.code == NSFileNoSuchFileError)) ||
                (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT)) {
                return PreservedList<Element>()
            }
            throw error
        }
        do { return try JSONCoding.decode(PreservedList<Element>.self, from: data) } catch {
            // 解码损坏时保留原文件；隔离失败仍禁止后续覆盖（问题 #33）。
            guard UnreadableFile.setAside(url) != nil else { throw error }
            return PreservedList<Element>()
        }
    }

    private func writePreservedList<Element: Codable>(_ list: PreservedList<Element>, to url: URL) throws {
        let data = try JSONCoding.encode(list)
        try data.write(to: url, options: .atomic)
    }
}
