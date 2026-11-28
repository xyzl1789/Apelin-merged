import ApelinCore
import ApelinProtocol
import Foundation

// 独立编译此文件与生产存储；禁止测试意外连接设备后台或读取真实缓存。
extension ApelinService {
    static var app: ApelinService { fatalError("测试必须注入服务") }
}
extension DataFolder {
    static var app: DataFolder { fatalError("测试必须注入目录") }
}

private actor QuotaDisplayTransport: ApelinTransport {
    var accounts: [AgentAccount] = []
    var quotas: [AgentQuotaSnapshot] = []
    var failing = false
    var paused = false
    var quotaCalls = 0
    var quotaTargets: [AgentProviderQuotaRequest] = []
    var pending: [CheckedContinuation<Void, Never>] = []

    func configure(accounts: [AgentAccount], quotas: [AgentQuotaSnapshot], failing: Bool = false, paused: Bool = false) {
        self.accounts = accounts
        self.quotas = quotas
        self.failing = failing
        self.paused = paused
    }

    func resume() {
        let all = pending
        pending = []
        for continuation in all { continuation.resume() }
    }

    func call(_ request: WireRequest, descriptors: [OwnedDescriptor]) async throws -> (WireReply, [OwnedDescriptor]) {
        switch request.operation {
        case .agentAccountList:
            return (.success(request.requestID, AgentAccountListResponse(accounts: accounts)), [])
        case .agentProviderQuota:
            quotaCalls += 1
            quotaTargets.append(try request.decode(AgentProviderQuotaRequest.self))
            let captured = quotas
            let fail = failing
            if paused { await withCheckedContinuation { pending.append($0) } }
            if fail { throw CocoaError(.fileReadUnknown) }
            return (.success(request.requestID, AgentProviderQuotaResponse(quotas: captured)), [])
        default:
            preconditionFailure("不应调用旧余额线路或其他服务")
        }
    }
}

@main
struct ProviderBalanceStoreCheck {
    @MainActor
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = DataFolder(root: root)
        let transport = QuotaDisplayTransport()
        let service = ApelinService(transport: transport)
        let date = Date(timeIntervalSince1970: 100)
        let first = account("deepseek", pool: "key:one")
        let second = account("deepseek#2", pool: "key:two")
        let firstQuota = snapshot("key:one", amount: 12, date: date)
        let secondQuota = snapshot("key:two", amount: 99, date: date)
        await transport.configure(accounts: [first, second], quotas: [firstQuota, secondQuota])
        let store = ProviderBalanceStore(folder: folder, service: service)
        _ = try await store.loadQuotas()
        precondition(store.current(for: .deepSeek)?.amount == "12")
        precondition(store.current(for: .deepSeek, accountID: "deepseek#2")?.amount == "99")
        precondition(store.current(for: .deepSeek, accountID: "deepseek#3") == nil)
        let restored = ProviderBalanceStore(folder: folder, service: service)
        precondition(restored.balances == store.balances, "重启应恢复数字和成功时间")
        store.configurationChanged()
        precondition(store.balances == restored.balances, "配置成功但未确认换池前不能把有效数据清空")

        await transport.configure(accounts: [first, second], quotas: [])
        _ = try await store.loadQuotas()
        precondition(store.balances.count == 2 && store.balances.allSatisfy(\.stale))
        precondition(store.balances.allSatisfy { $0.updatedAt == date }, "空返回不是成功更新时间")
        await transport.configure(accounts: [first, second], quotas: [], failing: true)
        do { _ = try await store.loadQuotas(); preconditionFailure("应传递查询错误") }
        catch { precondition(store.balances.count == 2 && store.balances.allSatisfy { $0.updatedAt == date }) }

        let before = await transport.quotaCalls
        await transport.configure(accounts: [first, second], quotas: [snapshot("key:two", amount: 500, date: date.addingTimeInterval(60))], paused: true)
        let late = Task { try await store.loadQuotas(provider: .deepSeek, accountID: "deepseek#2") }
        await waitForCall(after: before, transport: transport)
        store.invalidate(provider: .deepSeek, accountID: "deepseek#2")
        await transport.configure(accounts: [first], quotas: [firstQuota])
        await transport.resume()
        do { _ = try await late.value; preconditionFailure("退出后的旧回包必须作废") }
        catch is CancellationError {}
        precondition(store.current(for: .deepSeek, accountID: "deepseek#2") == nil)
        precondition(store.current(for: .deepSeek)?.amount == "12", "退出第二账号不删除首账号")
        precondition(ProviderBalanceStore(folder: folder, service: service).balances.count == 1)

        let beforeChange = await transport.quotaCalls
        await transport.configure(accounts: [first], quotas: [snapshot("key:one", amount: 800, date: date.addingTimeInterval(60))], paused: true)
        let changed = Task { try await store.loadQuotas() }
        await waitForCall(after: beforeChange, transport: transport)
        let replacement = account("deepseek", pool: "key:replacement")
        await transport.configure(accounts: [replacement], quotas: [])
        await transport.resume()
        do { _ = try await changed.value; preconditionFailure("请求后绑定改变时必须拒绝旧池结果") }
        catch is CancellationError {}
        precondition(store.balances.isEmpty)
        precondition(ProviderBalanceStore(folder: folder, service: service).balances.isEmpty)

