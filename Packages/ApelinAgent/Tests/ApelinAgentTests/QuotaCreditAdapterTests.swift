@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite("真实积分与旧计费路径", .serialized)
struct QuotaCreditAdapterTests {
    private final class Transport: QuotaHTTPTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [URLRequest] = []
        private let respond: @Sendable (URLRequest) throws -> (Int, String)
        init(_ respond: @escaping @Sendable (URLRequest) throws -> (Int, String)) { self.respond = respond }
        var requests: [URLRequest] { lock.withLock { recorded } }
        func send(_ request: URLRequest) async throws -> (HTTPURLResponse, Data) {
            lock.withLock { recorded.append(request) }
            let (status, text) = try respond(request)
            return (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!, Data(text.utf8))
        }
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func query(_ provider: AgentProvider, transport: Transport) async throws -> AgentQuotaSnapshot {
        try await QuotaAdapters.query(provider: provider, poolID: "oauth:test", accountLabel: nil,
            credentials: OAuthCredentials(access: "test-token", refresh: "", expires: .max, extras: ["uid": .string("test-account"), "enterpriseId": .string("test-team")]),
            usesAPIKey: false, cachedRelayProbe: nil, transport: transport, now: now).snapshot
    }

    @Test func `WorkBuddy两站从原始积分包合计且保留精度和最早到期`() async throws {
        for (provider, site) in [(AgentProvider.workBuddy, WorkBuddySite.china), (.workBuddyAI, .international)] {
            let transport = Transport { request in
                #expect(request.url?.path == "/v2/billing/meter/get-user-resource" || request.url?.path == "/billing/meter/get-user-resource-summary")
                if request.url?.path == "/v2/billing/meter/get-user-resource" {
                    #expect(request.url?.host == (provider == .workBuddy ? "www.codebuddy.cn" : "www.workbuddy.ai"))
                    let body = try #require(request.httpBody)
                    let requestBody = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
                    #expect(requestBody["ProductCode"] as? String == "p_tcaca")
                    return (404, "")
                }
                #expect(request.url?.host == URL(string: site.endpoint)?.host)
                #expect(request.httpMethod == "POST")
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-token")
                #expect(request.value(forHTTPHeaderField: "X-Enterprise-Id") == "test-team")
                #expect(request.value(forHTTPHeaderField: "User-Agent") == WorkBuddyOAuth.userAgent)
                return (200, #"{"code":0,"data":{"Packages":[{"PackageName":"订阅包","CycleTotalCapacity":"3300","CycleUsedCapacity":"438.88000002","ExpireTime":1800002000},{"PackageName":"奖励包","CycleTotalCapacity":"100","CycleUsedCapacity":"10","ExpireTime":1800001000000},{"CycleTotalCapacity":"9999","CycleUsedCapacity":"0","ExpireTime":1}]}}"#)
            }
            let snapshot = try await query(provider, transport: transport)
            #expect(snapshot.kind == .balance)
            #expect(snapshot.windows.isEmpty)
            #expect(snapshot.balances.count == 1)
            #expect(snapshot.balances[0].total == 3400)
            #expect(snapshot.balances[0].used == Decimal(string: "448.88000002"))
            #expect(snapshot.balances[0].remaining == Decimal(string: "2951.11999998"))
            #expect(snapshot.creditPackages?.count == 2)
            #expect(snapshot.earliestCreditExpiry == Date(timeIntervalSince1970: 1_800_001_000))
            let projected = AgentQuotaDisplayRecord(accountID: "workbuddy", snapshot: snapshot).balances
            #expect(projected.count == 1, "明细不能重复投影到胶囊")
            #expect(projected[0].currency == "积分")
            #expect(projected[0].amount == "2951.11999998")
            #expect(try JSONDecoder().decode(AgentQuotaSnapshot.self, from: JSONEncoder().encode(snapshot)) == snapshot)
        }
    }

    @Test func `WorkBuddy旧资源响应仍读取精确计数并遵守周期剩余约束`() async throws {
        let transport = Transport { request in
            if request.url?.path == "/billing/meter/get-user-resource-summary" { return (404, "") }
            #expect(request.url?.path == "/v2/billing/meter/get-user-resource")
            return (200, #"{"data":{"Response":{"Data":{"Accounts":[{"CapacitySizePrecise":"100","CapacityUsedPrecise":"94","CapacityRemainPrecise":"6","CycleCapacitySizePrecise":"20","CycleCapacityRemainPrecise":"12"}]}}}}"#)
        }
        let snapshot = try await query(.workBuddy, transport: transport)
        #expect(snapshot.balances.first?.remaining == 6)
        #expect(snapshot.balances.first?.total == 20)
        #expect(snapshot.balances.first?.used == 8)
        #expect(snapshot.earliestCreditExpiry == nil, "没有到期时间时不能根据周期推算")
        #expect(transport.requests.count == 1)
    }

    @Test func `WorkBuddy分页收齐后才合计积分且普通计数可补空精确字段`() async throws {
        let transport = Transport { request in
            #expect(request.url?.host == "www.codebuddy.cn")
            #expect(request.url?.path == "/v2/billing/meter/get-user-resource")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            let page = try #require(object["PageNumber"] as? Int)
            #expect(object["PageSize"] as? Int == 100)
            let count = page == 1 ? 100 : 1
            let accounts = (0 ..< count).map { index in
                ["PackageName": "第\(page)页第\(index)包", "CapacitySizePrecise": "", "CapacitySize": "10", "CapacityUsed": "3", "CapacityRemain": "7"]
            }
            let root: [String: Any] = ["data": ["Response": ["Data": ["Accounts": accounts]]]]
            return (200, String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self))
        }
        let snapshot = try await query(.workBuddy, transport: transport)
        #expect(transport.requests.count == 2)
        #expect(snapshot.creditPackages?.count == 101)
        #expect(Set(snapshot.creditPackages?.map(\.id) ?? []).count == 101)
        #expect(snapshot.balances.first?.total == 1010)
        #expect(snapshot.balances.first?.used == 303)
        #expect(snapshot.balances.first?.remaining == 707)
    }

    @Test func `WorkBuddy后续分页失败不能返回部分余额或改用摘要掩盖失败`() async throws {
        let transport = Transport { request in
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            if object["PageNumber"] as? Int == 2 { return (200, "{}") }
            let accounts = Array(repeating: ["CapacitySize": "10", "CapacityUsed": "3"], count: 100)
            let root: [String: Any] = ["data": ["Accounts": accounts]]
            return (200, String(decoding: try JSONSerialization.data(withJSONObject: root), as: UTF8.self))
        }
        do { _ = try await query(.workBuddy, transport: transport); Issue.record("分页失败不可返回第一批包的余额") }
        catch let error as QuotaAdapterError { if case .undecodable = error {} else { Issue.record("错误分类不符") } }
        #expect(transport.requests.count == 2)
        #expect(transport.requests.allSatisfy { $0.url?.path == "/v2/billing/meter/get-user-resource" })
    }

    @Test func `WorkBuddy空包是已用尽而缺失或损坏计数不是零`() async throws {
        let empty = try await query(.workBuddy, transport: Transport { _ in (200, #"{"data":{"Packages":[]}}"#) })
        #expect(empty.status == .exhausted && empty.balances.first?.remaining == 0)
        for text in [#"{"data":{}}"#, #"{"data":{"Packages":[{"CycleTotalCapacity":"100"}]}}"#, #"{"data":{"Packages":[{"CycleTotalCapacity":"NaN","CycleUsedCapacity":"1"}]}}"#, #"{"data":{"Packages":[{"CycleTotalCapacity":"100","CycleUsedCapacity":""}]}}"#] {
            do { _ = try await query(.workBuddy, transport: Transport { _ in (200, text) }); Issue.record("不能把不可读积分当作零或完整余额") }
            catch let error as QuotaAdapterError { if case .undecodable = error {} else { Issue.record("错误分类不符") } }
        }
        for status in [401, 403, 429] {
            let transport = Transport { _ in (status, "{}") }
            do { _ = try await query(.workBuddy, transport: transport); Issue.record("应传递鉴权或限流错误") }
            catch {}
            #expect(transport.requests.count == 1, "不能用另一条路径绕过鉴权或限流")
        }
    }

    @Test func `TraeCN统一额度使用与签到相同的权益积分和鉴权`() async throws {
        let transport = Transport { request in
            #expect(request.url?.absoluteString == "https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Cloud-IDE-JWT test-token")
            #expect(request.value(forHTTPHeaderField: "X-User-Region") == "cn")
            let body = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
            #expect(object["require_usage"] as? Bool == true)
            return (200, #"{"code":0,"user_entitlement_pack_list":[{"entitlement_base_info":{"quota":{"credits_limit":"100.25"}},"usage":{"credits_amount":"1.125"}},{"entitlement_base_info":{"quota":{"credits_limit":"10"}},"usage":{"credits_amount":"20"}}]}"#)
        }
        let snapshot = try await query(.trae, transport: transport)
        #expect(snapshot.kind == .balance)
        #expect(snapshot.balances.first?.total == Decimal(string: "110.25"))
        #expect(snapshot.balances.first?.used == Decimal(string: "21.125"))
        #expect(snapshot.balances.first?.remaining == Decimal(string: "99.125"))
        #expect(snapshot.windows.isEmpty)
        #expect(CheckInPlatform.traeCN.provider == .trae)
        #expect(CheckInPlatform.traeCN.accountID == "trae")
        #expect(CheckInPlatform.workBuddy.accountID == "workbuddy")
        #expect(CheckInPlatform.workBuddyAI.accountID == "workbuddy-ai")
    }

    @Test func `旧计费两种路径都可查且用量优先同前缀`() async throws {
        for prefix in ["v1/dashboard/billing", "dashboard/billing"] {
            let transport = Transport { request in
                if request.url?.path == "/gateway/" + prefix + "/subscription" { return (200, #"{"hard_limit_usd":"100.50"}"#) }
                if request.url?.path == "/gateway/" + prefix + "/usage" { return (200, #"{"total_usage":"1234"}"#) }
                return (404, "")
            }
            let snapshot = try #require(try await QuotaAdapters.probeOpenAIBilling(rootURL: URL(string: "https://relay.example/gateway")!, poolID: "key:test", provider: .openAICompatible, accountLabel: nil, apiKey: "test", transport: transport, now: now))
            #expect(snapshot.balances.first?.remaining == Decimal(string: "88.16"))
            #expect(snapshot.balances.first?.used == Decimal(string: "12.34"))
            #expect(transport.requests.last?.url?.path == "/gateway/" + prefix + "/usage")
        }
        let missingUsage = Transport { request in
            request.url?.path.hasSuffix("subscription") == true ? (200, #"{"hard_limit_usd":100}"#) : (404, "")
        }
        do { _ = try await QuotaAdapters.probeOpenAIBilling(rootURL: URL(string: "https://relay.example")!, poolID: "key:test", provider: .openAICompatible, accountLabel: nil, apiKey: "test", transport: missingUsage, now: now); Issue.record("没有用量时不能将100当成剩余余额") }
        catch {}
    }

    @Test func `积分查询失败保留上次金额包明细和成功时间`() async throws {
        for provider in [AgentProvider.workBuddy, .workBuddyAI, .trae] {
            let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: home) }
            let store = QuotaCacheStore(dataRoot: ApelinDataRoot(home: home))
            let account = QuotaAccountDescriptor(provider: provider, storeID: provider.storeID, accountLabel: nil,
                credentials: OAuthCredentials(access: "synthetic-token", refresh: "", expires: .max), usesAPIKey: false)
            let pool = QuotaPoolIdentity.poolID(provider: provider, storeID: account.storeID, credentials: account.credentials, usesAPIKey: false)
            let date = now.addingTimeInterval(-120)
            let package = AgentQuotaBalance(id: "old-package", unitLabel: "积分", total: 100, used: 88, remaining: 12,
                label: "合成奖励包", expiresAt: now.addingTimeInterval(1000))
            let old = AgentQuotaSnapshot(poolID: pool, provider: provider, kind: .balance, source: .activeAPI, status: .available,
                balances: [package], creditPackages: [package], updatedAt: date)
            store.upsertPool(PersistedQuotaPool(poolID: pool, snapshot: old, lastForegroundFetchAt: date))
            let coordinator = QuotaCoordinator(store: store, transport: Transport { _ in (503, "{}") }, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
            let failed = await coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false)
            #expect(failed.balances == old.balances)
            #expect(failed.creditPackages == old.creditPackages)
            #expect(failed.updatedAt == date)
            #expect(failed.status == .cooldown && failed.errorSummary != nil)
        }
    }

    @Test func `签到失效清除门禁但保留数字并定向刷新`() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = QuotaCacheStore(dataRoot: ApelinDataRoot(home: home))
        let old = AgentQuotaSnapshot(poolID: "oauth:trae", provider: .trae, kind: .balance, source: .activeAPI, status: .available,
            balances: [AgentQuotaBalance(id: "credits", unitLabel: "积分", remaining: 12)], updatedAt: now)
        store.upsertPool(PersistedQuotaPool(poolID: old.poolID, snapshot: old, lastForegroundFetchAt: now, lastManualRefreshAt: now,
            circuitBrokenUntil: now.addingTimeInterval(86400)))
        let passive = try #require(store.passiveGeneration(for: old.poolID))
        let transport = Transport { _ in (200, #"{"user_entitlement_pack_list":[{"entitlement_base_info":{"quota":{"credits_limit":100}},"usage":{"credits_amount":1}}]}"#) }
        let coordinator = QuotaCoordinator(store: store, transport: transport, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        await coordinator.invalidate(poolID: old.poolID)
        #expect(!store.isCurrentPassiveGeneration(passive, for: old.poolID))
        #expect(store.pool(for: old.poolID)?.snapshot.balances.first?.remaining == 12)
        let account = QuotaAccountDescriptor(provider: .trae, storeID: "trae", accountLabel: nil, credentials: OAuthCredentials(access: "token", refresh: "", expires: .max), usesAPIKey: false)
        let refreshed = await coordinator.snapshot(for: account, mode: .attentionGated, foreground: true, force: false)
        #expect(refreshed.balances.first?.remaining == 99)
        #expect(refreshed.status == .available && refreshed.manualDebounceUntil == nil)
        #expect(transport.requests.count == 1)
    }
}
