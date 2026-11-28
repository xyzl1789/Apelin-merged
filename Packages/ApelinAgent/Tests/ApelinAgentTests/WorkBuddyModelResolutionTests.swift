@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite("WorkBuddy 在线模型与真实请求", .serialized)
struct WorkBuddyModelResolutionTests {
    private final class Client: HTTPClient, @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [Data] = []
        private var reads = 0
        let config: String
        init(config: String) { self.config = config }
        var requests: [Data] { lock.withLock { bodies } }
        var configReads: Int { lock.withLock { reads } }
        func stream(url: URL, method: String, headers: [String: String], body: Data?, cancellation: CancellationHandle?) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            let response: Data
            if method == "GET" {
                lock.withLock { reads += 1 }
                response = Data(config.utf8)
            } else {
                if let body { lock.withLock { bodies.append(body) } }
                response = Data("data: {\"choices\":[{\"delta\":{\"content\":\"好\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
            }
            return (HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!,
                AsyncThrowingStream { $0.yield(response); $0.finish() })
        }
    }

    @Test func `在线独有模型的档位进入最终reasoning_effort而不只进入菜单`() async throws {
        for site in [WorkBuddySite.china, .international] {
            let credentials = OAuthCredentials(access: UUID().uuidString, refresh: "", expires: .max)
            let client = Client(config: #"{"code":0,"data":{"agents":[{"name":"cli","models":["live-only-model"]}],"models":[{"id":"live-only-model","supportsReasoning":true,"onlyReasoning":true,"reasoning":{"supportedEfforts":["low","max"]}}]}}"#)
            let rows = await WorkBuddyModelCache.shared.load(site: site, credentials: credentials, client: client)
            #expect(rows?.count == 1)
            #expect(client.configReads == 1)
            let manager = OAuthManager(source: DeliveredCredentialSource([site.id: credentials]))
            let resolved = try #require(try await ProviderRegistration.resolve(storeID: site.id, manager: manager, modelOverride: "live-only-model"))
            #expect(resolved.model.reasoning)
            #expect(supportedThinkingLevels(resolved.model).contains(.max))
            #expect(!supportedThinkingLevels(resolved.model).contains(.off))
            let stream = WorkBuddyProvider(site: site, client: client).stream(model: resolved.model,
                context: Context(systemPrompt: "测试", messages: [.user(UserMessage(text: "测试"))]),
                options: StreamOptions(resolvedAuth: ResolvedProviderAuth(token: "test", scheme: .bearer), reasoning: .max))
            for await _ in stream {}
            let body = try #require(client.requests.last)
            let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(request["model"] as? String == "live-only-model")
            #expect(request["reasoning_effort"] as? String == "max")
            #expect(client.configReads == 1, "会话应复用列表读到的同账号配置")
        }
    }

    @Test func `在线明确禁用推理覆盖目录而且不同账号不串缓存`() async throws {
        let first = OAuthCredentials(access: UUID().uuidString, refresh: "", expires: .max)
        let second = OAuthCredentials(access: UUID().uuidString, refresh: "", expires: .max)
        let cache = WorkBuddyModelCache()
        let client = Client(config: #"{"data":{"agents":[{"name":"cli","models":["quiet"]}],"models":[{"id":"quiet","supportsReasoning":false}]}}"#)
        let rows = await cache.load(site: .china, credentials: first, client: client)
        let live = try #require(rows?.first)
        #expect(cache.models(site: .china, credentials: second) == nil)
        #expect(cache.models(site: .international, credentials: first) == nil)
        #expect(cache.models(site: .china, credentials: first, storeID: "workbuddy#2") == nil)
        _ = await cache.load(site: .china, credentials: first, storeID: "workbuddy#2", client: client)
        #expect(cache.models(site: .china, credentials: first, storeID: "workbuddy#2")?.first?.id == "quiet")
        #expect(client.configReads == 2, "相同凭据导入到附加账号也不借用首账号能力缓存")
        var catalog = live
        catalog.reasoning = true
        catalog.thinkingLevelMap = ["high": "high"]
        let adopted = WorkBuddyModelCache.applyingReasoning(from: live, to: catalog, parameters: nil)
        #expect(!adopted.reasoning)
        #expect(adopted.thinkingLevelMap == nil)
        let stream = WorkBuddyProvider(site: .china, client: client).stream(model: adopted,
            context: Context(messages: [.user(UserMessage(text: "测试"))]),
            options: StreamOptions(resolvedAuth: ResolvedProviderAuth(token: "test", scheme: .bearer), reasoning: .high))
        for await _ in stream {}
        let body = try #require(client.requests.last)
        let request = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(request["reasoning_effort"] == nil)
    }
}