        // 不同账号确认共用同一池时，只查其中一个入口也同步另一账号；不同池不借数。
        let sharedSecond = account("deepseek#2", pool: "key:replacement")
        await transport.configure(accounts: [replacement, sharedSecond], quotas: [snapshot("key:replacement", amount: 42, date: date)])
        _ = try await store.loadQuotas(provider: .deepSeek, accountID: "deepseek#2")
        precondition(store.current(for: .deepSeek)?.amount == "42")
        precondition(store.current(for: .deepSeek, accountID: "deepseek#2")?.amount == "42")
        store.invalidate(provider: .deepSeek, accountID: "deepseek#2")
        precondition(store.current(for: .deepSeek)?.amount == "42", "退出共享池中的一个账号不删除其他绑定")

        // 签到后的定向刷新采用真实store ID，取消旧回包，附加账号与其它平台保留。
        let workBuddy = AgentAccount(provider: .workBuddy, method: .browser, signedIn: true, poolID: "oauth:workbuddy", storeID: "workbuddy")
        let workBuddySecond = AgentAccount(provider: .workBuddy, method: .browser, signedIn: true, poolID: "oauth:workbuddy#2", storeID: "workbuddy#2")
        func credits(_ pool: String, _ amount: Decimal, at: Date) -> AgentQuotaSnapshot {
            AgentQuotaSnapshot(poolID: pool, provider: .workBuddy, kind: .balance, source: .activeAPI, status: .available,
                balances: [AgentQuotaBalance(id: "credits", unitLabel: "积分", remaining: amount)], updatedAt: at)
        }
        await transport.configure(accounts: [workBuddy, workBuddySecond], quotas: [credits("oauth:workbuddy", 10, at: date), credits("oauth:workbuddy#2", 50, at: date)])
        _ = try await store.loadQuotas()
        let beforeReward = await transport.quotaCalls
        await transport.configure(accounts: [workBuddy, workBuddySecond], quotas: [credits("oauth:workbuddy", 11, at: date)], paused: true)
        let oldRewardRead = Task { try await store.loadQuotas(provider: .workBuddy, accountID: "workbuddy") }
        await waitForCall(after: beforeReward, transport: transport)
        await transport.configure(accounts: [workBuddy, workBuddySecond], quotas: [credits("oauth:workbuddy", 110, at: date.addingTimeInterval(60))])
        await store.refreshAfterCheckIn([CheckInResult(platform: .workBuddy, outcome: .claimed)])
        precondition(store.current(for: .workBuddy, accountID: "workbuddy")?.amount == "110")
        precondition(store.current(for: .workBuddy, accountID: "workbuddy#2")?.amount == "50")
        let rewardTarget = await transport.quotaTargets.last
        precondition(rewardTarget?.provider == .workBuddy && rewardTarget?.accountID == "workbuddy")
        precondition(rewardTarget?.mode == .attentionGated, "奖励刷新应复用后台刚查询的缓存，不再占用手动防抖")
        await transport.resume()
        do { _ = try await oldRewardRead.value; preconditionFailure("奖励前旧回包必须作废") }
        catch is CancellationError {}
        precondition(store.current(for: .workBuddy, accountID: "workbuddy")?.amount == "110")
        let beforeFailure = await transport.quotaCalls
        await store.refreshAfterCheckIn([CheckInResult(platform: .traeCN, outcome: .failed)])
        let afterFailure = await transport.quotaCalls
        precondition(afterFailure == beforeFailure, "失败签到不作废其它账号额度")

        // 单条损坏保留原始槽位，其余账号仍恢复、写回；整文件损坏另存不覆盖。
        let file = root.appendingPathComponent("QuotaDisplay.json")
        let valid = AgentQuotaDisplayRecord(accountID: "deepseek", snapshot: firstQuota)
        let validJSON = try JSONSerialization.jsonObject(with: JSONCoding.encode(valid))
        try JSONSerialization.data(withJSONObject: [validJSON, ["future": "保留未知字段"]]).write(to: file)
        let partlyBroken = ProviderBalanceStore(folder: folder, service: service)
        precondition(partlyBroken.balances.count == 1)
        partlyBroken.invalidate(provider: .deepSeek, accountID: "deepseek")
        let preserved = try JSONCoding.decode(PreservedList<AgentQuotaDisplayRecord>.self, from: Data(contentsOf: file))
        precondition(preserved.items.isEmpty && preserved.unreadable.count == 1)
        try Data("不是JSON".utf8).write(to: file)
        let broken = ProviderBalanceStore(folder: folder, service: service)
        precondition(broken.balances.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        precondition(names.contains { $0.hasPrefix("QuotaDisplay.json.unreadable-") })

        // 文件读不到（目录占位）时不允许下一次保存覆盖它。
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let unreadable = ProviderBalanceStore(folder: folder, service: service)
        unreadable.invalidate(provider: .deepSeek, accountID: nil)
        var isDirectory: ObjCBool = false
        precondition(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        print("通过：新额度线路、账号隔离、重启恢复、空值/失败保值、退出/换池晚回包及损坏缓存保护")
    }

    private static func account(_ id: String, pool: String) -> AgentAccount {
        AgentAccount(provider: .deepSeek, method: .apiKey, signedIn: true, poolID: pool, storeID: id)
    }

    private static func snapshot(_ pool: String, amount: Decimal, date: Date) -> AgentQuotaSnapshot {
        AgentQuotaSnapshot(poolID: pool, provider: .deepSeek, kind: .balance, source: .activeAPI, status: .available,
            balances: [AgentQuotaBalance(id: "USD", currency: "USD", remaining: amount)], updatedAt: date)
    }

    private static func waitForCall(after count: Int, transport: QuotaDisplayTransport) async {
        for _ in 0..<2_000 {
            if await transport.quotaCalls > count { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("额度请求没有进入等待点")
    }
}
