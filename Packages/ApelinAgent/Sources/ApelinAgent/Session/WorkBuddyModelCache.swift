import ApelinProtocol
import Foundation
import KWWKAI

/// 账号列表与真实会话共用在线模型记录；只缓存模型，不持久化凭据。
public final class WorkBuddyModelCache: @unchecked Sendable {
    public static let shared = WorkBuddyModelCache()
    private struct Entry {
        var models: [Model]
        var at: Date
    }
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: (id: UUID, task: Task<[Model]?, Never>)] = [:]
    private let clock: @Sendable () -> Date
    private let lifetime: TimeInterval = 10 * 60

    public init(clock: @escaping @Sendable () -> Date = Date.init) { self.clock = clock }

    private func key(site: WorkBuddySite, credentials: OAuthCredentials, storeID: String?) -> String {
        // 同一服务商的不同账号和企业域不能借用彼此的推理能力。
        let headers = WorkBuddyOAuth.accountHeaders(credentials, site: site)
        let identity = ([credentials.access] + headers.keys.sorted().map { $0 + "=" + (headers[$0] ?? "") }).joined(separator: "\n")
        return site.id + ":" + (storeID ?? site.id) + ":" + QuotaPoolIdentity.keyDigestPrefix16(for: identity)
    }

    public func models(site: WorkBuddySite, credentials: OAuthCredentials, storeID: String? = nil) -> [Model]? {
        let key = key(site: site, credentials: credentials, storeID: storeID)
        return lock.withLock {
            guard let entry = entries[key], clock().timeIntervalSince(entry.at) < lifetime else { return nil }
            return entry.models
        }
    }

    /// 同账号的并发解析只读一次配置。失败保留目录回退，不缓存一次空响应。
    public func load(site: WorkBuddySite, credentials: OAuthCredentials, storeID: String? = nil, client: any HTTPClient = URLSessionHTTPClient.shared, force: Bool = false) async -> [Model]? {
        if !force, let cached = models(site: site, credentials: credentials, storeID: storeID) { return cached }
        let key = key(site: site, credentials: credentials, storeID: storeID)
        let running = lock.withLock { () -> (id: UUID, task: Task<[Model]?, Never>) in
            if let running = inFlight[key] { return running }
            let task = Task<[Model]?, Never> {
                guard let listings = try? await WorkBuddyModels.fetch(site: site, credentials: credentials, client: client), !listings.isEmpty else { return nil }
                var seen: Set<String> = []
                return listings.map(\.model).filter { seen.insert($0.id).inserted }
            }
            let running = (id: UUID(), task: task)
            inFlight[key] = running
            return running
        }
        let result = await running.task.value
        lock.withLock {
            guard inFlight[key]?.id == running.id else { return }
            if let result { entries[key] = Entry(models: result, at: clock()) }
            inFlight[key] = nil
        }
        return result
    }

    /// 目录的通用匹配不能覆盖在线配置明确禁用的档位；显式用户开关仍优先。
    public static func applyingReasoning(from live: Model, to model: Model, parameters: AgentModelParameters?) -> Model {
        var result = model
        result.reasoning = parameters?.reasoning ?? live.reasoning
        result.thinkingLevelMap = live.thinkingLevelMap
        result.compat = live.compat
        return result
    }
}
