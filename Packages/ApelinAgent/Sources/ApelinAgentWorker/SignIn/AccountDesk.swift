import ApelinAgent
import ApelinCore
import ApelinProtocol
import Dispatch
import Foundation
import KWWKAI
import os

/// Where a sign-in's events go: the host's task, as `WorkerContext` sends
/// them. A test records them instead.
public struct SignInReporter: Sendable {
    public var emit: @Sendable (TaskID, String, ApelinCore.JSONValue?) -> Void
    public var finish: @Sendable (TaskID, TaskState, String?) -> Void

    public init(
        emit: @escaping @Sendable (TaskID, String, ApelinCore.JSONValue?) -> Void,
        finish: @escaping @Sendable (TaskID, TaskState, String?) -> Void,
    ) {
        self.emit = emit
        self.finish = finish
    }

    public init(context: WorkerContext) {
        self.init(
            emit: { context.emit($0, $1, $2) },
            finish: { context.finish($0, $1, message: $2) },
        )
    }
}

/// apelin-agent's accounts: the `credential-import` instance signs in,
/// lists and signs out here, against the keychain the sessions read.
///
/// A sign-in is kwwk's own flow (`SignInLogin`), run in this process with
/// callbacks that turn what the user must see into task events — a device
/// code, a page to open, the fields of a key — and nothing else. What comes
/// back from the provider, and what the user types, goes into the store and
/// is never emitted or logged. Only the app's explicit configuration editor
/// can read a saved API key back through `apiConfiguration`. One sign-in runs at a time: a new
/// one ends the old one `cancelled` first, so a loopback port is free again.
public actor AccountDesk {
    private let store: any CredentialSource
    private let login: SignInLogin
    private let listener: OAuthLoopbackFactory
    private let timeoutSeconds: Double
    private let verifyKey: @Sendable (AgentProvider, OAuthCredentials, String?) async throws -> Void
    private let quotaTransport: any QuotaHTTPTransport
    private var quotaCoordinators: [URL: QuotaCoordinator] = [:]
    private var keyVerification: (run: SignInRun, task: Task<Void, Error>)?
    private var running: SignInRun?
    /// 退出先递增代次；网络返回后只接受同一代账号的结果。
    private var accountGenerations: [String: UInt64] = [:]
    private var signingOut: Set<String> = []
    /// 同账号写入串行；退出等待已开始的钥匙串写入完成后再删除。
    private var credentialWrites: [String: (id: UUID, task: Task<Void, Error>)] = [:]
    /// One balance lookup at a time: a second caller joins the request the
    /// first one started, rather than asking every provider twice.
    private var balanceInFlight: Task<AgentProviderBalancesResponse, Error>?
    /// 本进程已检查过退役服务商的登录凭据。
    private var retiredSignInsLookedFor = false
    /// 签到同一时间只跑一遍：自动签到与设置页的手动签到撞上时后者等前者的结果。
    private var checkInInFlight: Task<AgentCheckInResponse, Error>?

    public init(
        store: any CredentialSource,
        login: @escaping SignInLogin = KWWKSignIn.login,
        listener: @escaping OAuthLoopbackFactory = AccountDesk.nioListener,
        timeoutSeconds: Double = Double(AgentSignInRequest.timeoutSeconds),
        verifyKey: @escaping @Sendable (AgentProvider, OAuthCredentials, String?) async throws -> Void = ProviderKeyVerification.verify,
        quotaTransport: any QuotaHTTPTransport = URLSessionQuotaTransport.shared,
    ) {
        self.store = store
        self.login = login
        self.listener = listener
        self.timeoutSeconds = timeoutSeconds
        self.verifyKey = verifyKey
        self.quotaTransport = quotaTransport
    }

    /// 删除应用已不再提供的服务商凭据。
    /// 删除失败时在下一次账号列表请求中重试；日志只记录存储 ID，不记录凭据内容。
    func forgetRetiredSignIns() async {
        guard !retiredSignInsLookedFor else { return }
        retiredSignInsLookedFor = true
        let stored = Set(await store.providerIds())
        var allRemoved = true
        for retired in AgentProvider.retired {
            let ids = ([retired.storeID] + (2 ... AccountIDs.maximum).map { AgentAccountID.extra(retired.storeID, $0) })
                .filter { stored.contains($0) }
            for id in ids {
                do {
                    try await store.remove(id)
                    Self.log.warning("已移除退役服务商的登录凭据 \(id, privacy: .public)")
                } catch {
                    allRemoved = false
                    Self.log.error("无法移除退役服务商的登录凭据 \(id, privacy: .public)")
                }
            }
        }
        if !allRemoved { retiredSignInsLookedFor = false }
    }

    /// kwwk's NIO listener with Apelin's own pages.
    public static let nioListener: OAuthLoopbackFactory = { host, port, path in
        try OAuthCallbackServer(
            port: port,
            path: path,
            successHTML: PasteableLoopback.successPage,
            errorHTML: PasteableLoopback.errorPage,
            redirectHost: host,
            surfacesProviderErrors: true,
        )
    }

    // MARK: - Accounts

    /// Says in the device log what an account list cost, per account and in
    /// all. Store ids, counts and milliseconds only: never a credential, never
    /// an endpoint's key.
    private static let log = Logger(subsystem: "wiki.qaq.apelin", category: "Accounts")

    /// Whole milliseconds since a `DispatchTime.now().uptimeNanoseconds` stamp.
    static func milliseconds(since start: UInt64) -> Int {
        Int((DispatchTime.now().uptimeNanoseconds &- start) / 1_000_000)
    }

    /// Every provider, in kwwk's order.
    ///
    /// `onlyExtraModels` is a narrower list for a picker: each signed-in
    /// account answers with the models it was asked for and nothing else, so
    /// the composer does not carry every provider's whole catalogue. What it
    /// was asked for is what it answers — the app's own list is where a live
    /// provider's models come from (WorkBuddy's config, a relay's endpoint),
    /// and those include models no bundled catalog names — so nothing is cut
    /// against a catalog here, and an account asked for no model carries none
    /// and reads no catalog at all: its levels, tiers and capabilities are
    /// trimmed to the models it names, not left holding the whole catalogue's.
    /// Absent or false keeps the whole list, exactly as before, which is what
    /// Settings and onboarding draw.
    public func list(
        extraModels: [String: [String]] = [:],
        onlyExtraModels: Bool = false,
    ) async -> AgentAccountListResponse {
        let started = DispatchTime.now().uptimeNanoseconds
        await forgetRetiredSignIns()
        let stored = Set(await store.providerIds())
        var accounts: [AgentAccount] = []
        accounts.reserveCapacity(AgentProvider.signInOrder.count)
        for listed in AgentProvider.signInOrder {
            for provider in Self.listed(listed, stored: stored) {
                let requested = extraModels[provider.rawValue] ?? []
                let others = Array(provider.signInMethods.dropFirst())
                let ids = Self.accountIDs(of: provider, stored: stored)
                guard !ids.isEmpty else {
                    accounts.append(AgentAccount(
                        provider: provider,
                        method: provider.signInMethod,
                        alternativeMethods: others.isEmpty ? nil : others,
                        signedIn: false,
                        storeID: provider.storeID,
                    ))
                    continue
                }
                // 每份凭据各占一行，无法解码的条目仍可在设置中退出。
                for id in ids {
                    let accountStarted = DispatchTime.now().uptimeNanoseconds
                    var account = AgentAccount(
                        provider: provider,
                        method: provider.signInMethod,
                        alternativeMethods: others.isEmpty ? nil : others,
                        signedIn: true,
                        storeID: id,
                    )
                    if let credentials = try? await store.credentials(for: id) {
                        account.account = Self.accountLabel(provider, credentials)
                        account.expiresAt = Self.lapses(credentials)
                        let models = onlyExtraModels
                            ? Self.narrowed(requested)
                            : Self.widened(requested, provider: provider, credentials: credentials)
                        account.models = models
                        // 窄列表未指定模型时不读目录，指定时也只携带这些模型的字段。
                        if !models.isEmpty || !onlyExtraModels {
                            let facts = ProviderModels.catalogFacts(provider, credentials: credentials, models: models)
                            let tiers = ProviderModels.serviceTiers(provider, credentials: credentials)
                            if onlyExtraModels {
                                let asked = Set(models)
                                account.reasoningEfforts = facts.reasoningEfforts.filter { asked.contains($0.key) }
                                account.serviceTiers = tiers.filter { asked.contains($0.key) }
                                account.capabilities = facts.capabilities
                            } else {
                                account.reasoningEfforts = facts.reasoningEfforts
                                account.serviceTiers = tiers
                                account.capabilities = facts.capabilities
                            }
                        }
                        let usesAPIKey = ProviderModels.usesAPIKey(provider, credentials: credentials)
                        account.usesAPIKey = usesAPIKey ? true : nil
                        account.poolID = QuotaPoolIdentity.poolID(
                            provider: provider, storeID: id,
                            credentials: credentials, usesAPIKey: usesAPIKey,
                        )
                    }
                    accounts.append(account)
                    Self.log.notice(
                        "已列出 \(id, privacy: .public)，耗时 \(Self.milliseconds(since: accountStarted), privacy: .public) 毫秒：\(account.models?.count ?? 0, privacy: .public) 个模型，目录 \(account.capabilities == nil ? 0 : 1, privacy: .public)",
                    )
                }
            }
        }
        Self.log.notice(
            "listed \(accounts.count, privacy: .public) providers in \(Self.milliseconds(since: started), privacy: .public) ms, \(onlyExtraModels ? "named" : "all", privacy: .public) models",
        )
        return AgentAccountListResponse(accounts: accounts)
    }

    /// What the list shows for `provider`: itself, and for the
    /// OpenAI-compatible login every endpoint signed in to, in number
    /// order, then one more that is not, so there is always one to add
    /// (#60). The one to add is the first endpoint while that is free,
    /// else the lowest number no endpoint has.
    static func listed(_ provider: AgentProvider, stored: Set<String>) -> [AgentProvider] {
        guard provider == .openAICompatible else { return [provider] }
        let bases = Set(stored.map(AccountIDs.base(of:)))
        let numbers = Set(bases.compactMap(CredentialProviderID.endpointNumber)).sorted()
        var endpoints = numbers.map(AgentProvider.openAICompatibleEndpoint)
        if bases.contains(provider.storeID) {
            endpoints.insert(provider, at: 0)
            if let free = AgentProvider.endpointNumbers.first(where: { !numbers.contains($0) }) {
                endpoints.append(.openAICompatibleEndpoint(free))
            }
        } else {
            endpoints.append(provider)
        }
        return endpoints
    }

    /// 验证账号属于该服务商且格式规范，验证前不触碰凭据。
    static func validatedAccountID(_ requested: String?, for provider: AgentProvider) throws -> String {
        let id = AccountIDs.resolved(requested, for: provider)
        guard requested != "", AccountIDs.belongs(id, to: provider) else {
            throw ApelinError(.badRequest, "账号标识无效或不属于所选服务商。")
        }
        return id
    }

    /// 首账号在前，附加账号按数字排序；不把未知存储条目归给别的服务商。
    static func accountIDs(of provider: AgentProvider, stored: Set<String>) -> [String] {
        ([provider.storeID] + (2 ... AccountIDs.maximum).map { AccountIDs.extra(provider, $0) })
            .filter { stored.contains($0) }
    }

    /// The whole list with the caller's own models added: what every account
    /// list answered before there was a narrower one.
    static func widened(
        _ extraModels: [String],
        provider: AgentProvider,
        credentials: OAuthCredentials,
    ) -> [String] {
        var models = ProviderModels.list(provider, credentials: credentials)
        var known = Set(models)
        for id in extraModels where known.insert(id).inserted {
            models.append(id)
        }
        return models
    }

    /// Only the caller's own models, in its order, once each: what a picker
    /// asks for is what it gets, including a model no bundled catalog knows —
    /// a live provider's own list is the app's to name, not this worker's to
    /// second-guess.
    static func narrowed(_ extraModels: [String]) -> [String] {
        var seen: Set<String> = []
        return extraModels.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// The explicit app-only editor reads the saved key directly; no task is
    /// created and neither account listings nor sign-in events expose it.
    public func apiConfiguration(
        for provider: AgentProvider,
        accountID: String? = nil,
    ) async throws -> AgentAPIConfigurationResponse {
        let accountID = try Self.validatedAccountID(accountID, for: provider)
        guard let credentials = try await store.credentials(for: accountID) else {
            throw ApelinError(.notFound, "没有找到已保存的 API 配置，请先登录该供应商。")
        }
        guard ProviderModels.usesAPIKey(provider, credentials: credentials) else {
            throw ApelinError(.denied, "该账户不使用可编辑的 API 密钥。")
        }
        var values: [String: String] = [:]
        for field in provider.keyFields {
            if field.field == .apiKey {
                values[field.field.rawValue] = credentials.access
            } else if case let .string(value)? = credentials.extras[field.field.rawValue] {
                values[field.field.rawValue] = value
            } else if let value = field.defaultValue {
                values[field.field.rawValue] = value
            }
        }
        return AgentAPIConfigurationResponse(values: values)
    }

    /// Every signed-in account whose endpoint publishes a balance, read once
    /// and cached in the data folder. Only short, redacted facts cross back to
    /// the app: the amount as decimal text, a unit and a failure class. A
    /// provider with no balance adapter is absent, never a zero.
    public func providerBalances(force: Bool, home: URL) async throws -> AgentProviderBalancesResponse {
        if let running = balanceInFlight {
            return try await running.value
        }
        // 先把密钥读进 actor 内的数组：查询服务只拿到值，不捕获 actor 状态。
        var accounts: [(String, OAuthCredentials)] = []
        for id in await store.providerIds() {
            guard let saved = try await store.credentials(for: id) else { continue }
            accounts.append((id, saved))
        }
        os.Logger(subsystem: "wiki.qaq.apelin", category: "Balance")
            .info("worker 收到余额查询：force=\(force, privacy: .public)，凭据 \(accounts.map(\.0).joined(separator: ","), privacy: .public)")
        let task = Task<AgentProviderBalancesResponse, Error> {
            try await ProviderBalanceService.lookup(
                force: force,
                accounts: accounts,
                dataRoot: ApelinDataRoot(home: home).url,
            )
        }
        balanceInFlight = task
        defer { balanceInFlight = nil }
        return try await task.value
    }

    /// 给已登录的 WorkBuddy / Trae CN / Qoder CN 账号做当天签到。和余额一样
    /// 先把凭据读成值，服务只拿值；当天问过的平台用 worker 里的缓存，`force`
    /// 才重新打服务端。领取结果不可撤销，因此只有 App 明确要求时才真的领取。
    public func checkIn(platforms: [CheckInPlatform], force: Bool, home: URL) async throws -> AgentCheckInResponse {
        if let running = checkInInFlight {
            return try await running.value
        }
        var accounts: [(String, OAuthCredentials)] = []
        for id in await store.providerIds() {
            guard CheckInPlatform.allCases.contains(where: { CheckInService.storeID($0) == id }),
                  let saved = try await store.credentials(for: id) else { continue }
            accounts.append((id, saved))
        }
        os.Logger(subsystem: "wiki.qaq.apelin", category: "CheckIn")
            .info("worker 收到签到：force=\(force, privacy: .public)，平台 \(platforms.map(\.rawValue).joined(separator: ","), privacy: .public)，凭据 \(accounts.map(\.0).joined(separator: ","), privacy: .public)")
        let task = Task<AgentCheckInResponse, Error> {
            await CheckInService.run(platforms: platforms, force: force, accounts: accounts, home: home)
        }
        checkInInFlight = task
        defer { checkInInFlight = nil }
        return try await task.value
    }

    /// 退出指定账号；未指定时退出服务商的全部账号。损坏凭据也必须能删除。
    public func signOut(
        _ provider: AgentProvider,
        accountID: String? = nil,
        dataRoot: ApelinDataRoot? = nil,
    ) async throws {
        let selected = try accountID.map { try Self.validatedAccountID($0, for: provider) }
        let invalidated = selected.map { [$0] }
            ?? ([provider.storeID] + (2 ... AccountIDs.maximum).map { AccountIDs.extra(provider, $0) })
        guard signingOut.isDisjoint(with: invalidated) else {
            throw ApelinError(.conflict, "所选账号正在退出，请稍后重试。")
        }
        // 在第一次 await 前作废所有目标，尚未落盘的登录也包含在内。
        for id in invalidated { accountGenerations[id, default: 0] &+= 1 }
        signingOut.formUnion(invalidated)
        defer { signingOut.subtract(invalidated) }
        if let previous = running, invalidated.contains(previous.accountID) {
            previous.cancel()
            if keyVerification?.run === previous {
                keyVerification?.task.cancel()
                keyVerification = nil
            }
            running = nil
        }
        for id in invalidated {
            if let write = credentialWrites[id] { _ = await write.task.result }
        }
        let stored = Set(await store.providerIds())
        let ids = invalidated.filter { stored.contains($0) }
        var removedPools: Set<String> = []
        var removalError: Error?
        for id in ids {
            // 解码失败不影响删除；可读凭据则用于找出需要清理的共享池。
            let credentials = try? await store.credentials(for: id)
            do {
                try await store.remove(id)
                removedPools.insert("oauth:\(id)")
                if let credentials {
                    removedPools.insert(QuotaPoolIdentity.poolID(
                        provider: provider, storeID: id, credentials: credentials,
                        usesAPIKey: ProviderModels.usesAPIKey(provider, credentials: credentials),
                    ))
                }
            } catch {
                if removalError == nil { removalError = error }
            }
        }
        if let dataRoot {
            var sharedPools: Set<String> = []
            var unreadableRemaining = false
            for id in await store.providerIds() {
                guard let credentials = try? await store.credentials(for: id) else {
                    unreadableRemaining = true
                    continue
                }
                if let owner = AccountIDs.provider(of: id, among: Self.providersForStoredAccounts(id)) {
                    sharedPools.insert(QuotaPoolIdentity.poolID(
                        provider: owner, storeID: id, credentials: credentials,
                        usesAPIKey: ProviderModels.usesAPIKey(owner, credentials: credentials),
                    ))
                }
            }
            let cache = QuotaCacheStore(dataRoot: dataRoot)
            for pool in removedPools where !sharedPools.contains(pool) {
                // 剩余损坏条目可能仍共享此 key 池，无法判断时保留它。
                if pool.hasPrefix("key:"), unreadableRemaining { continue }
                if let coordinator = quotaCoordinators[dataRoot.url] {
                    await coordinator.forget(poolID: pool)
                } else {
                    cache.clearPool(poolID: pool)
                }
            }
        }
        if let removalError {
            throw ApelinError(.internal, "无法移除已保存的登录：\(removalError.localizedDescription)。请重试。")
        }
    }

    /// 动态端点也参与账号归属解析，不能只依赖 allCases 中的首端点。
    private static func providersForStoredAccounts(_ id: String) -> [AgentProvider] {
        let base = AccountIDs.base(of: id)
        if let number = CredentialProviderID.endpointNumber(base) {
            return [.openAICompatibleEndpoint(number)]
        }
        return AgentProvider.signInOrder
    }

    // MARK: - 服务商额度

    private func quotaCoordinator(for dataRoot: ApelinDataRoot) -> QuotaCoordinator {
        if let existing = quotaCoordinators[dataRoot.url] { return existing }
        let coordinator = QuotaCoordinator(store: QuotaCacheStore(dataRoot: dataRoot), transport: quotaTransport)
        quotaCoordinators[dataRoot.url] = coordinator
        return coordinator
    }

    public func quotas(
        _ request: AgentProviderQuotaRequest,
        dataRoot: ApelinDataRoot,
    ) async throws -> AgentProviderQuotaResponse {
        // 先验证定向请求，再做账号枚举或退役清理。
        let selected: (provider: AgentProvider, accountID: String)?
        if let accountID = request.accountID {
            guard let provider = request.provider else {
                throw ApelinError(.badRequest, "查询指定账号的额度时必须提供服务商。")
            }
            selected = (provider, try Self.validatedAccountID(accountID, for: provider))
        } else {
            selected = nil
        }
        let generations = accountGenerations
        await forgetRetiredSignIns()
        let stored = Set(await store.providerIds())
        var targets: [(provider: AgentProvider, accountID: String)] = []
        if let selected {
            if stored.contains(selected.accountID) { targets = [selected] }
        } else if let provider = request.provider {
            targets = Self.accountIDs(of: provider, stored: stored).map { (provider, $0) }
        } else {
            for listed in AgentProvider.signInOrder {
                for provider in Self.listed(listed, stored: stored) {
                    targets += Self.accountIDs(of: provider, stored: stored).map { (provider, $0) }
                }
            }
        }
        var descriptors: [QuotaAccountDescriptor] = []
        for (provider, accountID) in targets {
            let generation = generations[accountID, default: 0]
            guard isCurrent(accountID, generation: generation),
                  var credentials = try? await store.credentials(for: accountID),
                  isCurrent(accountID, generation: generation)
            else { continue }
            let usesAPIKey = ProviderModels.usesAPIKey(provider, credentials: credentials)
            if request.mode != .cachedOnly, !usesAPIKey,
               credentials.isExpired, !credentials.refresh.isEmpty
            {
                let refreshers: [any OAuthProvider]
                if let site = KimiSite.site(id: provider.storeID) {
                    refreshers = OAuthSubscriptions.refresher(
                        providerId: site.id,
                        kimiIdentity: KimiIdentity.identity(recordedIn: credentials),
                    ).map { [$0] } ?? []
                } else {
                    refreshers = KimiIdentity.refreshers(for: provider.storeID)
                }
                let manager = OAuthManager(source: store, providers: Self.scoped(
                    refreshers, accountID: accountID, provider: provider,
                ))
                if let freshAccess = try? await manager.apiKey(for: accountID), !freshAccess.isEmpty {
                    credentials = (try? await manager.credentials(for: accountID)) ?? credentials
                    guard isCurrent(accountID, generation: generation) else { continue }
                    credentials.access = freshAccess
                    // OAuthManager 只更新自身内存；持久化必须再次验证账号代次。
                    try? await persist(credentials, accountID: accountID, generation: generation)
                }
            }
            guard isCurrent(accountID, generation: generation) else { continue }
            descriptors.append(QuotaAccountDescriptor(
                provider: provider, storeID: accountID,
                accountLabel: Self.accountLabel(provider, credentials),
                credentials: credentials, usesAPIKey: usesAPIKey,
            ))
        }
        descriptors.removeAll { !isCurrent($0.storeID, generation: generations[$0.storeID, default: 0]) }
        let snapshots = await quotaCoordinator(for: dataRoot).snapshots(
            for: descriptors, mode: request.mode, foreground: request.foreground, force: request.force,
        )
        // 等待网络期间账号可能退出；迟到快照也不得返回给旧账号请求。
        let current = zip(descriptors, snapshots).compactMap { descriptor, snapshot in
            isCurrent(descriptor.storeID, generation: generations[descriptor.storeID, default: 0])
                ? snapshot : nil
        }
        return AgentProviderQuotaResponse(quotas: current)
    }

    /// 附加账号使用同一刷新流程，但读写自己的凭据 ID。
    static func scoped(
        _ refreshers: [any OAuthProvider],
        accountID: String,
        provider: AgentProvider,
    ) -> [any OAuthProvider] {
        guard accountID != provider.storeID else { return refreshers }
        return refreshers.map { AccountRefresher(base: $0, id: accountID) }
    }

    /// Endpoint host shown as the account label for API-key and AirRelay accounts.
    static func accountLabel(_ provider: AgentProvider, _ credentials: OAuthCredentials) -> String? {
        if case let .string(base)? = credentials.extras[AgentSignInField.baseURL.rawValue],
           let host = URLComponents(string: base)?.host
        {
            return host
        }
        guard provider.signInMethod == .apiKey,
              let base = provider.keyFields.first(where: { $0.field == .baseURL })?.defaultValue
        else { return nil }
        return URLComponents(string: base)?.host
    }

    /// Only a sign-in that cannot renew itself lapses for the user: a
    /// refresh token renews it, and an API key is stored as never expiring.
    static func lapses(_ credentials: OAuthCredentials) -> Date? {
        guard credentials.refresh.isEmpty, credentials.expires != .max else { return nil }
        return Date(timeIntervalSince1970: Double(credentials.expires) / 1000)
    }

    // MARK: - Signing in

    /// Accepts the task and starts the flow; its events and final `state`
    /// follow the reply. A method the provider does not offer is refused
    /// before anything starts, and the sign-in still running goes on.
    public func start(_ request: AgentSignInRequest, taskID: TaskID, reporter: SignInReporter) async throws {
        let method = request.method ?? request.provider.signInMethod
        guard request.provider.signInMethods.contains(method) else {
            throw ApelinError(
                .badRequest,
                "\(request.provider.rawValue) does not support \(method.rawValue) sign-in. Choose another method.",
            )
        }
        let accountID = try Self.validatedAccountID(request.accountID, for: request.provider)
        let generation = accountGenerations[accountID, default: 0]
        guard isCurrent(accountID, generation: generation) else { throw CancellationError() }
        await stopRunning()
        guard isCurrent(accountID, generation: generation) else { throw CancellationError() }
        let run = SignInRun(taskID: taskID, provider: request.provider, accountID: accountID, method: method, generation: generation)
        running = run
        run.work = Task { [weak self] in
            await self?.perform(run, reporter: reporter)
        }
    }

    public func cancel(_ taskID: TaskID) -> Bool {
        guard let running, running.taskID == taskID else { return false }
        keyVerification?.task.cancel()
        running.cancel()
        return true
    }

    /// What the user supplied, for the sign-in that asked for it. A value
    /// that will not do is refused naming the field; the flow goes on
    /// waiting for a better one.
    public func respond(_ request: AgentSignInRespondRequest) async throws {
        guard let run = running, run.taskID == request.taskID else {
            throw ApelinError(
                .notFound,
                "登录 \(request.taskID) 已不在等待响应。请重新开始登录。",
            )
        }
        var values: [AgentSignInField: String] = [:]
        for (key, value) in request.values {
            guard let field = AgentSignInField(rawValue: key) else {
                throw ApelinError(.badRequest, "\(key) is not a sign-in field")
            }
            values[field] = value
        }
        guard running === run, !run.isCancelled, !Task.isCancelled else { throw CancellationError() }
        switch run.method {
        case .deviceCode:
            throw ApelinError(
                .badRequest,
                "请在供应商网站上完成登录。Apelin 中无需响应。",
            )
        case .browser:
            guard values.count == 1, let text = values[.callbackURL] else {
                throw ApelinError(.badRequest, "浏览器登录只接受 \(AgentSignInField.callbackURL.rawValue)")
            }
            guard let loopback = run.loopback else {
                throw ApelinError(.conflict, "\(run.provider.rawValue) is not waiting for a pasted address")
            }
            try loopback.paste(text)
        case .apiKey:
            guard keyVerification == nil else {
                throw ApelinError(.conflict, "供应商验证已在进行中。")
            }
            let accepted = try Self.validated(
                values,
                for: run.provider,
                requiresDefaultModel: request.verifyModel != false,
            )
            guard request.verifyModel != false else {
                try run.deliver(accepted)
                return
            }
            let credentials = Self.apiKeyCredentials(accepted)
            let work = Task { try await verifyKey(run.provider, credentials, nil) }
            keyVerification = (run, work)
            defer {
                if keyVerification?.run === run {
                    keyVerification = nil
                }
            }
            do {
                try await work.value
            } catch ProviderEndpointRequirement.responsesOnly
                where Self.canSwitchFormat(run.provider, accepted)
            {
                // 站点停用了 Chat Completions，只开 Responses API。用户选哪个
                // 格式都不该决定成败：换成 Responses 再验一次，并把换过的
                // 格式随登录一起存下来，之后真实会话也用它。
                let switched = Self.switching(accepted, to: .responses)
                let retry = Task { try await verifyKey(run.provider, Self.apiKeyCredentials(switched), nil) }
                keyVerification = (run, retry)
                try await retry.value
                guard running === run, !run.isCancelled else { throw CancellationError() }
                try run.deliver(switched)
                return
            }
            guard running === run, !run.isCancelled else { throw CancellationError() }
            try run.deliver(accepted)

        }
    }

    /// The models the provider lists and, for an API-key account, the
    /// limits each of them and of `limitsFor` has when the user sets none.
    public func models(
        for provider: AgentProvider,
        accountID: String? = nil,
        limitsFor asked: [String] = [],
    ) async throws -> AgentModelListResponse {
        let accountID = try Self.validatedAccountID(accountID, for: provider)
        guard let credentials = try await store.credentials(for: accountID) else {
            throw ApelinError(.notFound, "请先登录该供应商。")
        }
        let models = try await ProviderModels.fetch(provider, credentials: credentials)
        guard ProviderModels.usesAPIKey(provider, credentials: credentials) else {
            return AgentModelListResponse(models: models)
        }
        let limits = await ProviderModels.automaticLimits(
            provider,
            credentials: credentials,
            models: models + asked.prefix(AgentModelListRequest.maximumLimitsAsked),
        )
        return AgentModelListResponse(models: models, limits: limits)
    }

    public func activateModels(
        _ request: AgentModelActivateRequest,
        taskID: TaskID,
        reporter: SignInReporter,
    ) async throws {
        guard !request.models.isEmpty, request.models.count <= 64,
              request.models.allSatisfy({ !$0.isEmpty && $0.count <= 256 && !$0.contains(where: \.isNewline) })
        else { throw ApelinError(.badRequest, "请选择 1 到 64 个有效模型 ID。") }
        let accountID = try Self.validatedAccountID(request.accountID, for: request.provider)
        let generation = accountGenerations[accountID, default: 0]
        guard isCurrent(accountID, generation: generation),
              let credentials = try await store.credentials(for: accountID)
        else { throw ApelinError(.notFound, "请先登录该供应商。") }
        guard isCurrent(accountID, generation: generation) else { throw CancellationError() }
        let usesAPIKey = ProviderModels.usesAPIKey(request.provider, credentials: credentials)
        guard usesAPIKey || request.provider == .githubCopilot else {
            throw ApelinError(.badRequest, "该 OAuth 供应商不需要模型验证。")
        }
        await stopRunning()
        guard isCurrent(accountID, generation: generation) else { throw CancellationError() }
        let run = SignInRun(taskID: taskID, provider: request.provider, accountID: accountID, method: .apiKey, generation: generation)
        running = run
        run.work = Task { [weak self, verifyKey] in
            var currentModel = ""
            do {
                var verified = credentials
                for model in request.models {
                    currentModel = model
                    try Task.checkCancellation()
                    if usesAPIKey {
                        do {
                            try await verifyKey(request.provider, verified, model)
                        } catch ProviderEndpointRequirement.responsesOnly
                            where Self.canSwitchFormat(request.provider, verified)
                        {
                            // 站点只开 Responses API。换成 Responses 存下来再验，
                            // 之后真实会话也用这个格式，不必让用户手选。
                            try Task.checkCancellation()
                            verified = Self.switching(verified, to: .responses)
                            try await verifyKey(request.provider, verified, model)
                            try await self?.save(verified, for: run)
                        }
                    } else {
                        try await KWWKSignIn.enableCopilotModels(verified, models: [model])
                    }
                    try Task.checkCancellation()
                    reporter.emit(taskID, "modelVerified", .object(["model": .string(model)]))
                }
                reporter.finish(taskID, .succeeded, nil)
            } catch {
                reporter.finish(
                    taskID,
                    run.isCancelled ? .cancelled : .failed,
                    run.isCancelled ? nil : "无法验证模型 \(currentModel)。请检查模型 ID 与供应商访问权限后重试。",
                )
            }
            await self?.clear(run)
        }
    }

    private func isCurrent(_ accountID: String, generation: UInt64) -> Bool {
        !Task.isCancelled && !signingOut.contains(accountID)
            && accountGenerations[accountID, default: 0] == generation
    }

    /// 只有仍在运行且代次有效的登录或模型验证可以保存凭据。
    private func save(_ credentials: OAuthCredentials, for run: SignInRun) async throws {
        guard running === run, !run.isCancelled,
              isCurrent(run.accountID, generation: run.generation)
        else { throw CancellationError() }
        try Task.checkCancellation()
        try await persist(credentials, accountID: run.accountID, generation: run.generation)
    }

    private func persist(_ credentials: OAuthCredentials, accountID: String, generation: UInt64) async throws {
        guard isCurrent(accountID, generation: generation) else { throw CancellationError() }
        let previous = credentialWrites[accountID]?.task
        let id = UUID()
        let write = Task { [store] in
            if let previous { _ = await previous.result }
            try await store.store(credentials, for: accountID)
        }
        credentialWrites[accountID] = (id, write)
        defer {
            if credentialWrites[accountID]?.id == id { credentialWrites[accountID] = nil }
        }
        try await write.value
        guard isCurrent(accountID, generation: generation) else { throw CancellationError() }
    }

    private func clear(_ run: SignInRun) {
        if running === run {
            running = nil
        }
    }

    private func stopRunning() async {
        guard let previous = running else { return }
        previous.cancel()
        if let verification = keyVerification {
            verification.task.cancel()
            _ = await verification.task.result
        }
        await previous.work?.value
    }

    /// 只有 OpenAI 兼容端点能在两种接口格式之间切换：别的供应商的
    /// 传输是固定的。
    static func canSwitchFormat(_ provider: AgentProvider, _ values: [AgentSignInField: String]) -> Bool {
        guard CredentialProviderID.isOpenAICompatible(provider.storeID) else { return false }
        return values[.apiFormat] != AgentAPIFormat.responses.rawValue
    }

    /// 已保存的凭据同上：读出它的接口格式，看还能不能换。
    static func canSwitchFormat(_ provider: AgentProvider, _ credentials: OAuthCredentials) -> Bool {
        guard CredentialProviderID.isOpenAICompatible(provider.storeID) else { return false }
        let saved: String? = if case let .string(value)? = credentials.extras[AgentSignInField.apiFormat.rawValue] {
            value
        } else {
            nil
        }
        return saved != AgentAPIFormat.responses.rawValue
    }

    /// 同一个端点，接口格式换成 `format`：其余字段原样保留。
    static func switching(
        _ values: [AgentSignInField: String],
        to format: AgentAPIFormat,
    ) -> [AgentSignInField: String] {
        var switched = values
        switched[.apiFormat] = format.rawValue
        return switched
    }

    /// 已保存的凭据只改接口格式这一项。
    static func switching(
        _ credentials: OAuthCredentials,
        to format: AgentAPIFormat,
    ) -> OAuthCredentials {
        var switched = credentials
        switched.extras[AgentSignInField.apiFormat.rawValue] = .string(format.rawValue)
        return switched
    }

    /// The key and its extras, each checked on its own and refused by name
    /// alone: an error never quotes what was typed.
    static func validated(
        _ values: [AgentSignInField: String],
        for provider: AgentProvider,
        requiresDefaultModel: Bool = true,
    ) throws -> [AgentSignInField: String] {
        let fields = provider.keyFields
        for field in values.keys where !fields.contains(where: { $0.field == field }) {
            throw ApelinError(.badRequest, "\(provider.rawValue) does not ask for \(field.rawValue)")
        }
        let azure = CredentialProviderID.isOpenAICompatible(provider.storeID)
            && values[.azure]?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        var accepted: [AgentSignInField: String] = [:]
        for field in fields {
            let value = (values[field.field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if value.isEmpty {
                if field.required, field.field != .defaultModel || requiresDefaultModel {
                    throw ApelinError(.badRequest, Self.missing(field.field))
                }
                continue
            }
            switch field.field {
            case .apiKey:
                guard value.count <= 4096, !value.unicodeScalars.contains(where: Self.isSpaceOrControl) else {
                    throw ApelinError(.badRequest, "请输入不含空格或换行的有效 API 密钥。")
                }
            case .baseURL:
                guard value.count <= 2048, let url = URLComponents(string: value),
                      let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
                      url.host?.isEmpty == false, url.user == nil, url.password == nil,
                      url.fragment == nil,
                      (azure ? (scheme == "https" && Self.acceptsAzureQuery(url)) : url.query == nil)
                else {
                    throw ApelinError(.badRequest, "请输入有效的 HTTP 或 HTTPS 地址。")
                }
            case .defaultModel:
                guard value.count <= 256, !value.unicodeScalars.contains(where: Self.isSpaceOrControl) else {
                    throw ApelinError(.badRequest, "请输入不含空格或换行的有效模型 ID。")
                }
            case .apiFormat:
                guard AgentAPIFormat(rawValue: value) != nil else {
                    throw ApelinError(.badRequest, "请选择有效的接口格式。")
                }
            case .appendV1, .azure:
                guard value == "true" || value == "false" else {
                    throw ApelinError(.badRequest, "请选择有效的开关值。")
                }
            case .customUserAgent:
                // A real UA often carries spaces and parentheses
                // (`claude-cli/1.0 (iOS)`); only control characters and an
                // absurd length are refused. Nothing here is logged.
                guard value.count <= 512, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                    throw ApelinError(.badRequest, "请输入不含换行或控制字符的有效 User-Agent。")
                }
            case .imageEndpointMode:
                guard AgentImageEndpointMode(rawValue: value) != nil else {
                    throw ApelinError(.badRequest, "请选择有效的图像生成端点。")
                }
            case .callbackURL:
                throw ApelinError(.badRequest, "\(provider.rawValue) does not ask for \(field.field.rawValue)")
            }
            accepted[field.field] = value
        }
        return accepted
    }

    private static func acceptsAzureQuery(_ url: URLComponents) -> Bool {
        guard url.query != nil else { return true }
        guard let items = url.queryItems, items.count == 1, let version = items.first,
              version.name == "api-version", let value = version.value, !value.isEmpty
        else { return false }
        let allowed = CharacterSet(charactersIn: "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-.")
        return value.count <= 64 && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    /// The refusal for an empty required field, which names it.
    private static func missing(_ field: AgentSignInField) -> String {
        switch field {
        case .apiKey: "请输入 API 密钥。"
        case .baseURL: "请输入端点地址。"
        case .defaultModel: "请输入模型 ID。"
        case .apiFormat: "请选择接口格式。"
        case .appendV1: "请选择是否自动附加 /v1。"
        case .customUserAgent: "请输入自定义 User-Agent。"
        case .azure: "请选择是否使用 Azure OpenAI。"
        case .imageEndpointMode: "请选择图像生成端点。"
        case .callbackURL: "请粘贴浏览器打开的地址。"
        }
    }

    private static func isSpaceOrControl(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.whitespacesAndNewlines.contains(scalar) || CharacterSet.controlCharacters.contains(scalar)
    }

    /// kwwk's API-key shape (KWWKCli's `apiKeyCredentials`): the key as
    /// `access`, no refresh token, never expiring, the rest as extras.
    static func apiKeyCredentials(_ values: [AgentSignInField: String]) -> OAuthCredentials {
        var credentials = OAuthCredentials(access: values[.apiKey] ?? "", refresh: "", expires: .max)
        for field in [
            AgentSignInField.baseURL, .defaultModel, .apiFormat,
            .appendV1, .customUserAgent, .azure, .imageEndpointMode,
        ] {
            if let value = values[field] {
                credentials.extras[field.rawValue] = .string(value)
            }
        }
        return credentials
    }

    /// What kwwk's login gets beside its callbacks: for Kimi, either site,
    /// the device id that site's stored sign-in recorded, so signing in
    /// again keeps the device Kimi knows (`KimiIdentity`).
    private func options(for run: SignInRun) async -> SignInOptions {
        guard run.provider == .kimiCoding || run.provider == .kimiCodingGlobal else { return SignInOptions() }
        let previous = try? await store.credentials(for: run.accountID)
        return SignInOptions(kimiIdentity: KimiIdentity.identity(recordedIn: previous))
    }

    private func perform(_ run: SignInRun, reporter: SignInReporter) async {
        let taskID = run.taskID
        do {
            let options = await options(for: run)
            // Not named `credentials`: Swift 6.2 reads the call in the closure
            // as the variable it initialises.
            var signedIn = try await Self.withDeadline(timeoutSeconds) { [self] in
                try await credentials(for: run, options: options, reporter: reporter)
            }
            if run.provider == .openRouter, run.method == .apiKey {
                signedIn.extras[ProviderModels.signInMethodExtra] = .string(run.method.rawValue)
            }
            try Task.checkCancellation()
            do {
                try await save(signedIn, for: run)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // A store error names a status, never the secret.
                throw ApelinError(.internal, "无法保存登录信息：\(error.localizedDescription)。请重试。")
            }
            reporter.finish(taskID, .succeeded, "You are signed in.")
        } catch {
            reporter.finish(taskID, run.isCancelled ? .cancelled : Self.state(of: error), Self.message(error))
        }
        clear(run)
    }

    /// A cancel — the app's, a newer sign-in's, the user's "deny" on the
    /// provider's page — ends `cancelled`; everything else `failed`.
    static func state(of error: Error) -> TaskState {
        switch error {
        case is CancellationError: .cancelled
        case let error as OAuthLoginError where error == .cancelled: .cancelled
        default: .failed
        }
    }

    /// What the user reads: kwwk's own words for what went wrong, cut short
    /// — a provider's error body names the failure, and a failed exchange
    /// has no token to show.
    static func message(_ error: Error) -> String {
        switch error {
        case is CancellationError: return "Sign-in was cancelled."
        case let error as OAuthLoginError where error == .cancelled: return "Sign-in was declined or cancelled."
        case OAuthLoginError.timedOut, SignInDeadline.passed:
            return "登录超时，请重试。"
        case let error as ApelinError: return error.message
        default: break
        }
        let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        return text.count > 300 ? String(text.prefix(300)) + "…" : text
    }

    private nonisolated func credentials(
        for run: SignInRun,
        options: SignInOptions,
        reporter: SignInReporter,
    ) async throws -> OAuthCredentials {
        let taskID = run.taskID
        switch run.method {
        case .apiKey:
            reporter.emit(taskID, "input", .object(["fields": .array(run.provider.keyFields.map { field in
                var entry: [String: ApelinCore.JSONValue] = [
                    "key": .string(field.field.rawValue),
                    "required": .bool(field.required),
                    "secure": .bool(field.secure),
                ]
                if let value = field.defaultValue {
                    entry["defaultValue"] = .string(value)
                }
                if let value = field.placeholder {
                    entry["placeholder"] = .string(value)
                }
                if let options = field.options {
                    entry["options"] = .array(options.map { option in
                        .object(["value": .string(option.value), "title": .string(option.title)])
                    })
                }
                return .object(entry)
            })]))
            return try await Self.apiKeyCredentials(run.waitForKeys())
        case .deviceCode, .browser:
            let listener = listener
            let callbacks = OAuthLogin.Callbacks(
                onDeviceCode: { code in
                    run.announcedDeviceCode()
                    reporter.emit(taskID, "deviceCode", .object([
                        "code": .string(code.code),
                        "verificationURL": .string(code.verificationURL.absoluteString),
                        "pageHoldsCode": .bool(code.pageHoldsCode),
                    ]))
                },
                browser: SignInPresenter(signIn: run, reporter: reporter),
                loopback: { host, port, path in
                    let loopback = try PasteableLoopback(inner: listener(host, port, path))
                    run.loopback = loopback
                    return loopback
                },
            )
            return try await login(run.provider, callbacks, options)
        }
    }

    /// Runs `body` for at most `seconds`; past that it throws
    /// `SignInDeadline.passed`. The clock's child answers whether it fired
    /// (nil), so a clock cancelled because the work ended is never read as
    /// the deadline.
    static func withDeadline<T: Sendable>(
        _ seconds: Double,
        _ body: @escaping @Sendable () async throws -> T,
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T?.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            guard let value = first else { throw SignInDeadline.passed }
            return value
        }
    }
}

enum SignInDeadline: Error {
    case passed
}

/// kwwk's page presenter: says what to open, once, and lets the flow's own
/// waiting run. A device flow has said it already, code and page together.
/// A flow that polls the provider (Cursor, Qoder, WorkBuddy, Z.ai) or binds
/// its own listener (Kiro) has no loopback of Apelin's, so nothing pasted
/// can stand in for its redirect.
private struct SignInPresenter: OAuthBrowserPresenter {
    let signIn: SignInRun
    let reporter: SignInReporter

    func run<Outcome: Sendable>(
        _ url: URL,
        while work: @escaping @Sendable () async throws -> Outcome,
    ) async throws -> Outcome {
        if !signIn.hasAnnouncedDeviceCode {
            reporter.emit(signIn.taskID, "authorize", .object([
                "url": .string(url.absoluteString),
                "acceptsCallbackURL": .bool(signIn.loopback != nil),
            ]))
        }
        return try await work()
    }
}

/// One sign-in in flight: its flow, the loopback it opened and, for a key,
/// what the user typed once it has been accepted.
final class SignInRun: @unchecked Sendable {
    let taskID: TaskID
    let provider: AgentProvider
    /// 本次操作持有的凭据存储 ID。
    let accountID: String
    let generation: UInt64
    let method: AgentSignInMethod
    var work: Task<Void, Never>?

    private let lock = NSLock()
    private var keyWaiter: CheckedContinuation<[AgentSignInField: String], Error>?
    private var keys: [AgentSignInField: String]?
    @objc private dynamic var cancelled = false
    @objc private dynamic var deviceCode = false
    private var listener: PasteableLoopback?

    init(taskID: TaskID, provider: AgentProvider, accountID: String? = nil, method: AgentSignInMethod, generation: UInt64 = 0) {
        self.taskID = taskID
        self.provider = provider
        self.accountID = AccountIDs.resolved(accountID, for: provider)
        self.generation = generation
        self.method = method
    }

    var loopback: PasteableLoopback? {
        get { lock.withLock { listener } }
        set { lock.withLock { listener = newValue } }
    }

    @objc dynamic var hasAnnouncedDeviceCode: Bool {
        lock.withLock { deviceCode }
    }

    @objc dynamic var isCancelled: Bool {
        lock.withLock { cancelled }
    }

    @objc dynamic func announcedDeviceCode() {
        lock.withLock { deviceCode = true }
    }

    @objc dynamic func cancel() {
        let waiter = lock.withLock { () -> CheckedContinuation<[AgentSignInField: String], Error>? in
            cancelled = true
            defer { keyWaiter = nil }
            return keyWaiter
        }
        waiter?.resume(throwing: CancellationError())
        loopback?.stop()
        work?.cancel()
    }

    /// Hands the accepted key to the flow, once.
    func deliver(_ values: [AgentSignInField: String]) throws {
        let waiter = try lock.withLock { () throws -> CheckedContinuation<[AgentSignInField: String], Error>? in
            guard keys == nil, !cancelled else { throw ApelinError(.conflict, "该登录已有密钥") }
            keys = values
            defer { keyWaiter = nil }
            return keyWaiter
        }
        waiter?.resume(returning: values)
    }

    func waitForKeys() async throws -> [AgentSignInField: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[AgentSignInField: String], Error>) in
                let early = lock.withLock { () -> Result<[AgentSignInField: String], Error>? in
                    if let keys {
                        return .success(keys)
                    }
                    if cancelled || Task.isCancelled {
                        return .failure(CancellationError())
                    }
                    keyWaiter = continuation
                    return nil
                }
                if let early {
                    continuation.resume(with: early)
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<[AgentSignInField: String], Error>? in
                defer { keyWaiter = nil }
                return keyWaiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }
}
