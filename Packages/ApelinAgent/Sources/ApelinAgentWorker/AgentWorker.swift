import ApelinAgent
import ApelinCore
import ApelinProtocol
import Darwin
import Foundation
import KWWKAI

/// `apelin-agent`: one agent session per process. The session host spawns
/// it as mobile for `agentOpen` (instance = session id) and forwards the
/// session's prompt, steer, abort, approve and close to it; the same
/// executable, spawned as the `credential-import` instance, serves
/// `agentCredentialImport` and the accounts: `agentAccountList`,
/// `agentSignIn` (a `signIn` task), `agentSignInRespond`, its cancel and
/// `agentSignOut` (`AccountDesk`), and Settings ▸ Skills' `agentSkillList`.
///
/// The session's events go to the host as the events of its `agent` task.
public enum AgentWorker {
    /// Apelin's own keychain items, shared by nothing else.
    public static let keychainAccessGroup = "wiki.qaq.apelin.agent"
    public static let defaultCopilotModel = "claude-sonnet-5.5"

    /// Sign-ins and the accounts list, against the keychain the sessions read.
    static let accounts = AccountDesk(store: KeychainCredentialSource(accessGroup: keychainAccessGroup))

    public static func main() -> Never {
        let state = WorkerState()
        WorkerMain.run(role: .agent, onCancel: { taskID, _ in
            Task {
                // A sign-in's cancel ends that sign-in; any other is the session's.
                if await accounts.cancel(taskID) {
                    return
                }
                await state.abort()
            }
        }, onClose: {
            // the host has gone and the worker exits next: what still runs
            // never ends, and the journal says so while it can
            SessionJournal.interruptAll(reason: "the session host closed the worker's channel")
        }) { request, context in
            await handle(request, context: context, state: state)
        }
    }

