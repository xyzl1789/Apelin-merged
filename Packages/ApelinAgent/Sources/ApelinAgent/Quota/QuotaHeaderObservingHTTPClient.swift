import Foundation
import KWWKAI

/// 不阻塞响应流：提取 Anthropic/Codex OAuth 响应头（包括 429），
/// 合并到共享额度缓存，并清除失败退避与冷却状态。
public final class QuotaHeaderObservingHTTPClient: HTTPClient, @unchecked Sendable {
    public let inner: any HTTPClient
    public let storeID: String
    public let store: QuotaCacheStore
    private let poolID: String
    private let generation: UUID?

    public init(inner: any HTTPClient = URLSessionHTTPClient.shared, storeID: String, store: QuotaCacheStore) {
        self.inner = inner
        self.storeID = storeID
        self.store = store
        let poolID = "oauth:\(storeID)"
        self.poolID = poolID
        generation = store.passiveGeneration(for: poolID)
    }

    /// 旧观察器不会在下一次请求中重新绑定退出后的新代次。
    private func currentGeneration() -> UUID? {
        guard let generation, store.isCurrentPassiveGeneration(generation, for: poolID) else { return nil }
        return generation
    }

    public func stream(url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let generation = currentGeneration()
        let result = try await inner.stream(url: url, method: method, headers: headers, body: body, cancellation: cancellation)
        if let generation { observeNonBlocking(response: result.0, generation: generation) }
        return result
    }

    public func stream(url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?, timeoutSeconds: TimeInterval) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
        let generation = currentGeneration()
        let result = try await inner.stream(url: url, method: method, headers: headers, body: body, cancellation: cancellation, timeoutSeconds: timeoutSeconds)
        if let generation { observeNonBlocking(response: result.0, generation: generation) }
        return result
    }

    private func observeNonBlocking(response: HTTPURLResponse, generation: UUID) {
        let extracted = PassiveQuotaHeaderParser.lowercasedHeaders(from: response)
        guard !extracted.isEmpty else { return }
        let statusCode = response.statusCode
        let baseStoreID = AccountIDs.base(of: storeID)
        let poolID = poolID
        let store = store
        Task.detached(priority: .utility) {
            let now = Date()
            guard let observation = PassiveQuotaHeaderParser.parse(storeID: baseStoreID, statusCode: statusCode, headers: extracted, now: now) else { return }
            // 最终检查和合并持有同一把跨进程缓存锁，避免退出清理与写回竞态。
            store.mergePassiveUpdate(
                poolID: poolID, provider: observation.provider, accountLabel: nil,
                windows: observation.windows, balances: observation.balances, planName: observation.planName,
                isExhausted: observation.isExhausted, now: now, expectedGeneration: generation,
            )
        }
    }
}
