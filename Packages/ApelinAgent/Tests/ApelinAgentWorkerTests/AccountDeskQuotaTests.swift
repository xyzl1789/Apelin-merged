import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite("账号额度查询集成", .serialized)
struct AccountDeskQuotaTests {
    private final class MockTransport: QuotaHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var callCount: Int { lock.withLock { calls } }

        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            lock.withLock { calls += 1 }
            let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"99.00"}]}"#
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!
            return (response, Data(body.utf8))
        }
    }

    @Test func `账号共享密钥时额度去重且退出最后账号清理缓存`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-account-quota-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = ApelinDataRoot(home: home)
        let sharedKey = "sk-shared-deepseek-key-123456"
        let store = DeliveredCredentialSource([
            CredentialProviderID.deepSeek: OAuthCredentials(access: sharedKey, refresh: "", expires: .max),
            CredentialProviderID.openAICompatible: OAuthCredentials(access: sharedKey, refresh: "", expires: .max, extras: ["baseUrl": .string("https://api.deepseek.com")]),
        ])
        let transport = MockTransport()
        let desk = AccountDesk(store: store, quotaTransport: transport)
        let listed = await desk.list()
        let deepSeekAccount = try #require(listed.accounts.first { $0.provider == .deepSeek })
        let compatAccount = try #require(listed.accounts.first { $0.provider == .openAICompatible })
        #expect(deepSeekAccount.poolID != nil)
        #expect(deepSeekAccount.poolID == compatAccount.poolID)
        let response = try await desk.quotas(AgentProviderQuotaRequest(mode: .attentionGated), dataRoot: root)
        #expect(response.quotas.count == 2)
        #expect(Set(response.quotas.map(\.provider)) == [.deepSeek, .openAICompatible])
        // SingleFlight 与共享摘要额度池避免并发重复查询。
        #expect(transport.callCount == 1)
        // 退出其中一个账号时，另一个仍使用该密钥，缓存必须保留。
        try await desk.signOut(.openAICompatible, dataRoot: root)
        let afterFirst = try await desk.quotas(AgentProviderQuotaRequest(mode: .cachedOnly), dataRoot: root)
        #expect(afterFirst.quotas.count == 1)
        #expect(afterFirst.quotas.first?.balances.first?.remaining == Decimal(string: "99.00"))
        // 退出最后一个共享账号时删除该池缓存。
        try await desk.signOut(.deepSeek, dataRoot: root)
        #expect(QuotaCacheStore(dataRoot: root).loadPools().isEmpty)
    }
}