    static func handle(
        _ request: ChannelRequest,
        context: WorkerContext,
        state: WorkerState,
    ) async -> (WireReply, [OwnedDescriptor]) {
        switch request.request.operation {
        case .agentOpen:
            await WorkerMain.serve(AgentOpenRequest.self, request) { open in
                guard let taskID = request.taskID else {
                    throw ApelinError(.badRequest, "agentOpen 随其任务一起提供")
                }
                try await state.open(open, taskID: taskID, context: context)
                return AgentOpenResponse(
                    sessionID: context.assignment.sessionID ?? "",
                    task: TaskHandle(taskID: taskID, kind: .agent),
                )
            }
        case .agentPrompt:
            await WorkerMain.serve(AgentPromptRequest.self, request) { prompt in
                let session = try await state.session(prompt.sessionID)
                await state.markRunActive()
                if let mode = prompt.approvalMode {
                    await session.setApprovalMode(AgentWorker.approvalMode(mode))
                }
                if let asks = prompt.asksBeforeScreen {
                    await session.setAsksBeforeScreen(asks)
                }
                if let unlock = prompt.allowsUnlock {
                    await session.setAllowsUnlock(unlock)
                }
                if let runMode = prompt.runMode {
                    await session.setRunMode(runMode)
                }
                // Each prompt carries the reader's injection as the app has
                // it now, so a chat that was already open hears the switch:
                // the worker says so in this message's `<system-state>`.
                if let injection = prompt.promptInjection {
                    await session.setPromptInjection(injection)
                }
                let choice = try prompt.provider.map { provider in
                    PendingModelChoice(
                        provider: try AgentWorker.provider(provider: provider, model: prompt.model, accountID: prompt.accountID),
                        wireProvider: provider, model: prompt.model,
                        reasoningEffort: prompt.reasoningEffort, serviceTier: prompt.serviceTier,
                        parameters: prompt.modelParameters ?? .init(), defaults: prompt.modelDefaults,
                        accountID: prompt.accountID)
                }
                if let provider = prompt.provider {
                    do {
                        try await session.configure(
                            provider: AgentWorker.provider(AgentOpenRequest(provider: provider, accountID: prompt.accountID, model: prompt.model)),
                            thinking: .init(rawValue: prompt.reasoningEffort?.rawValue ?? "off") ?? .off,
                            serviceTier: AgentWorker.serviceTier(prompt.serviceTier),
                            modelLimits: prompt.modelLimits,
                            credentials: KeychainCredentialSource(accessGroup: keychainAccessGroup),
                        )
                    } catch let error as ProviderResolutionError {
                        throw AgentWorker.signInError(error)
                    }
                    await state.modelChoice.set(
                        provider: provider,
                        model: prompt.model,
                        reasoningEffort: prompt.reasoningEffort,
                        serviceTier: prompt.serviceTier,
                        modelLimits: prompt.modelLimits,
                        accountID: prompt.accountID,
                    )
                }
                guard (prompt.attachments?.count ?? 0) <= 8 else {
                    throw ApelinError(.badRequest, "附件描述无效")
                }
                let files = try (prompt.attachments ?? []).map { attachment -> (name: String, mimeType: String, descriptor: OwnedDescriptor) in
                    guard request.descriptors.indices.contains(attachment.descriptor.index) else {
                        throw ApelinError(.badRequest, "附件描述无效")
                    }
                    let descriptor = request.descriptors[attachment.descriptor.index]
                    return (attachment.name, attachment.mimeType, descriptor)
                }
                // A queued reader choice owns its auxiliary defaults too;
                // do not change compression/image settings of the active run.
                if choice == nil { await session.setModelDefaults(prompt.modelDefaults) }
                var sender: ConversationSender?
                if let from = prompt.fromSessionID {
                    sender = await AgentWorker.sender(from, context: context)
                }
                // The turns of conversations this one opened, as the host
                // reported them, and its own account message when the list is
                // empty: facts about other conversations, which the message
                // keeps (the sender the host named stays). A report never
                // names this chat and never wakes a stopped queue — both are
                // the session's to decide (`AgentSession.prompt`).
                try await session.prompt(prompt.text, messageID: prompt.messageID, fileDescriptors: files, from: sender, source: prompt.source, delivery: prompt.delivery ?? .queue, modelChoice: choice, reports: prompt.reports)
                // Only the app's own message names the chat: a host account
                // message, even one carrying no turn, never does.
                if prompt.reports == nil {
                    await session.generateTitle(for: prompt.text)
                }
                return Acknowledged()
            }
        case .agentGenerateImage:
            await WorkerMain.serve(AgentGenerateImageRequest.self, request) { image in
                let session = try await state.session(image.sessionID)
                await session.setModelDefaults(image.modelDefaults)
                return try await session.generateImage(for: image.prompt)
            }
        case .agentSteer:
            await WorkerMain.serve(AgentSteerRequest.self, request) { steer in
                try await state.session(steer.sessionID).steer(steer.text)
                return Acknowledged()
            }
        case .agentQueue:
            await WorkerMain.serve(AgentQueueRequest.self, request) { queue in
                try await state.session(queue.sessionID).manageQueue(queue)
                return Acknowledged()
            }
        case .agentAbort:
            await WorkerMain.serve(AgentAbortRequest.self, request) { abort in
                // 应用的「停止」：由 worker 计时，未结束的运行会被兜底结束。
                try await state.stop(abort.sessionID)
                return Acknowledged()
            }
        case .agentCompact:
            await WorkerMain.serve(AgentCompactRequest.self, request) { compact in
                let session = try await state.session(compact.sessionID)
                await session.setModelDefaults(compact.modelDefaults)
                try await session.compact()
                return Acknowledged()
            }
        // The reader picked another model in the composer's row: applied
        // between runs, and the total that model reads is recorded, so the
        // ring is right before a prompt is sent.
        case .agentSetRunMode:
            await WorkerMain.serve(AgentSetRunModeRequest.self, request) { set in
                let session = try await state.session(set.sessionID)
                await session.setNextRunMode(set.mode)
                return Acknowledged()
            }
        case .agentConfigure:
            await WorkerMain.serve(AgentConfigureRequest.self, request) { configure in
                let session = try await state.session(configure.sessionID)
                let applied = try await session.configure(
                    provider: AgentWorker.provider(AgentOpenRequest(
                        provider: configure.provider,
                        accountID: configure.accountID,
                        model: configure.model,
                    )),
                    thinking: .init(rawValue: configure.reasoningEffort?.rawValue ?? "off") ?? .off,
                    serviceTier: AgentWorker.serviceTier(configure.serviceTier),
                    modelParameters: configure.modelParameters ?? .init(),
                    credentials: KeychainCredentialSource(accessGroup: keychainAccessGroup),
                )
                guard applied else { return AgentConfigureResponse(applied: false) }
                await state.modelChoice.set(
                    provider: configure.provider,
                    model: configure.model,
                    reasoningEffort: configure.reasoningEffort,
                    serviceTier: configure.serviceTier,
                    modelParameters: configure.modelParameters,
                    accountID: configure.accountID,
                )
                let figure = await session.contextFigure()
                return AgentConfigureResponse(applied: true, tokens: figure.tokens, window: figure.window)
            }
        case .agentRewind:
            await WorkerMain.serve(AgentRewindRequest.self, request) { rewind in
                try await state.session(rewind.sessionID).rewind(to: rewind.messageID, truncate: rewind.truncate)
                return Acknowledged()
            }
        case .agentEditMessage:
            await WorkerMain.serve(AgentEditMessageRequest.self, request) { edit in
                try await state.session(edit.sessionID).edit(
                    edit.messageID,
                    reply: edit.reply,
                    text: edit.text,
                    expected: edit.expected,
                )
                return Acknowledged()
            }
        case .agentDeleteReply:
            await WorkerMain.serve(AgentDeleteReplyRequest.self, request) { delete in
                try await state.session(delete.sessionID).deleteReply(delete.messageID, expected: delete.expected)
                return Acknowledged()
            }
        case .agentFork:
            await WorkerMain.serve(AgentForkRequest.self, request) { fork in
                try await state.session(fork.sessionID).fork(through: fork.messageID, as: fork.newSessionID)
                return Acknowledged()
            }
        case .agentApprove:
            await WorkerMain.serve(AgentApproveRequest.self, request) { approve in
                try await state.approve(approve)
                return Acknowledged()
            }
        case .agentClose:
            await WorkerMain.serve(AgentCloseRequest.self, request) { close in
                _ = try await state.session(close.sessionID)
                await state.close(.succeeded, message: "closed")
                return Acknowledged()
            }
        case .agentCredentialImport:
            await WorkerMain.serve(AgentCredentialImportRequest.self, request) { _ in
                await CredentialInbox(home: context.assignment.home)
                    .importAll(into: KeychainCredentialSource(accessGroup: keychainAccessGroup))
            }
        case .agentAccountList:
            await WorkerMain.serve(AgentAccountListRequest.self, request) { list in
                await accounts.list(
                    extraModels: list.extraModels ?? [:],
                    onlyExtraModels: list.onlyExtraModels ?? false,
                )

            }
        case .agentMCPTools:
            await WorkerMain.serve(AgentMCPToolsRequest.self, request) { query in
                let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
                let store = MCPServerStore(root: ApelinDataRoot(home: home).url)
                let snapshot = try store.read()
                guard let record = snapshot.servers.items.first(where: { $0.connection.name == query.serverName }) else {
                    throw MCPStoreError.serverNotFound
                }
                return AgentMCPToolsResponse(
                    serverName: record.connection.name,
                    tools: try await MCPServerToolInspector.list(
                        name: record.connection.name,
                        url: record.connection.url,
                        headers: record.connection.headers,
                    ),
                )
            }
        case .agentProviderQuota:
            await WorkerMain.serve(AgentProviderQuotaRequest.self, request) { query in
                let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
                return try await accounts.quotas(query, dataRoot: ApelinDataRoot(home: home))
            }
        case .agentProviderBalances:
            await WorkerMain.serve(AgentProviderBalancesRequest.self, request) { balances in
                let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
                return try await accounts.providerBalances(force: balances.force, home: home)
            }
        case .agentCheckIn:
            await WorkerMain.serve(AgentCheckInRequest.self, request) { checkIn in
                let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
                return try await accounts.checkIn(platforms: checkIn.platforms, force: checkIn.force, home: home)
            }
        case .agentSkillList:
            await WorkerMain.serve(AgentSkillListRequest.self, request) { _ in
                let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
                return SkillCatalog.listing(userDirectory: ApelinDataRoot(home: home).skills)
            }
        case .agentModelTest:
            await WorkerMain.serve(AgentModelTestRequest.self, request) { query in
                _ = try AccountDesk.validatedAccountID(query.accountID, for: query.provider)
                guard let taskID = request.taskID else {
                    throw ApelinError(.badRequest, "模型测试需要一个任务")
                }
                // The probe can take a minute: the handle goes back at once and
                // each stage is emitted as it starts and ends, then the report
                // travels as the `result` of the final `state`.
                Task.detached(priority: .userInitiated) {
                    let response = await AgentModelTester.run(
                        query,
                        credentials: KeychainCredentialSource(accessGroup: keychainAccessGroup),
                    ) { stage in
                        context.emit(taskID, AgentModelTestProgress.eventKind, stage.payload)
                    }
                    var payload: [String: ApelinCore.JSONValue] = [
                        "state": .string(response.success ? TaskState.succeeded.rawValue : TaskState.failed.rawValue),
                    ]
                    if let report = try? ApelinCore.JSONValue(encoding: response) {
                        payload[AgentModelTestResponse.stateMember] = report
                    }
                    if let failure = response.failure {
                        payload["message"] = .string(failure)
                    }
                    context.emit(taskID, TaskEvent.stateKind, .object(payload))
                }
                return TaskHandle(taskID: taskID, kind: .modelTest)
            }
        case .agentRewritePrompt:
            await WorkerMain.serve(AgentRewritePromptRequest.self, request) { query in
                try await PromptRewriter.rewrite(
                    query,
                    home: URL(fileURLWithPath: context.assignment.home, isDirectory: true),
                    installRoot: context.assignment.installRoot,
                    credentials: KeychainCredentialSource(accessGroup: keychainAccessGroup),
                )
            }
        case .agentAPIConfiguration:
            await WorkerMain.serve(AgentAPIConfigurationRequest.self, request) { query in
                try await accounts.apiConfiguration(for: query.provider, accountID: query.accountID)
            }
        case .agentModelList:
            await WorkerMain.serve(AgentModelListRequest.self, request) { query in
                try await accounts.models(for: query.provider, accountID: query.accountID, limitsFor: query.limitsFor ?? [])
            }
        case .agentModelActivate:
            await WorkerMain.serve(AgentModelActivateRequest.self, request) { query in
                guard let taskID = request.taskID else {
                    throw ApelinError(.badRequest, "模型验证需要一个任务")
                }
                try await accounts.activateModels(query, taskID: taskID, reporter: SignInReporter(context: context))
                return TaskHandle(taskID: taskID, kind: .signIn)
            }
        case .agentSignIn:
            await WorkerMain.serve(AgentSignInRequest.self, request) { signIn in
                guard let taskID = request.taskID else {
                    throw ApelinError(.badRequest, "agentSignIn 随其任务一起提供")
                }
                try await accounts.start(signIn, taskID: taskID, reporter: SignInReporter(context: context))
                return TaskHandle(taskID: taskID, kind: .signIn)
            }
        case .agentSignInRespond:
            await WorkerMain.serve(AgentSignInRespondRequest.self, request) { respond in
                try await accounts.respond(respond)
                return Acknowledged()
            }
        case .agentSignOut:
            await WorkerMain.serve(AgentSignOutRequest.self, request) { signOut in
                let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
                try await accounts.signOut(signOut.provider, accountID: signOut.accountID, dataRoot: ApelinDataRoot(home: home))
                return Acknowledged()
            }
        default:
            WorkerMain.unimplemented(request)
        }
    }

