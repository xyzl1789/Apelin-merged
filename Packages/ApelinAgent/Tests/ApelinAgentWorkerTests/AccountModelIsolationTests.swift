@testable import ApelinAgentWorker
import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite("账号模型偏好隔离", .serialized)
struct AccountModelIsolationTests {
    @Test func `首账号兼容旧模型键而附加账号只读自己的键`() async throws {
        let provider = AgentProvider.deepSeek
        let second = AccountIDs.extra(provider, 2)
        let third = AccountIDs.extra(provider, 3)
        let credentials = OAuthCredentials(access: "synthetic-key", refresh: "", expires: .max)
        let desk = AccountDesk(store: DeliveredCredentialSource([
            provider.storeID: credentials, second: credentials, third: credentials,
        ]))
        let response = await desk.list(extraModels: [
            provider.rawValue: ["first-model"], second: ["second-model"],
        ], onlyExtraModels: true)
        let rows = response.accounts.filter { $0.provider == provider && $0.signedIn }
        #expect(rows.first { $0.storeID == provider.storeID }?.models == ["first-model"])
        #expect(rows.first { $0.storeID == second }?.models == ["second-model"])
        #expect(rows.first { $0.storeID == third }?.models == [])
    }

    @Test func `首账号实际存储键优先旧键且不向附加账号广播`() async throws {
        let provider = AgentProvider.deepSeek
        #expect(provider.storeID != provider.rawValue)
        let second = AccountIDs.extra(provider, 2)
        let credentials = OAuthCredentials(access: "synthetic-key", refresh: "", expires: .max)
        let desk = AccountDesk(store: DeliveredCredentialSource([
            provider.storeID: credentials, second: credentials,
        ]))
        let rows = await desk.list(extraModels: [
            provider.storeID: ["actual-key-model"], provider.rawValue: ["old-key-model"],
        ], onlyExtraModels: true).accounts
        #expect(rows.first { $0.storeID == provider.storeID }?.models == ["actual-key-model"])
        #expect(rows.first { $0.storeID == second }?.models == [])
    }

    @Test func `自动限制拒绝跨服务商账号而不尝试解析`() async {
        let limits = await ProviderModels.automaticLimits(.deepSeek,
            credentials: OAuthCredentials(access: "synthetic-key", refresh: "", expires: .max),
            models: ["deepseek-chat"], storeID: AgentProvider.openAI.storeID)
        #expect(limits.isEmpty)
    }
}
