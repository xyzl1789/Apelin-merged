import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite("签到后的统一额度刷新", .serialized)
struct CheckInQuotaRefreshTests {
    private actor Store: CredentialSource {
        var entries: [String: OAuthCredentials]
        init(_ entries: [String: OAuthCredentials]) { self.entries = entries }
        func providerIds() -> [String] { entries.keys.sorted() }
        func credentials(for id: String) -> OAuthCredentials? { entries[id] }
        func store(_ credentials: OAuthCredentials, for id: String) { entries[id] = credentials }
        func remove(_ id: String) { entries.removeValue(forKey: id) }
    }
    private final class Transport: QuotaHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            lock.withLock { calls += 1 }
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Cloud-IDE-JWT test-first-account")
            #expect(request.url?.host == "api.trae.cn")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!,
                Data(#"{"code":0,"user_entitlement_pack_list":[{"entitlement_base_info":{"quota":{"credits_limit":"100.5"}},"usage":{"credits_amount":"1.25"}}]}"#.utf8))
        }
    }
    private struct DailyCache: Encodable { var day: String; var results: [CheckInResult] }

    @Test func `当天签到缓存命中也使首账号池失效刷新而不碰附加账号`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = ApelinDataRoot(home: home)
        let folder = root.url.appendingPathComponent("checkin")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        // 只用合成当天结果，不调用领取接口或访问真实凭据。
        let daily = DailyCache(day: formatter.string(from: Date()), results: [CheckInResult(platform: .traeCN, outcome: .alreadyClaimed, available: "12")])
        try JSONEncoder().encode(daily).write(to: folder.appendingPathComponent("cache.json"))
        let cache = QuotaCacheStore(dataRoot: root)
        let now = Date()
        for (id, amount) in [("trae", Decimal(12)), ("trae#2", Decimal(77))] {
            let snapshot = AgentQuotaSnapshot(poolID: "oauth:\(id)", provider: .trae, kind: .balance, source: .activeAPI, status: .available,
                balances: [AgentQuotaBalance(id: "credits", unitLabel: "积分", remaining: amount)], updatedAt: now)
            cache.upsertPool(PersistedQuotaPool(poolID: snapshot.poolID, snapshot: snapshot, lastForegroundFetchAt: now, lastManualRefreshAt: now))
        }
        let store = Store([
            "trae": OAuthCredentials(access: "test-first-account", refresh: "", expires: .max),
            "trae#2": OAuthCredentials(access: "test-second-account", refresh: "", expires: .max),
        ])
        let transport = Transport()
        let desk = AccountDesk(store: store, quotaTransport: transport)
        let response = try await desk.checkIn(platforms: [.traeCN], force: false, home: home)
        #expect(transport.count == 1)
        #expect(response.results.first?.available == "99.25")
        #expect(response.results.first?.used == "1.25")
        #expect(cache.pool(for: "oauth:trae")?.snapshot.balances.first?.remaining == Decimal(string: "99.25"))
        #expect(cache.pool(for: "oauth:trae#2")?.snapshot.balances.first?.remaining == 77)
        #expect(cache.pool(for: "oauth:trae#2")?.lastManualRefreshAt == now)
        let compatibility = try await desk.providerBalances(force: false, home: home)
        #expect(compatibility.balances.first(where: { $0.accountID == "trae" })?.amount == "99.25")
        #expect(transport.count == 1, "旧余额入口与签到共用缓存，不能再查一份余额")
    }
}