    /// The conversation a message came from (the host wrote its session ID),
    /// with its title when the host lists one.
    static func sender(_ sessionID: String, context: WorkerContext) async -> ConversationSender {
        let listed = try? await context.host.agentList().sessions.first { $0.sessionID == sessionID }
        return ConversationSender(sessionID: sessionID, title: listed?.title)
    }

    /// The wire's approval mode as the session's gate takes it.
    static func approvalMode(_ wire: ApelinProtocol.ApprovalMode) -> ApelinAgent.ApprovalMode {
        switch wire {
        case .relaxed: .relaxed
        case .confirm: .confirm
        case .full: .full
        }
    }

    static func serviceTier(_ wire: AgentServiceTier?) -> ServiceTier? {
        wire.flatMap { ServiceTier(rawValue: $0.rawValue) }
    }

    /// The app is told why a session's saved sign-in cannot be used.
    static func signInError(_ error: ProviderResolutionError, inboxRejected: [String] = []) -> ApelinError {
        switch error {
        case .missingCredentials:
            var message = error.localizedDescription
            if !inboxRejected.isEmpty {
                message += "（导入凭据：\(inboxRejected.joined(separator: "；"))）"
            }
            return ApelinError(.denied, message)
        case let .unresolved(message, reason):
            guard let reason else { return ApelinError(.internal, message) }
            return ApelinError(.unavailable, message, reason: reason)
        }
    }

    /// The kwwk provider configuration for an open request. The first four
    /// keep their own cases (and need a model named, as they always have);
    /// every other provider uses its credential store id and the default
    /// model chosen by ProviderRegistration when none is named.
    static func provider(_ open: AgentOpenRequest) throws -> ProviderConfiguration {
        try provider(provider: open.provider ?? .githubCopilot, model: open.model, accountID: open.accountID)
    }

