@testable import ApelinAgent
import CryptoKit
import Foundation
import KWWKAI
import ApelinProtocol
import Testing

@Suite("提供商额度子系统", .serialized)
struct ProviderQuotaTests {
    // MARK: - 测试辅助

    private final class StubQuotaTransport: QuotaHTTPTransport, @unchecked Sendable {
        struct Recorded: Sendable { var url: URL; var method: String; var headers: [String: String] }
        private let lock = NSLock()
        private var recorded: [Recorded] = []
        private let responder: @Sendable (URLRequest) async throws -> (Int, [String: String], Data)
        init(_ responder: @escaping @Sendable (URLRequest) async throws -> (Int, [String: String], Data)) { self.responder = responder }
        var requests: [Recorded] { lock.withLock { recorded } }
        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            let entry = Recorded(url: request.url!, method: request.httpMethod ?? "GET", headers: request.allHTTPHeaderFields ?? [:])
            lock.withLock { recorded.append(entry) }
            let (status, headers, body) = try await responder(request)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, body)
        }
    }

    private struct StubKWWKUsage: KWWKQuotaUsageProvider {
        let handler: @Sendable (String, OAuthCredentials) async throws -> [OAuthUsageWindow]?
        func usage(for storeID: String, credentials: OAuthCredentials) async throws -> [OAuthUsageWindow]? { try await handler(storeID, credentials) }
    }

    private final class MockHTTPClient: HTTPClient, @unchecked Sendable {
        let statusCode: Int
        let headers: [String: String]
        init(statusCode: Int, headers: [String: String]) { self.statusCode = statusCode; self.headers = headers }
        func stream(url: URL, method _: String, headers _: [String: String], body _: Data?, cancellation _: CancellationHandle?) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            let response = HTTPURLResponse(url: url, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: headers)!
            return (response, AsyncThrowingStream<Data, Error> { $0.finish() })
        }
    }

    private func makeTempRoot() throws -> ApelinDataRoot {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("apelin-quota-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return ApelinDataRoot(home: home)
    }

    // MARK: - 身份、十进制与脱敏持久化

    @Test func `独立账号额度作用域保留原客户端模型转换及服务商行为`() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)
        let client = MockHTTPClient(statusCode: 200, headers: [:])
        let originalScope = "quota-registration-\(UUID().uuidString)"
        let transport = AnthropicProvider(
            client: client,
            extraHeaders: ["x-custom-client": "preserved"],
            maximumOutputTokens: 1234,
            modelIDTransform: { _ in "wire-model" },
            compatTransform: { value in
                var value = value ?? ModelCompat()
                value.behavesLikeProvider = "compat-preserved"
                return value
            },
        )
        await APIRegistry.shared.register(transport, scope: originalScope)
        var compatibility = ModelCompat()
        compatibility.behavesLikeProvider = "anthropic"
        let original = Model(id: "test", api: transport.api, provider: originalScope, compat: compatibility)
        let first = await ProviderRegistration.observingQuota(original, storeID: "anthropic", baseStoreID: "anthropic", store: store)
        let second = await ProviderRegistration.observingQuota(original, storeID: "anthropic#2", baseStoreID: "anthropic", store: store)
        #expect(first.provider != second.provider)
        #expect(first.behaviorProvider == original.behaviorProvider)
        #expect(second.behaviorProvider == original.behaviorProvider)
        let wrapped = try #require(await APIRegistry.shared.provider(scope: second.provider, api: second.api) as? AnthropicProvider)
        let observer = try #require(wrapped.client as? QuotaHeaderObservingHTTPClient)
        #expect(observer.inner as? MockHTTPClient === client)
        #expect(observer.storeID == "anthropic#2")
        #expect(wrapped.extraHeaders == transport.extraHeaders)
        #expect(wrapped.maximumOutputTokens == 1234)
        #expect(wrapped.modelIDTransform?(original) == "wire-model")
        #expect(wrapped.compatTransform?(nil)?.behavesLikeProvider == "compat-preserved")
        await APIRegistry.shared.unregisterScope(first.provider)
        await APIRegistry.shared.unregisterScope(second.provider)
        await APIRegistry.shared.unregisterScope(originalScope)
    }

    @Test func `API密钥按SHA256前16位去重且OAuth按存储实例区分`() {
        let secret = "sk-test-secret-value-12345"
        let prefix16 = String(SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
        let creds = OAuthCredentials(access: secret, refresh: "", expires: .max)
        let id1 = QuotaPoolIdentity.poolID(provider: .openAICompatible, storeID: CredentialProviderID.openAICompatible, credentials: creds, usesAPIKey: true)
        let id2 = QuotaPoolIdentity.poolID(provider: .deepSeek, storeID: CredentialProviderID.deepSeek, credentials: creds, usesAPIKey: true)
        #expect(id1 == "key:\(prefix16)")
        #expect(id1 == id2)
        let oauthID = QuotaPoolIdentity.poolID(provider: .anthropicOAuth, storeID: CredentialProviderID.anthropicOAuth, credentials: OAuthCredentials(access: "oauth-token-1", refresh: "r", expires: .max), usesAPIKey: false)
        #expect(oauthID == "oauth:anthropic")
    }

    @Test func `金额和百分比通过线协议保持Decimal精度`() throws {
        let balance = AgentQuotaBalance(id: "USD", currency: "USD", isAvailable: true, total: Decimal(string: "10.30"), granted: Decimal(string: "0.10"), toppedUp: Decimal(string: "10.20"), used: Decimal(string: "0.03"), remaining: Decimal(string: "10.27"))
        let window = AgentQuotaWindow(id: "fiveHour", label: "5 小时窗口", usedPercent: Decimal(string: "33.33")!)
        let snapshot = AgentQuotaSnapshot(poolID: "key:0123456789abcdef", provider: .deepSeek, kind: .balance, source: .activeAPI, status: .available, balances: [balance], windows: [window])
        let decoded = try JSONDecoder().decode(AgentQuotaSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.balances.first == balance)
        #expect(decoded.windows.first?.usedPercent == Decimal(string: "33.33"))
        #expect(decoded.windows.first?.remainingPercent == Decimal(string: "66.67"))
        for sample in ["0", "10.30", "123456.789", "-1.25"] {
            let decimal = try #require(Decimal(string: sample))
            #expect(QuotaDecimalCoding.parse(QuotaDecimalCoding.encode(decimal)) == decimal)
        }
        let request = AgentProviderQuotaRequest(accountID: "account:second")
        let requestCopy = try JSONDecoder().decode(AgentProviderQuotaRequest.self, from: JSONEncoder().encode(request))
        #expect(requestCopy.accountID == "account:second")
    }

    @Test func `数字一不是布尔值且ISO时间串不被当作十进制前缀`() throws {
        let body = try #require(JSONSerialization.jsonObject(with: Data(#"{"one":1,"zero":0,"flag":true}"#.utf8)) as? [String: Any])
        #expect(QuotaAdapters.decimalValue(body["one"]) == Decimal(1))
        #expect(QuotaAdapters.decimalValue(body["zero"]) == Decimal(0))
        #expect(QuotaAdapters.decimalValue(body["flag"]) == nil)
        #expect(QuotaDecimalCoding.parse("12junk") == nil)
        #expect(QuotaDecimalCoding.parse("2026-11-27T18:00:00Z") == nil)
        let formatter = ISO8601DateFormatter()
        #expect(QuotaAdapters.parseTimestamp("2026-11-27T18:00:00.123Z") == formatter.date(from: "2026-11-27T18:00:00Z"))
    }

    @Test func `缓存拒绝未来探测时间并保留被动更新前的池类型`() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.storeRelayProbe(endpointKey: "https://future.example", kind: .sub2api, now: now.addingTimeInterval(3600))
        #expect(store.cachedRelayProbe(for: "https://future.example", now: now) == nil)
        #expect(store.cachedRelayProbe(for: "https://future.example", now: now.addingTimeInterval(3605)) == .sub2api)
        #expect(store.cachedRelayProbe(for: "https://future.example", now: now.addingTimeInterval(3600 + 86400)) == nil)
        let debounce = now.addingTimeInterval(25)
        store.upsertPool(PersistedQuotaPool(poolID: "key:balance-pool", snapshot: AgentQuotaSnapshot(poolID: "key:balance-pool", provider: .openAICompatible, kind: .balance, source: .probedRelay, status: .available, manualDebounceUntil: debounce)))
        let merged = store.mergePassiveUpdate(poolID: "key:balance-pool", provider: .openAICompatible, accountLabel: "relay.example", windows: [AgentQuotaWindow(id: "fiveHour", label: "5 小时", usedPercent: Decimal(12))], balances: [], planName: nil, isExhausted: false, now: now)
        #expect(merged?.snapshot.kind == .balance)
        #expect(merged?.snapshot.manualDebounceUntil == debounce)
        #expect(root.quota.path.contains("wiki.qaq.apelin/Quota"))
    }

    @Test func `缓存去除秘密并隔离损坏文件`() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)
        let secretKey = "sk-super-secret-value-99999"
        store.upsertPool(PersistedQuotaPool(poolID: "key:1122334455667788", endpointKey: "https://api.deepseek.com", snapshot: AgentQuotaSnapshot(poolID: "key:1122334455667788", provider: .deepSeek, accountLabel: "api.deepseek.com", kind: .balance, source: .activeAPI, status: .cooldown, errorSummary: "Authorization: Bearer \(secretKey) failed")), secretToScrub: secretKey)
        let diskPath = root.quota.appendingPathComponent("pools.json")
        let diskText = try String(contentsOf: diskPath, encoding: .utf8)
        #expect(!diskText.contains(secretKey))
        #expect(!diskText.contains("Bearer "))
        let detailedSnapshot = AgentQuotaSnapshot(poolID: "key:labels", provider: .cursor, kind: .window, source: .activeAPI, status: .available,
            balances: [AgentQuotaBalance(id: secretKey, unitLabel: secretKey)],
            windows: [AgentQuotaWindow(id: secretKey, label: secretKey, usedPercent: 0, status: secretKey)], relayKind: secretKey)
        let sanitized = store.sanitizeSnapshot(detailedSnapshot, secretToScrub: secretKey)
        #expect(!String(decoding: try JSONEncoder().encode(sanitized), as: UTF8.self).contains(secretKey))
        try Data("not-json".utf8).write(to: diskPath)
        #expect(store.loadPools().isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: root.quota.path)
        #expect(files.contains { $0.hasPrefix("pools.json.unreadable-") })
    }

    // MARK: - 主动查询适配器

    @Test func `DeepSeek按币种拆池并保留精度与可用状态`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://api.deepseek.com/user/balance")
            #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer ds-secret")
            let body = #"{"is_available":true,"balance_infos":[{"currency":"CNY","total_balance":"12.50","granted_balance":"2.50","topped_up_balance":"10.00"},{"currency":"USD","total_balance":"0.00","granted_balance":"0.00","topped_up_balance":"0.00"}]}"#
            return (200, [:], Data(body.utf8))
        }
        let res = try await QuotaAdapters.query(provider: .deepSeek, poolID: "key:ds", accountLabel: "api.deepseek.com", credentials: OAuthCredentials(access: "ds-secret", refresh: "", expires: .max), usesAPIKey: true, cachedRelayProbe: nil, transport: transport)
        #expect(res.snapshot.status == .available)
        #expect(res.snapshot.balances.count == 2)
        #expect(res.snapshot.balances[0].currency == "CNY")
        #expect(res.snapshot.balances[0].total == Decimal(string: "12.50"))
        #expect(res.snapshot.balances[0].granted == Decimal(string: "2.50"))
        #expect(res.snapshot.balances[0].toppedUp == Decimal(string: "10.00"))
        #expect(res.snapshot.balances[0].isAvailable)
        #expect(res.snapshot.balances[1].currency == "USD")
        #expect(!res.snapshot.balances[1].isAvailable)
    }

    @Test func `Moonshot国内映射人民币国际映射美元`() async throws {
        for (base, currency) in [("https://api.moonshot.cn/v1", "CNY"), ("https://api.moonshot.ai/v1", "USD")] {
            let transport = StubQuotaTransport { req in
                #expect(req.url?.absoluteString.hasSuffix("/v1/users/me/balance") == true)
                return (200, [:], Data(#"{"data":{"available_balance":42.75,"voucher_balance":2.75,"cash_balance":40.0}}"#.utf8))
            }
            let creds = OAuthCredentials(access: "ms-key", refresh: "", expires: .max, extras: ["baseUrl": .string(base)])
            let res = try await QuotaAdapters.query(provider: .openAICompatible, poolID: "key:ms", accountLabel: nil, credentials: creds, usesAPIKey: true, cachedRelayProbe: nil, transport: transport)
            #expect(res.snapshot.balances.first?.currency == currency)
            #expect(res.snapshot.balances.first?.remaining == Decimal(string: "42.75"))
        }
    }

    @Test func `SiliconFlow只读取余额且忽略个人资料`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://api.siliconflow.cn/v1/user/info")
            return (200, [:], Data(#"{"data":{"id":"user-999","name":"测试用户","email":"private@example.com","phone":"+8613800138000","balance":"1.25","chargeBalance":"8.75","totalBalance":"10.00"}}"#.utf8))
        }
        let creds = OAuthCredentials(access: "sf-key", refresh: "", expires: .max, extras: ["baseUrl": .string("https://api.siliconflow.cn/v1")])
        let res = try await QuotaAdapters.query(provider: .openAICompatible, poolID: "key:sf", accountLabel: "api.siliconflow.cn", credentials: creds, usesAPIKey: true, cachedRelayProbe: nil, transport: transport)
        let encoded = String(decoding: try JSONEncoder().encode(res.snapshot), as: UTF8.self)
        #expect(!encoded.contains("测试用户"))
        #expect(!encoded.contains("private@example.com"))
        #expect(!encoded.contains("13800138000"))
        #expect(res.snapshot.balances.first?.currency == "CNY")
        #expect(res.snapshot.balances.first?.remaining == Decimal(string: "10.00"))
    }

    @Test func `OpenRouter查询密钥和总余额`() async throws {
        let transport = StubQuotaTransport { req in
            switch req.url?.path {
            case "/api/v1/key": return (200, [:], Data(#"{"data":{"limit":20.0,"limit_remaining":15.5,"usage":4.5,"is_free_tier":false}}"#.utf8))
            case "/api/v1/credits": return (200, [:], Data(#"{"data":{"total_credits":50.0,"total_usage":12.25}}"#.utf8))
            default: return (404, [:], Data())
            }
        }
        let res = try await QuotaAdapters.query(provider: .openRouter, poolID: "key:or", accountLabel: "openrouter.ai", credentials: OAuthCredentials(access: "sk-or-v1-abc", refresh: "", expires: .max), usesAPIKey: true, cachedRelayProbe: nil, transport: transport)
        #expect(transport.requests.count == 2)
        #expect(res.snapshot.balances.count == 2)
        #expect(res.snapshot.balances[0].remaining == Decimal(string: "37.75"))
        #expect(res.snapshot.balances[1].remaining == Decimal(string: "15.5"))
    }

    @Test func `Codex发送官方CLI请求头和ChatGPT账号标识`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://chatgpt.com/backend-api/wham/usage")
            #expect(req.value(forHTTPHeaderField: "User-Agent") == "codex_cli_rs")
            #expect(req.value(forHTTPHeaderField: "Originator") == "codex_cli_rs")
            #expect(req.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "acct-42")
            return (200, [:], Data(#"{"plan_type":"pro","rate_limit":{"primary_window":{"used_percent":18,"limit_window_seconds":18000,"reset_at":1800000000},"secondary_window":{"used_percent":44,"limit_window_seconds":604800,"reset_at":1800500000}}}"#.utf8))
        }
        let creds = OAuthCredentials(access: "codex-jwt", refresh: "r", expires: .max, extras: ["accountId": .string("acct-42")])
        let res = try await QuotaAdapters.query(provider: .openAICodex, poolID: "oauth:openai-codex", accountLabel: nil, credentials: creds, usesAPIKey: false, cachedRelayProbe: nil, transport: transport)
        #expect(res.snapshot.planName == "pro")
        #expect(res.snapshot.windows.count == 2)
        #expect(res.snapshot.windows[0].id == "fiveHour")
        #expect(res.snapshot.windows[0].usedPercent == Decimal(18))
        #expect(res.snapshot.windows[1].id == "sevenDay")
        #expect(res.snapshot.windows[1].usedPercent == Decimal(44))
    }

    @Test func `Claude主动API的利用率一代表百分之一而非百分之百`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://api.anthropic.com/api/oauth/usage")
            #expect(req.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
            #expect(req.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("claude-cli/") == true)
            #expect(req.value(forHTTPHeaderField: "x-app") == "cli")
            return (200, [:], Data(#"{"five_hour":{"utilization":1,"resets_at":"2026-11-27T18:00:00Z"},"seven_day":{"utilization":37.5,"resets_at":"2026-12-01T00:00:00Z"}}"#.utf8))
        }
        let res = try await QuotaAdapters.query(provider: .anthropicOAuth, poolID: "oauth:anthropic", accountLabel: nil, credentials: OAuthCredentials(access: "claude-tok", refresh: "r", expires: .max), usesAPIKey: false, cachedRelayProbe: nil, transport: transport)
        #expect(res.snapshot.windows.count == 2)
        #expect(res.snapshot.windows[0].usedPercent == Decimal(1))
        #expect(res.snapshot.windows[1].usedPercent == Decimal(string: "37.5"))
    }

    @Test func `KimiCode不发送伪造的UserAgent`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://api.kimi.ai/coding/v1/usages")
            #expect(req.value(forHTTPHeaderField: "User-Agent") == nil)
            return (200, [:], Data(#"{"limits":[{"window":{"duration":5,"timeUnit":"HOUR"},"detail":{"limit":100,"used":25,"reset_in":3600}}]}"#.utf8))
        }
        let res = try await QuotaAdapters.query(provider: .kimiCodingGlobal, poolID: "oauth:kimi-coding-ai", accountLabel: nil, credentials: OAuthCredentials(access: "kimi-tok", refresh: "r", expires: .max), usesAPIKey: false, cachedRelayProbe: nil, transport: transport)
        #expect(res.snapshot.windows.first?.id == "fiveHour")
        #expect(res.snapshot.windows.first?.usedPercent == Decimal(25))
    }

    @Test func `Cursor通过kwwk读出多个订阅额度窗口`() async throws {
        let usage = StubKWWKUsage { storeID, _ in
            #expect(storeID == "cursor")
            return [
                OAuthUsageWindow(window: .fiveHour, usedPercent: 42, resetsAt: 1_800_000_000_000, windowSeconds: 18000, limitID: "pool-a", limitName: "订阅额度"),
                OAuthUsageWindow(window: .fiveHour, usedPercent: 15, resetsAt: 1_800_000_000_000, windowSeconds: 18000, limitID: "pool-b", limitName: "额外额度"),
            ]
        }
        let res = try await QuotaAdapters.query(provider: .cursor, poolID: "oauth:cursor", accountLabel: nil, credentials: OAuthCredentials(access: "cursor-tok", refresh: "r", expires: .max), usesAPIKey: false, cachedRelayProbe: nil, transport: StubQuotaTransport { _ in (404, [:], Data()) }, kwwkUsage: usage)
        #expect(res.snapshot.kind == .window)
        #expect(res.snapshot.windows.count == 2)
        #expect(res.snapshot.windows[0].usedPercent == Decimal(42))
        #expect(res.snapshot.windows[1].usedPercent == Decimal(15))
    }

    @Test func `中转探测顺序与原始单位及无限额度阈值`() async throws {
        let creds = OAuthCredentials(access: "r-key", refresh: "", expires: .max, extras: ["baseUrl": .string("https://relay.example.com/v1/")])
        let subTransport = StubQuotaTransport { req in
            #expect(req.url?.absoluteString == "https://relay.example.com/v1/usage")
            return (200, [:], Data(#"{"remaining":8.5,"limit":10.0,"plan_name":"Pro"}"#.utf8))
        }
        let subRes = try await QuotaAdapters.query(provider: .openAICompatible, poolID: "key:sub", accountLabel: "relay.example.com", credentials: creds, usesAPIKey: true, cachedRelayProbe: nil, transport: subTransport)
        #expect(subRes.relayProbeKind == .sub2api)
        #expect(subRes.snapshot.balances.first?.remaining == Decimal(string: "8.5"))
        let newTransport = StubQuotaTransport { req in
            if req.url?.path == "/api/usage/token" { return (200, [:], Data(#"{"code":true,"data":{"total_available":500000,"total_used":125000,"unlimited_quota":false}}"#.utf8)) }
            return (404, [:], Data())
        }
        let newRes = try await QuotaAdapters.query(provider: .openAICompatible, poolID: "key:newapi", accountLabel: "relay.example.com", credentials: creds, usesAPIKey: true, cachedRelayProbe: nil, transport: newTransport)
        #expect(newRes.relayProbeKind == .newapi)
        #expect(newRes.snapshot.balances.first?.currency == nil)
        #expect(newRes.snapshot.balances.first?.unitLabel == "quota")
        #expect(newRes.snapshot.balances.first?.remaining == Decimal(500_000))
        let billingTransport = StubQuotaTransport { req in
            switch req.url?.path {
            case "/v1/dashboard/billing/subscription": return (200, [:], Data(#"{"hard_limit_usd":100000000}"#.utf8))
            case "/v1/dashboard/billing/usage": return (200, [:], Data(#"{"total_usage":1234}"#.utf8))
            default: return (404, [:], Data())
            }
        }
        let billingRes = try await QuotaAdapters.query(provider: .openAICompatible, poolID: "key:oai-bill", accountLabel: "relay.example.com", credentials: creds, usesAPIKey: true, cachedRelayProbe: nil, transport: billingTransport)
        #expect(billingRes.relayProbeKind == .openAIBilling)
        #expect(billingRes.snapshot.balances.first?.isUnlimited == true)
        #expect(billingRes.snapshot.balances.first?.used == Decimal(string: "12.34"))
    }

    // MARK: - 被动响应头与冷却复位

    @Test func `被动响应头归一化利用率并处理429及复位冷却`() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        store.upsertPool(PersistedQuotaPool(poolID: "oauth:anthropic", snapshot: AgentQuotaSnapshot(poolID: "oauth:anthropic", provider: .anthropicOAuth, kind: .window, source: .activeAPI, status: .cooldown, cooldownUntil: now.addingTimeInterval(600)), consecutiveFailures: 3, cooldownUntil: now.addingTimeInterval(600)))
        let client = QuotaHeaderObservingHTTPClient(inner: MockHTTPClient(statusCode: 429, headers: [
            "anthropic-ratelimit-unified-5h-utilization": "0.85", "anthropic-ratelimit-unified-5h-status": "allowed_warning",
            "anthropic-ratelimit-unified-7d-utilization": "42", "anthropic-ratelimit-unified-7d-status": "rejected", "anthropic-ratelimit-unified-status": "rejected",
        ]), storeID: CredentialProviderID.anthropicOAuth, store: store)
        _ = try await client.stream(url: URL(string: "https://api.anthropic.com/v1/messages")!, method: "POST", headers: [:], body: nil, cancellation: nil)
        // 等待不阻塞响应流的后台合并。
        for _ in 0 ..< 100 {
            if store.pool(for: "oauth:anthropic")?.snapshot.source == .passiveHeaders { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let updated = try #require(store.pool(for: "oauth:anthropic"))
        #expect(updated.consecutiveFailures == 0)
        #expect(updated.cooldownUntil == nil)
        #expect(updated.snapshot.source == .passiveHeaders)
        #expect(updated.snapshot.status == .exhausted)
        #expect(updated.snapshot.windows.first { $0.id == "fiveHour" }?.usedPercent == Decimal(85))
        #expect(updated.snapshot.windows.first { $0.id == "sevenDay" }?.usedPercent == Decimal(42))
        let codex = PassiveQuotaHeaderParser.parse(storeID: "openai-codex", statusCode: 200, headers: [
            "x-codex-primary-used-percent": "27.5", "x-codex-primary-window-minutes": "300", "x-codex-primary-reset-after-seconds": "1200",
            "x-codex-plan-type": "plus", "x-codex-credits-has-credits": "true", "x-codex-credits-balance": "14.20",
        ], now: now)
        #expect(codex?.planName == "plus")
        #expect(codex?.windows.first?.id == "fiveHour")
        #expect(codex?.windows.first?.usedPercent == Decimal(string: "27.5"))
        #expect(codex?.balances.first?.remaining == Decimal(string: "14.20"))
    }

    @Test func `两个缓存实例共享退出代次且旧令牌不能重建额度池`() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let sessionStore = QuotaCacheStore(dataRoot: root)
        let accountStore = QuotaCacheStore(dataRoot: root)
        let firstID = "oauth:anthropic"
        let secondID = "oauth:anthropic#2"
        let oldFirst = try #require(sessionStore.passiveGeneration(for: firstID))
        let second = try #require(sessionStore.passiveGeneration(for: secondID))
        #expect(accountStore.passiveGeneration(for: firstID) == oldFirst)
        func merge(_ store: QuotaCacheStore, pool: String, generation: UUID, percent: Decimal) -> PersistedQuotaPool? {
            store.mergePassiveUpdate(poolID: pool, provider: .anthropicOAuth, accountLabel: nil,
                windows: [AgentQuotaWindow(id: "fiveHour", label: "5 小时窗口", usedPercent: percent)], balances: [], planName: nil,
                isExhausted: false, expectedGeneration: generation)
        }
        #expect(merge(sessionStore, pool: firstID, generation: oldFirst, percent: 10) != nil)
        #expect(merge(sessionStore, pool: secondID, generation: second, percent: 20) != nil)
        accountStore.clearPool(poolID: firstID)
        #expect(!sessionStore.isCurrentPassiveGeneration(oldFirst, for: firstID))
        #expect(merge(sessionStore, pool: firstID, generation: oldFirst, percent: 90) == nil)
        #expect(sessionStore.pool(for: firstID) == nil)
        #expect(sessionStore.isCurrentPassiveGeneration(second, for: secondID))
        #expect(sessionStore.pool(for: secondID)?.snapshot.windows.first?.usedPercent == 20)
        let fresh = try #require(accountStore.passiveGeneration(for: firstID))
        #expect(fresh != oldFirst)
        #expect(merge(sessionStore, pool: firstID, generation: fresh, percent: 30) != nil)
        #expect(merge(accountStore, pool: firstID, generation: oldFirst, percent: 99) == nil)
        #expect(sessionStore.pool(for: firstID)?.snapshot.windows.first?.usedPercent == 30)
    }

    @Test func `旧观察器退出后的迟到响应和后续请求都不能恢复缓存`() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let sessionStore = QuotaCacheStore(dataRoot: root)
        let accountStore = QuotaCacheStore(dataRoot: root)
        let gate = ResponseGate()
        let oldClient = QuotaHeaderObservingHTTPClient(inner: DelayedHTTPClient(gate: gate), storeID: "anthropic#2", store: sessionStore)
        let url = URL(string: "https://api.anthropic.com/v1/messages")!
        let pending = Task {
            _ = try await oldClient.stream(url: url, method: "POST", headers: [:], body: nil, cancellation: nil)
        }
        await gate.waitForStart()
        accountStore.clearPool(poolID: "oauth:anthropic#2")
        await gate.release()
        try await pending.value
        let freshClient = QuotaHeaderObservingHTTPClient(inner: MockHTTPClient(statusCode: 200, headers: ["anthropic-ratelimit-unified-5h-utilization": "0.27"]), storeID: "anthropic#2", store: accountStore)
        _ = try await freshClient.stream(url: url, method: "POST", headers: [:], body: nil, cancellation: nil, timeoutSeconds: 15)
        for _ in 0 ..< 100 {
            if sessionStore.pool(for: "oauth:anthropic#2")?.snapshot.windows.first?.usedPercent == 27 { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(sessionStore.pool(for: "oauth:anthropic#2")?.snapshot.windows.first?.usedPercent == 27)
        #expect(sessionStore.pool(for: "oauth:anthropic") == nil)
        // 旧客户端即使再次发起请求，也不能重新绑定新登录的代次。
        _ = try await oldClient.stream(url: url, method: "POST", headers: [:], body: nil, cancellation: nil, timeoutSeconds: 15)
        try await Task.sleep(nanoseconds: 50_000_000)
        #expect(sessionStore.pool(for: "oauth:anthropic#2")?.snapshot.windows.first?.usedPercent == 27)
    }

    @Test func `读取失败不覆盖池和探测记录且代次失败时禁止清理`() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)
        let poolID = "oauth:anthropic"
        let token = try #require(store.passiveGeneration(for: poolID))
        let pool = PersistedQuotaPool(poolID: poolID, snapshot: AgentQuotaSnapshot(poolID: poolID, provider: .anthropicOAuth, kind: .window, source: .activeAPI, status: .available))
        store.upsertPool(pool)
        store.storeRelayProbe(endpointKey: "https://relay.example", kind: .sub2api)
        let poolsFile = root.quota.appendingPathComponent("pools.json")
        let probesFile = root.quota.appendingPathComponent("probes.json")
        let generationsFile = root.quota.appendingPathComponent("generations.json")
        let poolsBefore = try Data(contentsOf: poolsFile)
        let probesBefore = try Data(contentsOf: probesFile)
        let generationsBefore = try Data(contentsOf: generationsFile)
        let denied = QuotaCacheStore(dataRoot: root, readData: { url in
            if ["pools.json", "probes.json"].contains(url.lastPathComponent) { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        #expect(denied.loadPools().isEmpty)
        denied.upsertPool(pool)
        #expect(denied.mergePassiveUpdate(poolID: poolID, provider: .anthropicOAuth, accountLabel: nil, windows: [], balances: [], planName: nil, isExhausted: false, expectedGeneration: token) == nil)
        denied.storeRelayProbe(endpointKey: "https://new.example", kind: .newapi)
        #expect(try Data(contentsOf: poolsFile) == poolsBefore)
        #expect(try Data(contentsOf: probesFile) == probesBefore)
        let generationDenied = QuotaCacheStore(dataRoot: root, readData: { url in
            if url.lastPathComponent == "generations.json" { throw CocoaError(.fileReadNoPermission) }
            return try Data(contentsOf: url)
        })
        #expect(generationDenied.passiveGeneration(for: poolID) == nil)
        #expect(!generationDenied.isCurrentPassiveGeneration(token, for: poolID))
        generationDenied.clearPool(poolID: poolID)
        #expect(generationDenied.mergePassiveUpdate(poolID: poolID, provider: .anthropicOAuth, accountLabel: nil, windows: [], balances: [], planName: nil, isExhausted: false, expectedGeneration: token) == nil)
        #expect(try Data(contentsOf: poolsFile) == poolsBefore)
        #expect(try Data(contentsOf: generationsFile) == generationsBefore)
        #expect(store.isCurrentPassiveGeneration(token, for: poolID))
    }

    @Test func `损坏代次隔离后旧令牌永久失效且可以生成新令牌`() throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let first = QuotaCacheStore(dataRoot: root)
        let second = QuotaCacheStore(dataRoot: root)
        let poolID = "oauth:anthropic"
        let old = try #require(first.passiveGeneration(for: poolID))
        try Data("broken-generation".utf8).write(to: root.quota.appendingPathComponent("generations.json"))
        #expect(!second.isCurrentPassiveGeneration(old, for: poolID))
        let fresh = try #require(second.passiveGeneration(for: poolID))
        #expect(old != fresh)
        #expect(!first.isCurrentPassiveGeneration(old, for: poolID))
        #expect(first.isCurrentPassiveGeneration(fresh, for: poolID))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.quota.path)
        #expect(files.contains { $0.hasPrefix("generations.json.unreadable-") })
    }

    // MARK: - SingleFlight、30 秒门禁与 24 小时熔断

    @Test func `协调器共享请求并执行30秒门禁手动防抖和24小时熔断`() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)
        let clock = LockedDate(Date(timeIntervalSince1970: 1_800_000_000))
        let counter = LockedCounter()
        let transport = StubQuotaTransport { req in
            counter.increment()
            try await Task.sleep(nanoseconds: 50_000_000)
            if req.url?.host == "dead.relay.example" { return (404, [:], Data()) }
            return (200, [:], Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"5.00"}]}"#.utf8))
        }
        let coordinator = QuotaCoordinator(store: store, transport: transport, clock: { clock.now })
        let account = QuotaAccountDescriptor(provider: .deepSeek, storeID: CredentialProviderID.deepSeek, accountLabel: "api.deepseek.com", credentials: OAuthCredentials(access: "ds-1", refresh: "", expires: .max), usesAPIKey: true)
        let shared = QuotaAccountDescriptor(provider: .openAICompatible, storeID: CredentialProviderID.openAICompatible, accountLabel: "relay.deepseek.example", credentials: OAuthCredentials(access: "ds-1", refresh: "", expires: .max, extras: ["baseUrl": .string("https://api.deepseek.com")]), usesAPIKey: true)
        async let a = coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false)
        async let b = coordinator.snapshot(for: shared, mode: .attentionGated, foreground: true, force: false)
        let (snapA, snapB) = await (a, b)
        #expect(counter.value == 1)
        #expect(snapA.provider == .deepSeek)
        #expect(snapB.provider == .openAICompatible)
        #expect(snapB.accountLabel == "relay.deepseek.example")
        clock.advance(by: 20)
        let gated = await coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false)
        #expect(counter.value == 1)
        #expect(gated.nextAllowedAt == nil)
        clock.advance(by: 10)
        _ = await coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false)
        #expect(counter.value == 2)
        let manual = await coordinator.snapshot(for: account, mode: .manualRefresh, foreground: true, force: true)
        #expect(counter.value == 3)
        #expect(manual.nextAllowedAt == nil)
        #expect(manual.manualDebounceUntil == clock.now.addingTimeInterval(QuotaCoordinator.manualDebounceInterval))
        clock.advance(by: 10)
        let debounced = await coordinator.snapshot(for: account, mode: .manualRefresh, foreground: true, force: true)
        #expect(counter.value == 3)
        #expect(debounced.manualDebounceUntil == clock.now.addingTimeInterval(20))
        let dead = QuotaAccountDescriptor(provider: .openAICompatible, storeID: CredentialProviderID.openAICompatible, accountLabel: "dead.relay.example", credentials: OAuthCredentials(access: "k", refresh: "", expires: .max, extras: ["baseUrl": .string("https://dead.relay.example")]), usesAPIKey: true)
        let broken = await coordinator.snapshot(for: dead, mode: .attentionGated, foreground: true, force: false)
        #expect(broken.status == .circuitBroken)
        #expect(broken.circuitBrokenUntil == clock.now.addingTimeInterval(86400))
        let afterTrip = counter.value
        clock.advance(by: 12 * 3600)
        _ = await coordinator.snapshot(for: dead, mode: .attentionGated, foreground: true, force: false)
        #expect(counter.value == afterTrip)
    }

    @Test func `退出额度池后忽略取消的在途请求不能重新写缓存`() async throws {
        let root = try makeTempRoot()
        defer { try? FileManager.default.removeItem(at: root.home) }
        let store = QuotaCacheStore(dataRoot: root)
        let gate = ResponseGate()
        let transport = StubQuotaTransport { _ in
            await gate.waitForRelease()
            return (200, [:], Data(#"{"is_available":true,"balance_infos":[{"currency":"USD","total_balance":"5.00"}]}"#.utf8))
        }
        let coordinator = QuotaCoordinator(store: store, transport: transport)
        let credentials = OAuthCredentials(access: "ds-stale", refresh: "", expires: .max)
        let account = QuotaAccountDescriptor(provider: .deepSeek, storeID: CredentialProviderID.deepSeek, accountLabel: nil, credentials: credentials, usesAPIKey: true)
        let pending = Task { await coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false) }
        await gate.waitForStart()
        let poolID = QuotaPoolIdentity.poolID(provider: account.provider, storeID: account.storeID, credentials: credentials, usesAPIKey: true)
        await coordinator.forget(poolID: poolID)
        await gate.release()
        _ = await pending.value
        #expect(store.pool(for: poolID) == nil)
    }

    // MARK: - 本地中转代币头与重定向保护

    @Test func `代币额度头保持完整精度且拒绝缺失畸形负值及不一致用量`() throws {
        let valid = ["X-Quota-Limit": "1000000.123456", "x-quota-used": "0.000001", "x-quota-remaining": "1000000.123455"]
        let balance = try #require(QuotaAdapters.parseTokenQuota(valid))
        #expect(balance.currency == nil)
        #expect(balance.unitLabel == "tokens")
        #expect(balance.total == Decimal(string: "1000000.123456"))
        #expect(balance.used == Decimal(string: "0.000001"))
        #expect(balance.remaining == Decimal(string: "1000000.123455"))
        #expect(QuotaAdapters.parseTokenQuota(["x-quota-limit": "10", "x-quota-remaining": "3"])?.used == Decimal(7))
        for invalid in [
            ["x-quota-remaining": "3"], ["x-quota-limit": "10"],
            ["x-quota-limit": "10junk", "x-quota-remaining": "3"],
            ["x-quota-limit": "NaN", "x-quota-remaining": "3"],
            ["x-quota-limit": "10", "x-quota-remaining": "-1"],
            ["x-quota-limit": "10", "x-quota-remaining": "11"],
            ["x-quota-limit": "0", "x-quota-remaining": "0"],
            ["x-quota-limit": "10", "x-quota-remaining": "3", "x-quota-used": "-7"],
            ["x-quota-limit": "10", "x-quota-remaining": "3", "x-quota-used": "8"],
            ["x-quota-limit": "10", "x-quota-remaining": "3", "x-quota-used": "7junk"],
        ] { #expect(QuotaAdapters.parseTokenQuota(invalid) == nil) }
    }

    @Test func `指定中转只对HTTPS同站models发起额度头查询`() async throws {
        let transport = StubQuotaTransport { req in
            #expect(req.httpMethod == "GET")
            #expect(req.url?.absoluteString == "https://100milionseek.top/v1/models")
            return (200, ["x-quota-limit": "1000000", "x-quota-used": "120000", "x-quota-remaining": "880000"], Data())
        }
        let creds = OAuthCredentials(access: "test-token", refresh: "", expires: .max, extras: ["baseUrl": .string("https://100milionseek.top/v1")])
        let res = try await QuotaAdapters.query(provider: .openAICompatible, poolID: "key:token-quota", accountLabel: nil, credentials: creds, usesAPIKey: true, cachedRelayProbe: nil, transport: transport)
        #expect(transport.requests.count == 1)
        #expect(res.snapshot.balances.first?.unitLabel == "tokens")
        #expect(res.snapshot.balances.first?.remaining == Decimal(880000))
        let insecure = OAuthCredentials(access: "test-token", refresh: "", expires: .max, extras: ["baseUrl": .string("http://100milionseek.top/v1")])
        do {
            _ = try await QuotaAdapters.query(provider: .openAICompatible, poolID: "key:insecure", accountLabel: nil, credentials: insecure, usesAPIKey: true, cachedRelayProbe: nil, transport: transport)
            Issue.record("HTTP 地址不应发出额度请求")
        } catch let error as QuotaAdapterError {
            if case .invalidResponse = error {} else { Issue.record("应拒绝不安全地址") }
        }
        #expect(transport.requests.count == 1)
    }

    @Test func `额度传输委托拒绝重定向请求`() {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let original = URL(string: "https://100milionseek.top/v1/models")!
        let task = session.dataTask(with: original)
        let redirect = HTTPURLResponse(url: original, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://other.example"])!
        var completionCalled = false
        QuotaRedirectHold().urlSession(session, task: task, willPerformHTTPRedirection: redirect, newRequest: URLRequest(url: URL(string: "https://other.example")!)) { accepted in
            completionCalled = true
            #expect(accepted == nil)
        }
        #expect(completionCalled)
        task.cancel()
    }

    private final class DelayedHTTPClient: HTTPClient, @unchecked Sendable {
        let gate: ResponseGate
        private let lock = NSLock()
        private var started = false
        init(gate: ResponseGate) { self.gate = gate }
        func stream(url: URL, method _: String, headers _: [String: String], body _: Data?, cancellation _: CancellationHandle?) async throws -> (HTTPURLResponse, AsyncThrowingStream<Data, Error>) {
            let first = lock.withLock {
                let first = !started
                started = true
                return first
            }
            if first { await gate.waitForRelease() }
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["anthropic-ratelimit-unified-5h-utilization": "0.91"])!
            return (response, AsyncThrowingStream<Data, Error> { $0.finish() })
        }
    }

    private actor ResponseGate {
        private var started = false
        private var startWaiters: [CheckedContinuation<Void, Never>] = []
        private var reply: CheckedContinuation<Void, Never>?
        func waitForStart() async {
            if started { return }
            await withCheckedContinuation { startWaiters.append($0) }
        }
        func waitForRelease() async {
            started = true
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
            await withCheckedContinuation { reply = $0 }
        }
        func release() { reply?.resume(); reply = nil }
    }

    private final class LockedDate: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date) { self.date = date }
        var now: Date { lock.withLock { date } }
        func advance(by seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    }
    private final class LockedCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
}