    /// The same, from a provider and model rather than an open request: a
    /// rewrite asks the model a session would, without opening one.
    static func provider(
        provider: AgentProvider,
        model requested: String?,
        accountID: String? = nil,
    ) throws -> ProviderConfiguration {
        let account = try AccountDesk.validatedAccountID(accountID, for: provider)
        let model = requested.flatMap { $0.isEmpty ? nil : $0 }
        // 额外账号按自己的凭据 ID 解析，刷新与传输由注册表映射回原服务商。
        if account != provider.storeID {
            if provider == .githubCopilot {
                return .stored(storeID: account, model: model ?? defaultCopilotModel)
            }
            if provider == .anthropic || provider == .anthropicOAuth || provider.kind == .openAICompatible {
                guard model != nil else { throw ApelinError(.badRequest, "请给出 \(provider.rawValue) 的模型") }
            }
            return .stored(storeID: account, model: model)
        }
        switch provider {
        case .githubCopilot:
            return .githubCopilot(model: model ?? defaultCopilotModel)
        case .anthropic:
            guard let model else { throw ApelinError(.badRequest, "请给出 \(provider.rawValue) 的模型") }
            return .anthropic(model: model, oauth: false)
        case .anthropicOAuth:
            guard let model else { throw ApelinError(.badRequest, "请给出 \(provider.rawValue) 的模型") }
            return .anthropic(model: model, oauth: true)
        case .openAICompatible:
            guard let model else { throw ApelinError(.badRequest, "请给出 \(provider.rawValue) 的模型") }
            return .openAICompatible(model: model)
        case .openAICodex, .cursor, .devin, .kiro, .qoder, .qoderCN, .workBuddy, .workBuddyAI,
             .trae, .traeIntl, .raccoon,
             .kimiCoding, .kimiCodingGlobal, .xai, .zai, .zaiCodingCN, .openRouter, .openAI, .google, .deepSeek,
             .openCodeGo, .openCodeZen:
            return .stored(storeID: provider.storeID, model: model)
        case .openAICompatibleEndpoint:
            // As the first endpoint: its base URL is with its key, and the
            // model is named.
            guard let model else { throw ApelinError(.badRequest, "请给出 \(provider.rawValue) 的模型") }
            return .stored(storeID: provider.storeID, model: model)
        }
    }
}

/// The one session this process serves, and the relay of its events.
actor WorkerState {
    /// What the session runs with now, which a conversation it opens starts with.
    let modelChoice = SessionModelChoice()
    private var session: AgentSession?
    /// An open is under way. It takes the place before its first
    /// suspension, so an open the host sends meanwhile is refused rather
    /// than served by a second session writing the same log.
    private var opening = false
    private var taskID: TaskID?
    private var context: WorkerContext?
    private var relay: Task<Void, Never>?
    private var closeWhenFinished = false
    private var finished = false
    /// A stop's timed fallback: a run that does not answer its cancellation
    /// is ended by the worker, so Stop always ends the turn.
    private var stopWatch: Task<Void, Never>?
    /// Whether the current run is still going, for that fallback. Set when
    /// the run opens, cleared by its `.finished` event.
    private var runActive = false
    /// How long a stopped run has to end before the worker ends it.
    private let stopPatience: Duration = .seconds(20)

    func open(_ open: AgentOpenRequest, taskID: TaskID, context: WorkerContext) async throws {
        guard session == nil, !opening else {
            throw ApelinError(.conflict, "该进程已在服务或正在打开一个会话")
        }
        guard let sessionID = context.assignment.sessionID, SessionEventLog.isValidSessionID(sessionID) else {
            throw ApelinError(.badRequest, "代理会话需要宿主给出的会话 id")
        }
        guard let projectID = open.projectID, let projectName = open.projectName else {
            throw ApelinError(.badRequest, "宿主没有指明会话的项目")
        }
        let identity: ApelinAgent.ProjectIdentity
        do {
            identity = try ApelinAgent.ProjectIdentity(id: projectID, name: ApelinAgent.ProjectName(projectName))
        } catch {
            throw ApelinError(.badRequest, "\(projectName) is not a project name")
        }
        let home = URL(fileURLWithPath: context.assignment.home, isDirectory: true)
        let dataRoot = ApelinDataRoot(home: home)
        let projectURL = dataRoot.workspace(for: identity.name, temporaryID: open.temporaryID)
        // A brief that does not hold is refused before a session exists: no
        // conversation runs against an assignment nothing can enforce. The
        // host validates it too; this is the worker's own fail-closed gate.
        if let brief = open.delegationBrief {
            do {
                try brief.validate()
            } catch {
                throw ApelinError(.badRequest, error.localizedDescription)
            }
        }

        opening = true
        let openedAt = Date()
        // one that fails leaves the place free for the host to try again
        defer { opening = false }
        // Credentials the owner dropped in the inbox are taken first.
        let keychain = KeychainCredentialSource(accessGroup: AgentWorker.keychainAccessGroup)
        let imported = await CredentialInbox(home: context.assignment.home).importAll(into: keychain)

        let ledger = HostDigestLedger(service: context.host, projectURL: projectURL, dataFolder: dataRoot.url)
        let session: AgentSession
        do {
            session = try await AgentSession(
                configuration: AgentSessionConfiguration(
                    id: sessionID,
                    project: identity,
                    temporaryID: open.temporaryID,
                    provider: AgentWorker.provider(open),
                    approval: ApprovalPolicy(
                        mode: AgentWorker.approvalMode(open.approvalMode),
                        asksBeforeScreen: ScreenConsent.asks(open.asksBeforeScreen),
                        allowsUnlock: ScreenConsent.allowsUnlock(open.allowsUnlock),
                    ),
                    dataRoot: dataRoot,
                    mcpServers: (open.mcpServers ?? []).compactMap { connection in
                        guard let url = URL(string: connection.url) else { return nil }
                        return try? MCPServerConfiguration(
                            name: connection.name, url: url,
                            headers: connection.headers, description: connection.note
                        )
                    },
                    thinking: .init(rawValue: open.reasoningEffort?.rawValue ?? "off") ?? .off,
                    serviceTier: AgentWorker.serviceTier(open.serviceTier),
                    modelParameters: open.modelParameters ?? .init(),
                    modelDefaults: open.modelDefaults ?? .init(),
                    promptInjection: (open.promptInjection ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
                    modelLimits: open.modelLimits,
                    installRoot: context.assignment.installRoot,
                    hostRestarted: open.hostRestarted == true,
                    openerSessionID: open.openerSessionID,
                    delegationBrief: open.delegationBrief,
                ),
                backend: ChannelHostBackend(
                    service: context.host,
                    sessionID: sessionID,
                    project: identity,
                    projectURL: projectURL,
                    projectsURL: dataRoot.projects,
                    modelChoice: modelChoice,
                    modelDefaults: open.modelDefaults ?? .init(),
                ),
                digests: ledger,
                credentials: keychain,
            )
        } catch let error as ProviderResolutionError {
            var message = error.localizedDescription
            if !imported.rejected.isEmpty {
                message += " (inbox: \(imported.rejected.joined(separator: "; ")))"
            }
            throw ApelinError(.denied, message)
        } catch let error as ApelinError {
            throw error
        } catch {
            throw ApelinError(.internal, error.localizedDescription)
        }

        self.session = session
        self.taskID = taskID
        self.context = context
        closeWhenFinished = open.closeWhenFinished == true
        await modelChoice.set(
            provider: open.provider,
            model: open.model,
            reasoningEffort: open.reasoningEffort,
            serviceTier: open.serviceTier,
            modelParameters: open.modelParameters,
            modelLimits: open.modelLimits,
            accountID: open.accountID,
        )

        await modelChoice.setDefaults(open.modelDefaults)
        let choiceStore = modelChoice
        await session.observePendingModel { choice in
            await choiceStore.set(provider: choice.wireProvider, model: choice.model,
                                  reasoningEffort: choice.reasoningEffort, serviceTier: choice.serviceTier,
                                  modelParameters: choice.parameters,
                                  accountID: choice.accountID ?? choice.provider.storeID)
            if let defaults = choice.defaults { await choiceStore.setDefaults(defaults) }
        }

        // The total this open's model reads. A conversation whose log ends on
        // another model's window would otherwise draw that one as this one's
        // until its next turn ended.
        await session.recordContextUsage()

        let boundary = try await session.replayBoundary()
        let events = try await session.events(afterSeq: 0)
        let relay = EventRelay(context: context, taskID: taskID)
        self.relay = Task { [weak self] in
            for await record in events {
                await relay.relay(record.event, historical: record.seq <= boundary, at: record.date)
                if record.seq > boundary, case let .finished(reason) = record.event {
                    await self?.clearRunMarks()
                    await relay.flush()
                    await self?.runFinished(reason)
                }
            }
            await relay.flush()
        }
        if let prompt = open.prompt, !prompt.isEmpty {
            runActive = true
            if let runMode = open.runMode {
                await session.setRunMode(runMode)
            }
            try await session.prompt(prompt, messageID: open.messageID)
            // A conversation another agent opened is named by its opener,
            // or like one the user started; a headless run is not named.
            if let title = open.title {
                await session.setTitle(title)
            } else if !closeWhenFinished {
                await session.generateTitle(for: prompt)
            }
        }
        // What the app waited on before this chat could take a message, on
        // the conversation's own journal: the worker start, the session's
        // open and the replay of its history.
        session.journal.startup(
            "open finished in \(AgentSession.milliseconds(since: openedAt)) "
                + "(\(openedMessages(open)))",
        )
    }

    private func openedMessages(_ open: AgentOpenRequest) -> String {
        open.sessionID == nil ? "new: " : "resumed: " + (open.prompt.map { "\($0.count) chars" } ?? "no prompt")
    }

    func session(_ id: String) throws -> AgentSession {
        guard let session, id == session.id else {
            throw ApelinError(.notFound, "该进程不服务会话 \(id)")
        }
        return session
    }

    func approve(_ approve: AgentApproveRequest) async throws {
        let session = try session(approve.sessionID)
        guard await session.pendingApprovals.contains(where: { $0.id == approve.approvalID }) else {
            throw ApelinError(.notFound, "该审批请求已不在等待决定。")
        }
        // The host records a description or removal approval in its own
        // ledger as it relays this decision; the agent keeps nothing. An
        // answer to a question goes with it, checked by the session's gate.
        try await session.approve(
            requestID: approve.approvalID,
            decision: Self.decision(approve),
            answer: approve.answer,
            note: approve.decision == .approve ? approve.note : nil,
        )
    }

    /// The app's decision as the session's gate takes it: "for this
    /// session" where the app said so (the gate keeps it only for a request
    /// that offered it, and the host records the matching grant).
    /// The wire's yes or no, and what the reader typed beside it: a denial's
    /// reason is that text, which the model reads, and a bare denial keeps
    /// the sentence it always had.
    static func decision(_ approve: AgentApproveRequest) -> ApelinAgent.ApprovalDecision {
        guard approve.decision == .approve else {
            let typed = approve.note?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return .deny(reason: typed.isEmpty ? "denied in Apelin" : typed)
        }
        return .approve(approve.scope == .session ? .session : .once)
    }

    /// Marks the start of a run, for the stop fallback.
    func markRunActive() {
        stopWatch?.cancel()
        stopWatch = nil
        runActive = true
    }

    /// Stops the run of session `sessionID`, the app's Stop (`agentAbort`).
    /// The session's abort is followed by a timed fallback: a run still
    /// going after `stopPatience` is ended by the worker, so Stop always
    /// ends the turn even when something holds its cancellation.
    func stop(_ sessionID: String) async throws {
        _ = try session(sessionID)
        await stop()
    }

    func stop() async {
        guard let session else { return }
        let stopped = await session.abort()
        stopWatch?.cancel()
        let patience = stopPatience
        stopWatch = Task { [weak self] in
            try? await Task.sleep(for: patience)
            guard let self, !Task.isCancelled else { return }
            await self.endUnstoppedIfRunning(stopped)
        }
    }

    /// The timed fallback: if the stopped run has not ended, end the task
    /// with the reason the app says as "Did Not Stop in Time".
    private func endUnstoppedIfRunning(_ stopped: AgentSession.StoppedWork) async {
        // 只判断这次停止捕获的旧工作，不能被后来启动的任务延长。
        guard !stopped.hasEnded, runActive, !finished else { return }
        runActive = false
        let message = "This chat did not stop in time, so Apelin ended it. Send a message to continue."
        if let context, let taskID {
            context.emit(taskID, "error", .object([
                "message": .string(message),
                "reason": .string(ApelinError.Reason.unstopped.rawValue),
            ]))
        }
        await close(.cancelled, message: message)
    }

    func abort() async {
        await session?.abort()
    }

    /// The run's own marks, cleared where the actor owns them.
    private func clearRunMarks() {
        runActive = false
        stopWatch?.cancel()
        stopWatch = nil
    }

    /// A run ended; a headless session ends with it.
    private func runFinished(_ reason: FinishReason) async {
        guard closeWhenFinished else { return }
        let state: TaskState = switch reason {
        case .completed: .succeeded
        case .aborted: .cancelled
        case .failed: .failed
        }
        await close(state, message: "the run \(reason.rawValue)")
    }

    /// Ends the task and, a moment after the reply has gone, the process.
    func close(_ state: TaskState, message: String) async {
        guard !finished else { return }
        finished = true
        let session = session
        let context = context
        let taskID = taskID
        Task.detached {
            await session?.close()
            if let context, let taskID {
                context.finish(taskID, state, message: message)
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
            exit(0)
        }
    }
}

/// Turns session events into task events. Streamed text is coalesced into
/// `text` events of at least a few hundred bytes or a quarter second apart,
/// so a long answer is not thousands of events in the host's registry. The
/// run's `received` count goes out with the same flushes, its latest only.
actor EventRelay {
    private let emit: @Sendable (String, ApelinCore.JSONValue?) -> Void
    private var text = ""
    private var thinking = ""
    private var received: Int?
    private var lastFlush = Date()
    private var flushScheduled = false
    private var waiting = 0
    private var historical: Bool?
    /// When the record being replayed happened, in the log it came from.
    /// `historical` event payloads carry it as `at`, because the host stamps
    /// every task event with the moment it relayed it: without it a
    /// conversation read back — a fork's whole history — says every turn
    /// took as long as the replay did.
    private var replayedAt: Date?

    init(context: WorkerContext, taskID: TaskID) {
        self.init { kind, payload in context.emit(taskID, kind, payload) }
    }

    /// `emit` takes each task event, in order.
    init(emit: @escaping @Sendable (String, ApelinCore.JSONValue?) -> Void) {
        self.emit = emit
    }

    /// `at`: when the record happened, for a record read back from the
    /// session's own log rather than one just made.
    func relay(_ event: AgentSessionEvent, historical: Bool = false, at: Date? = nil) {
        if self.historical != nil, self.historical != historical {
            flush()
        }
        self.historical = historical
        if let at {
            replayedAt = at
        }
        switch event {
        case let .textDelta(delta):
            text += delta
            scheduleFlush()
            return
        case let .thinkingDelta(delta):
            thinking += delta
            scheduleFlush()
            return
        case let .received(tokens):
            received = tokens
            scheduleFlush()
            return
        default:
            flush()
        }
        for (kind, payload) in Self.events(for: event, waiting: &waiting) {
            emitEvent(kind, payload)
        }
    }

    /// A replay's payload is the record's own, with the two fields the app
    /// reads beside it: `historical`, and when it happened.
    private func emitEvent(_ kind: String, _ payload: ApelinCore.JSONValue?) {
        guard historical == true else {
            emit(kind, payload)
            return
        }
        var values: [String: ApelinCore.JSONValue] = [:]
        if let payload, case let .object(held) = payload {
            values = held
        }
        values["historical"] = .bool(true)
        if let replayedAt {
            values["at"] = .number(replayedAt.timeIntervalSince1970)
        }
        emit(kind, .object(values))
    }

    func flush() {
        if !thinking.isEmpty {
            emitEvent("thinking", .object(["text": .string(thinking)]))
        }
        if !text.isEmpty {
            emitEvent("text", .object(["text": .string(text)]))
        }
        if let received {
            for (kind, payload) in Self.events(for: .received(tokens: received), waiting: &waiting) {
                emitEvent(kind, payload)
            }
        }
        text = ""
        thinking = ""
        received = nil
        lastFlush = Date()
    }

    private func scheduleFlush() {
        if text.utf8.count + thinking.utf8.count >= 512 || Date().timeIntervalSince(lastFlush) > 0.25 {
            flush()
            return
        }
        guard !flushScheduled else { return }
        flushScheduled = true
        Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            self.timedFlush()
        }
    }

    private func timedFlush() {
        flushScheduled = false
        flush()
    }

    /// The task events one session event becomes. Kinds and payloads are
    /// listed in AGENTS.md ▸ Decisions ▸ Agent sessions.
    static func events(for event: AgentSessionEvent, waiting: inout Int) -> [(String, ApelinCore.JSONValue?)] {
        switch event {
        case let .pendingQueue(messages, paused):
            return [("pendingQueue", .object([
                "messages": (try? ApelinCore.JSONValue(encoding: messages)) ?? .array([]),
                "paused": .bool(paused),
            ]))]
        case let .userMessage(id, text, attachments, source):
            var payload: [String: ApelinCore.JSONValue] = [
                "id": .string(id.uuidString),
                "text": .string(text),
                "attachments": (try? ApelinCore.JSONValue(encoding: attachments)) ?? .array([]),
            ]
            if let source {
                payload["source"] = .string(source)
            }
            return [("prompt", .object(payload))]
        case let .userMessageQueued(id, text, attachments, source):
            var payload: [String: ApelinCore.JSONValue] = [
                "id": .string(id.uuidString),
                "text": .string(text),
                "attachments": (try? ApelinCore.JSONValue(encoding: attachments)) ?? .array([]),
            ]
            if let source {
                payload["source"] = .string(source)
            }
            return [("queued", .object(payload))]
        case let .conversationMessageQueued(id, text, from, reports):
            var payload: [String: ApelinCore.JSONValue] = [
                "id": .string(id.uuidString), "text": .string(text), "from": .string(from),
            ]
            if let reports {
                payload["reports"] = (try? ApelinCore.JSONValue(encoding: reports)) ?? .array([])
            }
            return [("queued", .object(payload))]
        case let .conversationMessageTaken(id, text, from, reports):
            var payload: [String: ApelinCore.JSONValue] = [
                "id": .string(id.uuidString), "text": .string(text), "from": .string(from),
            ]
            if let reports {
                payload["reports"] = (try? ApelinCore.JSONValue(encoding: reports)) ?? .array([])
            }
            return [("prompt", .object(payload))]
        case let .conversationMessagesDropped(ids):
            return [("queueDropped", .object(["ids": .array(ids.map { .string($0.uuidString) })]))]
        case let .queuedMessagesDropped(ids):
            return [("queueDropped", .object(["ids": .array(ids.map { .string($0.uuidString) })]))]
        case let .promptSubmitted(text, from):
            var payload: [String: ApelinCore.JSONValue] = ["text": .string(text)]
            if let from {
                payload["from"] = .string(from)
            }
            return [("prompt", .object(payload))]
        case let .titleUpdated(title):
            return [("title", .object(["text": .string(title)]))]
        case let .projectNameSuggested(name):
            return [("projectNameSuggested", .object(["name": .string(name)]))]
        case let .steered(text):
            return [("steer", .object(["text": .string(text)]))]
        case .messageStarted:
            return [("messageStarted", nil)]
        case .messageDiscarded:
            return [("messageDiscarded", nil)]
        case .reconnecting:
            return [("reconnecting", nil)]
        case .waitingForNetwork:
            return [("waitingForNetwork", nil)]
        case .toolCallPreparing:
            return [("toolCallPreparing", nil)]
        case let .textDelta(text):
            return [("text", .object(["text": .string(text)]))]
        case let .thinkingDelta(text):
            return [("thinking", .object(["text": .string(text)]))]
        case let .messageFinished(text):
            return [("message", .object(["text": .string(text)]))]
        case let .received(tokens):
            return [("received", .object(["tokens": .number(Double(tokens))]))]
        case let .contextUsage(tokens, window):
            return [("contextUsage", .object([
                "tokens": .number(Double(tokens)),
                "window": .number(Double(window)),
            ]))]
        case let .toolCallStarted(call):
            return [("toolCall", .object([
                "id": .string(call.id),
                "tool": .string(call.name),
                "arguments": .string(ToolArgumentRedaction.redacted(call.arguments, tool: call.name)),
            ]))]
        case let .toolCallFinished(result):
            return [("toolResult", .object([
                "id": .string(result.id),
                "tool": .string(result.name),
                "output": .string(result.output),
                "isError": .bool(result.isError),
                "attachments": (try? ApelinCore.JSONValue(encoding: result.attachments ?? [])) ?? .array([]),
            ]))]
        case let .approvalRequested(request):
            waiting += 1
            return [
                ("approvalRequested", approvalPayload(request)),
                (TaskEvent.stateKind, .object(["state": .string(TaskState.waitingForApproval.rawValue)])),
            ]
        case let .approvalResolved(requestID, decision):
            waiting = max(0, waiting - 1)
            var resolved: [(String, ApelinCore.JSONValue?)] = [("approvalResolved", .object([
                "approvalID": .string(requestID),
                "decision": .string(decisionName(decision)),
            ]))]
            if waiting == 0 {
                resolved.append((TaskEvent.stateKind, .object(["state": .string(TaskState.running.rawValue)])))
            }
            return resolved
        case let .notice(title, body):
            var payload: [String: ApelinCore.JSONValue] = ["body": .string(body)]
            if let title {
                payload["title"] = .string(title)
            }
            return [(AgentNoticeRules.eventKind, .object(payload))]
        case let .runModeChanged(runMode, reason):
            return [("runModeChanged", .object([
                "mode": .string(runMode.rawValue),
                "reason": .string(reason),
            ]))]
        case let .error(message, reason):
            var payload: [String: ApelinCore.JSONValue] = ["message": .string(message)]
            if let reason {
                payload[Wire.errorReasonKey] = .string(reason.rawValue)
            }
            return [("error", .object(payload))]
        case .recoveryContinues:
            return [("recoveryContinues", nil)]
        case let .finished(reason):
            return [("finished", .object(["reason": .string(reason.rawValue)]))]
        case .compactionStarted:
            return [("compactionStarted", nil)]
        case let .compactionFinished(result):
            return [("compactionFinished", (try? ApelinCore.JSONValue(encoding: result)) ?? .null)]
        case let .usage(input, output, cacheRead, cacheWrite):
            return [("usage", .object([
                "input": .number(Double(input)),
                "output": .number(Double(output)),
                "cacheRead": .number(Double(cacheRead)),
                "cacheWrite": .number(Double(cacheWrite)),
            ]))]
        case let .checkpointSaved(id):
            return [("checkpoint", .object(["id": .string(id.uuidString)]))]
        case let .messageEdited(id, text):
            return [("messageEdited", .object(["id": .string(id.uuidString), "text": .string(text)]))]
        case let .replyEdited(id, text):
            return [("replyEdited", .object(["id": .string(id.uuidString), "text": .string(text)]))]
        case let .replyDeleted(id):
            return [("replyDeleted", .object(["id": .string(id.uuidString)]))]
        case let .historyRewound(id):
            return [("historyRewound", .object(["id": .string(id.uuidString)]))]
        }
    }

    static func approvalPayload(_ request: ApprovalRequest) -> ApelinCore.JSONValue {
        var payload: [String: ApelinCore.JSONValue] = [
            "approvalID": .string(request.id),
            "toolCallID": .string(request.toolCallID),
            "tool": .string(request.tool),
            "arguments": .string(ToolArgumentRedaction.redacted(request.arguments, tool: request.tool)),
            "workingDirectory": .string(request.workingDirectory),
            "projectID": .string(request.projectID),
            "fingerprint": .string(request.fingerprint),
            "reason": .string(request.reason),
            "allowsSessionScope": .bool(request.allowsSessionScope),
        ]
        switch request.detail {
        case .none:
            break
        case let .descriptionChanged(kind, digest, diff):
            payload["detail"] = .object(["descriptionChanged": .object([
                "kind": .string(kind.rawValue),
                "digest": .string(digest),
                "diff": .string(diff),
            ])])
        case let .command(invocation):
            payload["detail"] = .object(["command": (try? ApelinCore.JSONValue(encoding: invocation)) ?? .null])
        // Its own key, so the host never takes it for an ordinary command's
        // approval, nor the other way round.
        case let .rootCommand(invocation):
            payload["detail"] = .object([
                RunCodeApproval.rootCommandDetail: (try? ApelinCore.JSONValue(encoding: invocation)) ?? .null,
            ])
        case let .packageRemoval(installationID):
            payload["detail"] = .object(["packageRemoval": .object(["installationID": .string(installationID)])])
        case let .gitPush(remote, branch):
            var push: [String: ApelinCore.JSONValue] = ["remote": .string(remote)]
            if let branch {
                push["branch"] = .string(branch)
            }
            payload["detail"] = .object(["gitPush": .object(push)])
        // The push and lease the host matches an agent's forced gitPush to
        // (AgentForcePushRules).
        case let .forcePush(force):
            payload["detail"] = .object(["forcePush": (try? ApelinCore.JSONValue(encoding: force)) ?? .null])
        // The squash the host matches an agent's gitSquash to
        // (AgentSquashRules).
        case let .squash(squash):
            payload["detail"] = .object(["squash": (try? ApelinCore.JSONValue(encoding: squash)) ?? .null])
        case let .gitSettings(summary):
            payload["detail"] = .object(["gitSettings": .object(["summary": .string(summary)])])
        // What the host matches an agent's setup, import or call into another
        // project to (AgentEnvironmentRules, AgentConversationRules).
        case let .toolchainSetup(setup):
            payload["detail"] = .object(["toolchainSetup": (try? ApelinCore.JSONValue(encoding: setup)) ?? .null])
        case let .sdkImport(sdkImport):
            payload["detail"] = .object(["sdkImport": (try? ApelinCore.JSONValue(encoding: sdkImport)) ?? .null])
        case let .otherProject(reach):
            payload["detail"] = .object(["otherProject": (try? ApelinCore.JSONValue(encoding: reach)) ?? .null])
        case let .externalBuild(build):
            payload["detail"] = .object(["externalBuild": (try? ApelinCore.JSONValue(encoding: build)) ?? .null])
        case let .skillChange(change):
            payload["detail"] = .object(["skillChange": (try? ApelinCore.JSONValue(encoding: change)) ?? .null])
        case let .projectRename(rename):
            payload["detail"] = .object(["projectRename": (try? ApelinCore.JSONValue(encoding: rename)) ?? .null])
        // The issue the host matches an agent's feedbackSend to
        // (AgentFeedbackRules).
        case let .feedback(feedback):
            payload["detail"] = .object(["feedback": (try? ApelinCore.JSONValue(encoding: feedback)) ?? .null])
        // The issue, the new text and what it was made against, which the
        // host matches an agent's feedbackEdit to (AgentFeedbackRules); a
        // field that stays is left out.
        case let .feedbackEdit(edit):
            payload["detail"] = .object(["feedbackEdit": (try? ApelinCore.JSONValue(encoding: edit)) ?? .null])
        // The repository the host matches an agent's gitRepositoryCreate to
        // (AgentRepositoryCreateRules).
        case let .repositoryCreate(repository):
            payload["detail"] = .object(["repositoryCreate": (try? ApelinCore.JSONValue(encoding: repository)) ?? .null])
        // The repository and issue the host matches an agent's
        // gitIssueCreate to (AgentIssueCreateRules).
        case let .issueCreate(issue):
            payload["detail"] = .object(["issueCreate": (try? ApelinCore.JSONValue(encoding: issue)) ?? .null])
        // The project the host matches an agent's projectDelete to
        // (AgentProjectDeleteRules).
        case let .projectDelete(deletion):
            payload["detail"] = .object(["projectDelete": (try? ApelinCore.JSONValue(encoding: deletion)) ?? .null])
        // The repository, files and digests the host matches an agent's
        // distributionPublish to (AgentPublishRules).
        case let .packagePublish(publication):
            payload["detail"] = .object(["packagePublish": (try? ApelinCore.JSONValue(encoding: publication)) ?? .null])
        // The project, repository, tag, commit, notes, files and digests the
        // host matches an agent's distributionRelease to (AgentReleaseRules).
        case let .packageRelease(release):
            payload["detail"] = .object(["packageRelease": (try? ApelinCore.JSONValue(encoding: release)) ?? .null])
        // What the host matches an agent's readUITree, uiAction or
        // agentRunCode to while Ask Before Using the Screen is on
        // (AgentScreenRules).
        case let .screenControl(use):
            payload["detail"] = .object(screenDetail(use))
        // The state the host matches an agent's gitResetToRemote to
        // (AgentResetToRemoteRules).
        case let .resetToRemote(reset):
            payload["detail"] = .object(["resetToRemote": (try? ApelinCore.JSONValue(encoding: reset)) ?? .null])
        // The question the app shows in the card's place; the host matches
        // nothing to it, since the answer reaches only the model.
        case let .question(question):
            payload["detail"] = .object([AgentQuestionRules.detailKey: (try? ApelinCore.JSONValue(encoding: question)) ?? .null])
        // The mode a run asks to go to and the reason on the card; the host
        // matches nothing to it either.
        case let .runMode(runMode):
            payload["detail"] = .object([AgentRunModeRules.detailKey: (try? ApelinCore.JSONValue(encoding: runMode)) ?? .null])
        }
        return .object(payload)
    }

    /// `detail` of a screen card: `screenControl` {operation, request?},
    /// the tree read or the action as `ChannelHostBackend` sends it to the
    /// host, and a command's own `command` — `rootCommand` as root — as any
    /// shell_run card has it, which the app's card shows. A request that
    /// would not reach the host (an element with nothing to tap it by) is
    /// left out, so no approval covers it.
    static func screenDetail(_ use: ScreenControlApproval) -> [String: ApelinCore.JSONValue] {
        func marker(_ operation: AppOperation, request: ApelinCore.JSONValue? = nil) -> ApelinCore.JSONValue {
            var marker: [String: ApelinCore.JSONValue] = ["operation": .string(operation.rawValue)]
            marker["request"] = request
            return .object(marker)
        }
        switch use {
        case let .readTree(targetID):
            let request = try? ApelinCore.JSONValue(encoding: ApelinProtocol.ReadUITreeRequest(targetID: targetID))
            return [ScreenConsent.detailKey: marker(.readUITree, request: request)]
        case let .interact(targetID, action):
            let request = (try? ChannelHostBackend.action(action)).flatMap { wire in
                try? ApelinCore.JSONValue(encoding: ApelinProtocol.UIActionRequest(targetID: targetID, action: wire))
            }
            return [ScreenConsent.detailKey: marker(.uiAction, request: request)]
        case let .command(invocation, asRoot):
            let key = asRoot ? RunCodeApproval.rootCommandDetail : "command"
            return [
                ScreenConsent.detailKey: marker(.agentRunCode),
                key: (try? ApelinCore.JSONValue(encoding: invocation)) ?? .null,
            ]
        }
    }

    static func decisionName(_ decision: ApelinAgent.ApprovalDecision) -> String {
        switch decision {
        case .approve: "approve"
        case .deny: "deny"
        }
    }
}
