import ApelinAgent
@testable import ApelinAgentWorker
import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

/// What a sign-in told the host, in order.
final class SignInRecorder: @unchecked Sendable {
    struct Event: Equatable {
        var kind: String
        var payload: ApelinCore.JSONValue?
    }

    private let lock = NSLock()
    private var recorded: [Event] = []
    private var ended: (TaskState, String?)?

    var reporter: SignInReporter {
        SignInReporter(
            emit: { [self] _, kind, payload in lock.withLock { recorded.append(Event(kind: kind, payload: payload)) } },
            finish: { [self] _, state, message in lock.withLock { ended = (state, message) } },
        )
    }

    var events: [Event] {
        lock.withLock { recorded }
    }

    var state: TaskState? {
        lock.withLock { ended?.0 }
    }

    var message: String? {
        lock.withLock { ended?.1 }
    }

    /// Everything the host was told, as one string, for "no secret in it".
    var transcript: String {
        lock.withLock {
            let lines = recorded.map { event -> String in
                let payload = event.payload.flatMap { try? JSONCoding.encode($0) }.flatMap { String(data: $0, encoding: .utf8) }
                return "\(event.kind) \(payload ?? "")"
            }
            return (lines + [ended?.1 ?? ""]).joined(separator: "\n")
        }
    }

    func waitFor(_ condition: @escaping (SignInRecorder) -> Bool) async throws {
        for _ in 0 ..< 500 {
            if condition(self) {
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("timed out waiting; events \(events.map(\.kind)), state \(String(describing: state))")
    }
}

/// A loopback that never hears from a browser: the paste is the only way in.
/// Its wait ends when its task is cancelled, as kwwk's listener's does,
/// even when the cancel came first: a wait that starts after the sign-in
/// was cancelled or the paste won must not keep the sign-in alive.
final class SilentListener: OAuthLoopbackListener, @unchecked Sendable {
    let redirectURI: String
    private let lock = NSLock()
    private var waiter: CheckedContinuation<[String: String], Error>?
    private(set) var stopped = false

    init(host: String, port: UInt16, path: String) {
        redirectURI = "http://\(host):\(port)\(path)"
    }

    func listen() async throws {}

    func waitForCallback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Decided under the lock the cancel handler takes: a cancel
                // that ran before this found no waiter to resume.
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled {
                        return true
                    }
                    waiter = continuation
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let waiter = lock.withLock { () -> CheckedContinuation<[String: String], Error>? in
                defer { self.waiter = nil }
                return self.waiter
            }
            waiter?.resume(throwing: CancellationError())
        }
    }

    func stop() {
        lock.withLock { stopped = true }
    }
}

/// 模拟凭据删除第一次失败、后续重试成功的钥匙串存储。
actor RemovalRefusedOnce: CredentialSource {
    private var entries: [String: OAuthCredentials]
    private(set) var removals = 0

    init(_ entries: [String: OAuthCredentials]) {
        self.entries = entries
    }

    func providerIds() -> [String] {
        entries.keys.sorted()
    }

    func credentials(for providerId: String) -> OAuthCredentials? {
        entries[providerId]
    }

    func store(_ credentials: OAuthCredentials, for providerID: String) {
        entries[providerID] = credentials
    }

    func remove(_ providerID: String) throws {
        removals += 1
        guard removals > 1 else { throw POSIXError(.EIO) }
        entries.removeValue(forKey: providerID)
    }
}

@Suite("Sign-in: kwwk's flows in apelin-agent, nothing secret on the wire", .timeLimit(.minutes(1)))
struct AccountDeskTests {
    static let silent: OAuthLoopbackFactory = { SilentListener(host: $0, port: $1, path: $2) }

    /// What a provider hands back: the strings no event may carry.
    static let issued = OAuthCredentials(access: "tok-access-SECRET", refresh: "tok-refresh-SECRET", expires: 4_102_444_800_000)

    /// GitHub's device flow as kwwk runs it, against nobody: the code, then
    /// the page, then the poll that answers once `approve` is called.
    static func deviceFlow(_ approval: AsyncStream<Void>) -> SignInLogin {
        { provider, callbacks, _ in
            #expect(provider == .githubCopilot)
            let code = OAuthLogin.DeviceCode(
                code: "ABCD-1234",
                verificationURL: URL(string: "https://github.com/login/device")!,
                pageHoldsCode: false,
            )
            await callbacks.onDeviceCode?(code)
            return try await callbacks.browser!.run(code.verificationURL) {
                for await _ in approval {
                    return issued
                }
                throw CancellationError()
            }
        }
    }

    /// Anthropic's PKCE flow as kwwk runs it: a loopback on the registered
    /// port, the authorize page, the redirect's state checked.
    static let browserFlow: SignInLogin = { provider, callbacks, _ in
        #expect(provider == .anthropicOAuth)
        let listener = try callbacks.loopback("localhost", 53692, "/callback")
        try await listener.listen()
        defer { listener.stop() }
        let page = URL(string: "https://claude.ai/oauth/authorize?state=s1&redirect_uri=\(listener.redirectURI)")!
        let parameters = try await callbacks.browser!.run(page) { try await listener.waitForCallback() }
        guard parameters["state"] == "s1", parameters["code"] == "c1" else {
            throw OAuthError.invalidResponse("anthropic OAuth state mismatch")
        }
        return issued
    }

    static let neverCalled: SignInLogin = { _, _, _ in
        Issue.record("an API-key sign-in ran a kwwk flow")
        throw CancellationError()
    }

    @Test
    func `a device flow shows its code and page, stores what GitHub issued, and says nothing secret`() async throws {
        let (approval, approve) = AsyncStream<Void>.makeStream()
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.deviceFlow(approval), listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .githubCopilot), taskID: TaskID("t1"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events == [SignInRecorder.Event(kind: "deviceCode", payload: .object([
            "code": .string("ABCD-1234"),
            "verificationURL": .string("https://github.com/login/device"),
            "pageHoldsCode": .bool(false),
        ]))])

        // A device flow takes nothing from the app.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("t1"), fields: [.apiKey: "x"]))
        }

        approve.yield()
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "github-copilot") == Self.issued)
        #expect(!recorder.transcript.contains("SECRET"))

        let listed = await desk.list().accounts
        #expect(listed.map(\.provider) == AgentProvider.signInOrder)
        #expect(listed.first { $0.provider == .githubCopilot }?.signedIn == true)
        #expect(listed.first { $0.provider == .githubCopilot }?.models?.isEmpty == false)
        #expect(listed.filter(\.signedIn).map(\.provider) == [.githubCopilot])
    }

    @Test
    func `a browser flow names its page, and a pasted redirect finishes it when the loopback hears nothing`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.browserFlow, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .anthropicOAuth), taskID: TaskID("t2"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events.map(\.kind) == ["authorize"])
        #expect(recorder.events[0].payload?["acceptsCallbackURL"] == .bool(true))
        #expect(recorder.events[0].payload?["url"]?.stringValue?.hasPrefix("https://claude.ai/oauth/authorize") == true)

        // Not a redirect: refused, and the sign-in goes on waiting.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("t2"), fields: [.callbackURL: "hello"]))
        }
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("t2"), fields: [.apiKey: "k"]))
        }
        #expect(recorder.state == nil)

        try await desk.respond(AgentSignInRespondRequest(
            taskID: TaskID("t2"),
            fields: [.callbackURL: "http://localhost:53692/callback?code=c1&state=s1"],
        ))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "anthropic") == Self.issued)
        #expect(!recorder.transcript.contains("SECRET"))
        #expect(!recorder.transcript.contains("c1&"))
    }

    /// Trae's and Raccoon's own logins, kwwk's: each page takes any
    /// loopback address, so the listener is asked for port 0 and the page
    /// is given the address it names. Cancelled before a code would be
    /// exchanged, so nothing here reaches the network. (The international
    /// Trae asks its gate where its page is first, so it is not started.)
    @Test(arguments: [
        (AgentProvider.trae, "127.0.0.1:0/authorize", "www.trae.cn", "auth_callback_url"),
        (AgentProvider.raccoon, "127.0.0.1:0/auth/callback", "xiaohuanxiong.com", "redirect"),
    ])
    func `Trae CN and Raccoon sign in on a loopback of any port, which a pasted address can stand in for`(
        provider: AgentProvider,
        asked: String,
        host: String,
        redirectParameter: String,
    ) async throws {
        let opened = SignInRecorder()
        let listener: OAuthLoopbackFactory = { host, port, path in
            opened.reporter.emit(TaskID("listener"), "\(host):\(port)\(path)", nil)
            return SilentListener(host: host, port: port, path: path)
        }
        let desk = AccountDesk(store: DeliveredCredentialSource(), login: KWWKSignIn.login, listener: listener, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        #expect(provider.signInMethods == [.browser])
        try await desk.start(AgentSignInRequest(provider: provider), taskID: TaskID("p1"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(opened.events.map(\.kind) == [asked])
        #expect(recorder.events.map(\.kind) == ["authorize"])
        #expect(recorder.events[0].payload?["acceptsCallbackURL"] == .bool(true))
        let page = try #require(recorder.events[0].payload?["url"]?.stringValue.flatMap(URLComponents.init(string:)))
        #expect(page.host == host)
        #expect(page.queryItems?.first { $0.name == redirectParameter }?.value == "http://\(asked)")
        // An address with neither a code nor Trae's `authCodeInfo` is no
        // redirect, and the sign-in goes on waiting.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(
                taskID: TaskID("p1"),
                fields: [.callbackURL: "http://\(asked)?refreshToken=not-a-code"],
            ))
        }
        #expect(recorder.state == nil)
        #expect(await desk.cancel(TaskID("p1")))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .cancelled)
    }

    @Test
    func `a pasted address is a redirect when it carries a code, Trae's auth code or an error`() throws {
        #expect(try PasteableLoopback.parameters(of: "http://localhost:1455/auth/callback?code=c1&state=s1")["code"] == "c1")
        #expect(try PasteableLoopback.parameters(of: "http://127.0.0.1:9/authorize?authCodeInfo=%7B%22AuthCode%22%3A%22a1%22%7D")
            == ["authCodeInfo": #"{"AuthCode":"a1"}"#])
        #expect(try PasteableLoopback.parameters(of: "http://localhost:1/callback?error=access_denied")["error"] == "access_denied")
        for address in ["http://127.0.0.1:9/authorize", "http://127.0.0.1:9/authorize?authCodeInfo=", "hello"] {
            #expect(throws: ApelinError.self) { try PasteableLoopback.parameters(of: address) }
        }
    }

    @Test
    func `an API key is asked for by field, checked by name alone, and stored in kwwk's shape`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        let task = TaskID("t3")
        try await desk.start(AgentSignInRequest(provider: .openAICompatible), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events.map(\.kind) == ["input"])
        let fields = recorder.events[0].payload?["fields"]
        #expect(fields == .array([
            .object(["key": .string("apiKey"), "required": .bool(true), "secure": .bool(true)]),
            .object(["key": .string("baseUrl"), "required": .bool(true), "secure": .bool(false), "placeholder": .string("https://…")]),
            .object(["key": .string("defaultModel"), "required": .bool(true), "secure": .bool(false)]),
            .object([
                "key": .string("apiFormat"), "required": .bool(false), "secure": .bool(false),
                "defaultValue": .string("openai-completions"),
                "options": .array([
                    .object(["value": .string("openai-completions"), "title": .string("Chat Completions")]),
                    .object(["value": .string("openai-responses"), "title": .string("Responses")]),
                ]),
            ]),
        ]))

        // Each refusal names the field and never what was typed.
        let refusals: [[AgentSignInField: String]] = [
            [.apiKey: "sk-SECRET", .baseURL: "https://example.invalid"],
            [.apiKey: "sk-SECRET", .baseURL: "ftp://example.invalid", .defaultModel: "m"],
            [.apiKey: "sk-SECRET", .baseURL: "https://user:pw@example.invalid", .defaultModel: "m"],
            [.apiKey: "sk SECRET", .baseURL: "https://example.invalid", .defaultModel: "m"],
            [.apiKey: "sk-SECRET", .baseURL: "https://example.invalid", .defaultModel: "m", .callbackURL: "x"],
        ]
        for values in refusals {
            do {
                try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: values))
                Issue.record("accepted \(values.keys.map(\.rawValue))")
            } catch let error as ApelinError {
                #expect(error.code == .badRequest)
                #expect(!error.message.contains("SECRET"))
            }
        }
        #expect(recorder.state == nil)

        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [
            .apiKey: " sk-SECRET\n", .baseURL: "https://llm.example.invalid/v1", .defaultModel: "test-model",
        ]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let stored = try #require(try await store.credentials(for: "openai-compatible"))
        #expect(stored.access == "sk-SECRET")
        #expect(stored.refresh.isEmpty && stored.expires == .max)
        #expect(stored.extras["baseUrl"] == .string("https://llm.example.invalid/v1"))
        #expect(stored.extras["defaultModel"] == .string("test-model"))
        #expect(!recorder.transcript.contains("SECRET"))

        let account = await desk.list().accounts.first { $0.provider == .openAICompatible }
        #expect(account?.signedIn == true)
        #expect(account?.account == "llm.example.invalid")
        #expect(account?.models == ["test-model"])

        // A second answer to an ended sign-in finds nothing waiting.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "again"]))
        }

        try await desk.signOut(.openAICompatible)
        #expect(try await store.credentials(for: "openai-compatible") == nil)
        #expect(await desk.list().accounts.allSatisfy { !$0.signedIn })
        // Signing out of nothing is no error.
        try await desk.signOut(.openAICompatible)
    }

    @Test
    func `Anthropic's key needs no endpoint, and its default is the account label`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: TaskID("t4"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events[0].payload?["fields"] == .array([
            .object([
                "key": .string("apiKey"), "required": .bool(true), "secure": .bool(true),
                "placeholder": .string("sk-ant-api03-…"),
            ]),
            .object([
                "key": .string("baseUrl"), "required": .bool(false), "secure": .bool(false),
                "defaultValue": .string("https://api.anthropic.com"),
            ]),
        ]))
        try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("t4"), fields: [.apiKey: "sk-ant-SECRET", .baseURL: ""]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "anthropic-api-key")?.extras.isEmpty == true)
        let account = await desk.list().accounts.first { $0.provider == .anthropic }
        #expect(account?.account == "api.anthropic.com")
        #expect(account?.expiresAt == nil)
    }

    @Test
    func `a candidate key is saved only after its model answers`() async throws {
        let store = DeliveredCredentialSource()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (reply, answer) = AsyncStream<Void>.makeStream()
        let desk = AccountDesk(store: store, verifyKey: { provider, credentials, _ in
            #expect(provider == .anthropic)
            #expect(credentials.access == "candidate")
            didStart.yield()
            for await _ in reply {
                return
            }
            throw CancellationError()
        })
        let recorder = SignInRecorder()
        let task = TaskID("verification-waits")
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        let response = Task { try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "candidate"])) }
        for await _ in started {
            break
        }
        #expect(await store.providerIds().isEmpty)
        #expect(recorder.state == nil)
        answer.yield()
        try await response.value
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "anthropic-api-key")?.access == "candidate")
        #expect(!recorder.transcript.contains("candidate"))
    }

    @Test
    func `failed verification preserves the saved key and the form accepts another answer`() async throws {
        let old = OAuthCredentials(access: "previous", refresh: "", expires: .max)
        let store = DeliveredCredentialSource(["anthropic-api-key": old])
        let desk = AccountDesk(store: store, verifyKey: { _, credentials, _ in
            if credentials.access == "rejected" {
                throw ApelinError(.unavailable, "Verification failed.")
            }
        })
        let recorder = SignInRecorder()
        let task = TaskID("verification-retry")
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "rejected"]))
        }
        #expect(recorder.state == nil)
        #expect(try await store.credentials(for: "anthropic-api-key") == old)
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "accepted"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "anthropic-api-key")?.access == "accepted")
    }

    @Test
    func `cancelling a verification never saves its late reply`() async throws {
        let store = DeliveredCredentialSource()
        let (started, didStart) = AsyncStream<Void>.makeStream()
        let (reply, answer) = AsyncStream<Void>.makeStream()
        let desk = AccountDesk(store: store, verifyKey: { _, _, _ in
            didStart.yield()
            for await _ in reply {
                return
            }
        })
        let recorder = SignInRecorder()
        let task = TaskID("verification-cancel")
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        let response = Task { try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "candidate"])) }
        for await _ in started {
            break
        }
        #expect(await desk.cancel(task))
        answer.yield()
        await #expect(throws: CancellationError.self) { try await response.value }
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .cancelled)
        #expect(await store.providerIds().isEmpty)
    }

    @Test
    func `a cancel ends the sign-in cancelled and stores nothing`() async throws {
        let (approval, _) = AsyncStream<Void>.makeStream()
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.deviceFlow(approval), listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .githubCopilot), taskID: TaskID("t5"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(await desk.cancel(TaskID("other")) == false)
        #expect(await desk.cancel(TaskID("t5")))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .cancelled)
        #expect(await store.providerIds().isEmpty)
    }

    @Test
    func `the app configuration editor receives saved API fields without adding secrets to account listings`() async throws {
        let credentials = OAuthCredentials(access: "test-saved-key", refresh: "", expires: .max,
                                           extras: ["baseUrl": .string("https://custom.example/v1"), "defaultModel": .string("saved-model")])
        let store = DeliveredCredentialSource(["anthropic-api-key": credentials, "github-copilot": Self.issued])
        let desk = AccountDesk(store: store)
        let configuration = try await desk.apiConfiguration(for: .anthropic)
        #expect(configuration.values == ["apiKey": "test-saved-key", "baseUrl": "https://custom.example/v1"])
        let listing = try await JSONCoding.encode(desk.list())
        #expect(!String(decoding: listing, as: UTF8.self).contains("test-saved-key"))
        await #expect(throws: ApelinError.self) { try await desk.apiConfiguration(for: .githubCopilot) }
        await #expect(throws: ApelinError.self) { try await desk.apiConfiguration(for: .openAI) }
        let defaultDesk = AccountDesk(store: DeliveredCredentialSource([
            "anthropic-api-key": OAuthCredentials(access: "test-default-key", refresh: "", expires: .max),
        ]))
        let defaults = try await defaultDesk.apiConfiguration(for: .anthropic)
        #expect(defaults.values["baseUrl"] == "https://api.anthropic.com")
    }

    @Test
    func `model activation probes the selected custom IDs and reports a refusal without secrets`() async throws {
        let credentials = OAuthCredentials(access: "SECRET", refresh: "", expires: .max)
        let store = DeliveredCredentialSource(["anthropic-api-key": credentials])
        let desk = AccountDesk(store: store, verifyKey: { provider, value, model in
            #expect(provider == .anthropic)
            #expect(value.access == "SECRET")
            if model == "denied-model" {
                throw ApelinError(.unavailable, "SECRET response")
            }
            #expect(model == "custom-model")
        })
        let recorder = SignInRecorder()
        try await desk.activateModels(AgentModelActivateRequest(provider: .anthropic, models: ["custom-model", "denied-model"]), taskID: TaskID("selected-models"), reporter: recorder.reporter)
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .failed)
        #expect(recorder.events.map(\.kind) == ["modelVerified"])
        #expect(recorder.message?.contains("denied-model") == true)
        #expect(!recorder.transcript.contains("SECRET"))
        #expect(await store.credentials(for: "anthropic-api-key") == credentials)
    }

    @Test
    func `cancelling model activation stops before accepting a late model response`() async throws {
        let store = DeliveredCredentialSource(["anthropic-api-key": Self.issued])
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (replies, reply) = AsyncStream<Void>.makeStream()
        let desk = AccountDesk(store: store, verifyKey: { _, _, _ in
            signal.yield()
            for await _ in replies {
                return
            }
        })
        let recorder = SignInRecorder()
        let task = TaskID("cancel-models")
        try await desk.activateModels(AgentModelActivateRequest(provider: .anthropic, models: ["custom"]), taskID: task, reporter: recorder.reporter)
        for await _ in started {
            break
        }
        #expect(await desk.cancel(task))
        reply.yield()
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .cancelled)
        #expect(recorder.events.isEmpty)
    }

    @Test
    func `站点停用 Chat Completions 时登录自动换用 Responses 并保存该格式`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, verifyKey: { _, credentials, _ in
            let saved: String? = if case let .string(value)? = credentials.extras[AgentSignInField.apiFormat.rawValue] {
                value
            } else {
                nil
            }
            if saved != AgentAPIFormat.responses.rawValue {
                throw ProviderEndpointRequirement.responsesOnly
            }
        })
        let recorder = SignInRecorder()
        let task = TaskID("switch-format-sign-in")
        try await desk.start(AgentSignInRequest(provider: .openAICompatible), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [
            .apiKey: "candidate",
            .baseURL: "https://relay.example.com",
            .defaultModel: "gpt-6.1-sol",
        ]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let saved = try #require(try await store.credentials(for: CredentialProviderID.openAICompatible))
        #expect(saved.extras[AgentSignInField.apiFormat.rawValue] == .string(AgentAPIFormat.responses.rawValue))
        #expect(saved.extras[AgentSignInField.baseURL.rawValue] == .string("https://relay.example.com"))
    }

    @Test
    func `站点停用 Chat Completions 时模型验证自动换用 Responses 并保存该格式`() async throws {
        var credentials = OAuthCredentials(access: "SECRET", refresh: "", expires: .max)
        credentials.extras[AgentSignInField.baseURL.rawValue] = .string("https://relay.example.com")
        credentials.extras[AgentSignInField.defaultModel.rawValue] = .string("gpt-6.1-sol")
        let store = DeliveredCredentialSource([CredentialProviderID.openAICompatible: credentials])
        let desk = AccountDesk(store: store, verifyKey: { _, value, _ in
            let saved: String? = if case let .string(format)? = value.extras[AgentSignInField.apiFormat.rawValue] {
                format
            } else {
                nil
            }
            if saved != AgentAPIFormat.responses.rawValue {
                throw ProviderEndpointRequirement.responsesOnly
            }
        })
        let recorder = SignInRecorder()
        try await desk.activateModels(
            AgentModelActivateRequest(provider: .openAICompatible, models: ["gpt-6.1-sol"]),
            taskID: TaskID("switch-format-models"),
            reporter: recorder.reporter,
        )
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(recorder.events.map(\.kind) == ["modelVerified"])
        let saved = try #require(try await store.credentials(for: CredentialProviderID.openAICompatible))
        #expect(saved.extras[AgentSignInField.apiFormat.rawValue] == .string(AgentAPIFormat.responses.rawValue))
        #expect(saved.access == "SECRET")
    }

    @Test
    func `API-key setup can defer probing until the selected models are saved`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, verifyKey: { _, _, _ in Issue.record("setup probed an unselected default model") })
        let recorder = SignInRecorder()
        let task = TaskID("deferred-probe")
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "candidate"], verifyModel: false))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(await desk.list().accounts.first { $0.provider == .anthropic }?.isAPIKeyAccount == true)
    }

    @Test
    func `a new sign-in ends the one still waiting, which frees its loopback`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.browserFlow, listener: Self.silent, verifyKey: { _, _, _ in })
        let first = SignInRecorder()
        let second = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .anthropicOAuth), taskID: TaskID("t6"), reporter: first.reporter)
        try await first.waitFor { !$0.events.isEmpty }
        try await desk.start(AgentSignInRequest(provider: .anthropicOAuth), taskID: TaskID("t7"), reporter: second.reporter)
        #expect(first.state == .cancelled)
        try await second.waitFor { !$0.events.isEmpty }
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(
                taskID: TaskID("t6"),
                fields: [.callbackURL: "http://localhost:53692/callback?code=c1&state=s1"],
            ))
        }
        #expect(await desk.cancel(TaskID("t7")))
        try await second.waitFor { $0.state != nil }
        #expect(second.state == .cancelled)
    }

    @Test
    func `a sign-in left alone ends failed at its deadline`() async throws {
        let desk = AccountDesk(store: DeliveredCredentialSource(), login: Self.neverCalled, listener: Self.silent, timeoutSeconds: 0.2, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .anthropic), taskID: TaskID("t8"), reporter: recorder.reporter)
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .failed)
        #expect(recorder.message?.contains("in time") == true)
    }

    @Test
    func `a sign-in only lapses when nothing renews it`() {
        #expect(AccountDesk.lapses(Self.issued) == nil)
        #expect(AccountDesk.lapses(OAuthCredentials(access: "k", refresh: "", expires: .max)) == nil)
        #expect(AccountDesk.lapses(OAuthCredentials(access: "k", refresh: "", expires: 1000)) == Date(timeIntervalSince1970: 1))
    }

    // MARK: - Several OpenAI-compatible endpoints (#60)

    @Test
    func `the list always has one OpenAI-compatible endpoint to add, after those signed in to`() {
        let first = CredentialProviderID.openAICompatible
        func listed(_ stored: [String]) -> [String] {
            AccountDesk.listed(.openAICompatible, stored: Set(stored)).map(\.rawValue)
        }
        #expect(listed([]) == ["openAICompatible"])
        #expect(listed([first]) == ["openAICompatible", "openAICompatible.2"])
        #expect(listed([first, "openai-compatible.2", "openai-compatible.4"])
            == ["openAICompatible", "openAICompatible.2", "openAICompatible.4", "openAICompatible.3"])
        // The first one, signed out of, is the one to add again.
        #expect(listed(["openai-compatible.2"]) == ["openAICompatible.2", "openAICompatible"])
        // Another provider's item, or a spelling that names no endpoint, is none.
        #expect(listed([first, "openai-compatible.02", "openai-compatible.1", "openai-compatible.x", "openai-codex"])
            == ["openAICompatible", "openAICompatible.2"])
        #expect(AccountDesk.listed(.deepSeek, stored: [first]) == [.deepSeek])
        #expect(AgentProvider.openAICompatibleEndpoint(7).storeID == "openai-compatible.7")
        #expect(CredentialProviderID.endpointNumber("openai-compatible.7") == 7)
        #expect(CredentialProviderID.endpointNumber(first) == nil)
        #expect(CredentialInbox.isKnown("openai-compatible.7") && !CredentialInbox.isKnown("openai-compatible.100"))
    }

    @Test
    func `a second OpenAI-compatible endpoint signs in beside the first, with a key, address and models of its own`() async throws {
        let first = OAuthCredentials(access: "sk-FIRST-SECRET", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://one.example.invalid/v1"), "defaultModel": .string("model-one"),
        ])
        let store = DeliveredCredentialSource([CredentialProviderID.openAICompatible: first])
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        func endpoints() async -> [AgentAccount] {
            await desk.list().accounts.filter { $0.provider.kind == .openAICompatible }
        }
        let second = AgentProvider.openAICompatibleEndpoint(2)
        let offered = await endpoints()
        #expect(offered.map(\.provider) == [.openAICompatible, second])
        #expect(offered.map(\.signedIn) == [true, false])
        #expect(offered[1].method == .apiKey)

        let recorder = SignInRecorder()
        let task = TaskID("endpoint-2")
        try await desk.start(AgentSignInRequest(provider: second), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        // The first endpoint's form.
        #expect(recorder.events[0].payload?["fields"] == .array([
            .object(["key": .string("apiKey"), "required": .bool(true), "secure": .bool(true)]),
            .object(["key": .string("baseUrl"), "required": .bool(true), "secure": .bool(false), "placeholder": .string("https://…")]),
            .object(["key": .string("defaultModel"), "required": .bool(true), "secure": .bool(false)]),
            .object([
                "key": .string("apiFormat"), "required": .bool(false), "secure": .bool(false),
                "defaultValue": .string("openai-completions"),
                "options": .array([
                    .object(["value": .string("openai-completions"), "title": .string("Chat Completions")]),
                    .object(["value": .string("openai-responses"), "title": .string("Responses")]),
                ]),
            ]),
        ]))
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [
            .apiKey: "sk-SECOND-SECRET", .baseURL: "https://two.example.invalid/v1", .defaultModel: "model-two",
        ]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(!recorder.transcript.contains("SECRET"))
        #expect(try await store.credentials(for: "openai-compatible") == first)
        let stored = try #require(try await store.credentials(for: "openai-compatible.2"))
        #expect(stored.access == "sk-SECOND-SECRET")
        #expect(stored.extras["baseUrl"] == .string("https://two.example.invalid/v1"))

        let listed = await endpoints()
        #expect(listed.map(\.provider) == [.openAICompatible, second, .openAICompatibleEndpoint(3)])
        #expect(listed.map(\.account) == ["one.example.invalid", "two.example.invalid", nil])
        #expect(listed.map(\.models) == [["model-one"], ["model-two"], nil])
        #expect(try await desk.apiConfiguration(for: second).values["baseUrl"] == "https://two.example.invalid/v1")
        #expect(try await desk.apiConfiguration(for: .openAICompatible).values["apiKey"] == "sk-FIRST-SECRET")

        // Signing out of the first leaves the second, and the first is the one to add.
        try await desk.signOut(.openAICompatible)
        #expect(try await store.credentials(for: "openai-compatible.2") == stored)
        let left = await endpoints()
        #expect(left.map(\.provider) == [second, .openAICompatible])
        #expect(left.map(\.signedIn) == [true, false])
    }

    @Test
    func `each OpenAI-compatible endpoint resolves to its own address and key`() async throws {
        func endpoint(_ key: String, _ host: String, _ model: String) -> OAuthCredentials {
            OAuthCredentials(access: key, refresh: "", expires: .max, extras: [
                "baseUrl": .string("https://\(host)/v1"), "defaultModel": .string(model),
            ])
        }
        let manager = OAuthManager(source: DeliveredCredentialSource([
            "openai-compatible": endpoint("sk-one", "one.example.invalid", "model-one"),
            "openai-compatible.2": endpoint("sk-two", "two.example.invalid", "model-two"),
        ]))
        let one = try #require(try await ProviderRegistration.resolve(storeID: "openai-compatible", manager: manager))
        let two = try #require(try await ProviderRegistration.resolve(
            storeID: "openai-compatible.2",
            manager: manager,
            modelOverride: "model-b",
        ))
        #expect(one.model.baseURL == "https://one.example.invalid/v1" && one.model.id == "model-one")
        #expect(two.model.baseURL == "https://two.example.invalid/v1" && two.model.id == "model-b")
        #expect(one.model.api == two.model.api && one.model.provider == two.model.provider)
        // Resolving one after the other leaves each its own key.
        #expect(try await two.authResolver?(two.model, nil)?.token == "sk-two")
        #expect(try await one.authResolver?(one.model, nil)?.token == "sk-one")
        // An endpoint nobody signed in to resolves to nothing.
        #expect(try await ProviderRegistration.resolve(storeID: "openai-compatible.3", manager: manager) == nil)
        // An endpoint that speaks the Responses API resolves to kwwk's
        // `openai-responses` transport; one saved before the field existed
        // still speaks Chat Completions.
        let responses = OAuthCredentials(access: "sk-r", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://resp.example.invalid/v1"), "defaultModel": .string("r-model"),
            "apiFormat": .string("openai-responses"),
        ])
        let responsesManager = OAuthManager(source: DeliveredCredentialSource([
            "openai-compatible.3": responses,
        ]))
        let routed = try #require(try await ProviderRegistration.resolve(
            storeID: "openai-compatible.3",
            manager: responsesManager,
        ))
        #expect(routed.model.api == "openai-responses")
        #expect(routed.model.provider == one.model.provider)
        #expect(try await routed.authResolver?(routed.model, nil)?.token == "sk-r")
    }

    @Test
    func `Azure 的端点校验、模型发现与两种传输使用同一版本和鉴权`() async throws {
        let base = "https://sample.openai.azure.com/openai/deployments/example/chat/completions?api-version=2025-04-01-preview"
        let fields: [AgentSignInField: String] = [.apiKey: "test-key", .baseURL: base, .defaultModel: "example", .azure: "true"]
        var plainFields = fields
        plainFields[.azure] = "false"
        #expect(throws: ApelinError.self) { try AccountDesk.validated(plainFields, for: .openAICompatible) }
        var unknownQuery = fields
        unknownQuery[.baseURL] = base + "&unknown=yes"
        #expect(throws: ApelinError.self) { try AccountDesk.validated(unknownQuery, for: .openAICompatible) }

        for format in AgentAPIFormat.allCases {
            var values = fields
            values[.apiFormat] = format.rawValue
            let accepted = try AccountDesk.validated(values, for: .openAICompatible)
            #expect(accepted[.baseURL] == base)
            let credentials = AccountDesk.apiKeyCredentials(accepted)
            let discovery = try #require(ProviderModels.modelRequest(.openAICompatible, credentials: credentials))
            #expect(discovery.url?.path == "/openai/models")
            #expect(discovery.url?.query == "api-version=2025-04-01-preview")
            #expect(discovery.value(forHTTPHeaderField: "api-key") == "test-key")
            #expect(discovery.value(forHTTPHeaderField: "Authorization") == nil)

            let storeID = "openai-compatible"
            let manager = OAuthManager(source: DeliveredCredentialSource([storeID: credentials]))
            let resolved = try #require(try await ProviderRegistration.resolve(storeID: storeID, manager: manager))
            #expect(resolved.model.api == format.rawValue)
            #expect(await APIRegistry.shared.provider(scope: resolved.model.provider, api: resolved.model.api) != nil)
            let auth = try #require(try await resolved.authResolver?(resolved.model, nil))
            guard case let .apiKeyHeader(name: header) = auth.scheme, header == "api-key" else {
                Issue.record("Azure 应使用 api-key，而不是 Bearer 鉴权")
                continue
            }
            #expect(auth.token == "test-key")
            let url = try #require(ProviderRegistration.azureEndpoint(resolved.model.baseURL, format: format, deployment: "example"))
            let path = format == .chatCompletions ? "/openai/deployments/example/chat/completions" : "/openai/responses"
            #expect(url.path == path)
            #expect(url.query == "api-version=2025-04-01-preview")
        }
    }

    @Test
    func `the interface format is validated, stored and restored for an OpenAI-compatible endpoint`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        let task = TaskID("api-format")
        try await desk.start(AgentSignInRequest(provider: .openAICompatible), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [
                .apiKey: "sk-SECRET", .baseURL: "https://llm.example.invalid/v1",
                .defaultModel: "m", .apiFormat: "not-a-format",
            ]))
        }
        #expect(recorder.state == nil)
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [
            .apiKey: "sk-SECRET", .baseURL: "https://llm.example.invalid/v1",
            .defaultModel: "m", .apiFormat: "openai-responses",
        ]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let saved = try #require(try await store.credentials(for: "openai-compatible"))
        #expect(saved.extras["apiFormat"] == .string("openai-responses"))
        let configuration = try await desk.apiConfiguration(for: .openAICompatible)
        #expect(configuration.values["apiFormat"] == "openai-responses")
        // A credential saved before the field existed reads as Chat Completions.
        let old = OAuthCredentials(access: "sk-old", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://old.example.invalid/v1"), "defaultModel": "m",
        ])
        let oldDesk = AccountDesk(store: DeliveredCredentialSource(["openai-compatible": old]))
        #expect(try await oldDesk.apiConfiguration(for: .openAICompatible).values["apiFormat"] == "openai-completions")
    }

    @Test
    func `interface options are validated, stored and restored for a compatible endpoint`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        let task = TaskID("endpoint-options")
        try await desk.start(AgentSignInRequest(provider: .openAICompatible), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [
                .apiKey: "sk-SECRET", .baseURL: "https://llm.example.invalid",
                .defaultModel: "m", .imageEndpointMode: "bogus",
            ]))
        }
        #expect(recorder.state == nil)
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [
            .apiKey: "sk-SECRET", .baseURL: "https://llm.example.invalid",
            .defaultModel: "m", .appendV1: "false",
            .customUserAgent: "claude-cli/1.0 (iOS)", .azure: "true",
            .imageEndpointMode: "chat_completions",
        ]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let saved = try #require(try await store.credentials(for: "openai-compatible"))
        #expect(saved.extras[AgentSignInField.appendV1.rawValue] == .string("false"))
        #expect(saved.extras[AgentSignInField.customUserAgent.rawValue] == .string("claude-cli/1.0 (iOS)"))
        #expect(saved.extras[AgentSignInField.azure.rawValue] == .string("true"))
        #expect(saved.extras[AgentSignInField.imageEndpointMode.rawValue] == .string("chat_completions"))
    }

    /// 已退役服务商留下的凭据在首次账号列表读取时删除，其他登录保持不变。
    @Test
    func `the first list deletes a retired provider's sign-in and keeps every other`() async throws {
        let retired = OAuthCredentials(access: "retired-SECRET", refresh: "retired-refresh-SECRET", expires: 4_102_444_800_000)
        let store = DeliveredCredentialSource([
            "antigravity": retired,
            "agy": retired,
            "github-copilot": Self.issued,
        ])
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let listed = await desk.list().accounts
        #expect(await store.providerIds() == ["github-copilot"])
        #expect(listed.map(\.provider) == AgentProvider.signInOrder)
        #expect(listed.filter(\.signedIn).map(\.provider) == [.githubCopilot])
        _ = await desk.list()
        #expect(try await store.credentials(for: "github-copilot") == Self.issued)
    }

    @Test
    func `a failed retired sign-in deletion is retried on the next list`() async {
        let store = RemovalRefusedOnce(["antigravity": Self.issued, "agy": Self.issued])
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        _ = await desk.list()
        #expect(await store.providerIds() == ["antigravity"])
        _ = await desk.list()
        #expect(await store.providerIds().isEmpty)
        _ = await desk.list()
        #expect(await store.removals == 3)
    }

    @Test
    func `retired sign-in IDs are not owned by current providers or the kwwk catalogs`() {
        let current = Set(AgentProvider.allCases.map(\.storeID))
        let kwwk = Set(providerDirectory.map(\.storeId)).union(OAuthSubscriptions.providers.map(\.id))
        for retired in AgentProvider.retired {
            #expect(!current.contains(retired.storeID))
            #expect(CredentialProviderID.endpointNumber(retired.storeID) == nil)
            #expect(!kwwk.contains(retired.storeID))
            #expect(!CredentialInbox.isKnown(retired.storeID))
        }
    }

    @Test
    func `every provider maps to the store id its session reads`() {
        #expect(Set(AgentProvider.allCases.map(\.storeID)) == CredentialInbox.knownProviders)
        #expect(Set(AgentProvider.allCases.map(\.storeID)).count == AgentProvider.allCases.count)
        #expect(Set(AgentProvider.signInOrder) == Set(AgentProvider.allCases))
        #expect(AgentProvider.signInOrder.count == AgentProvider.allCases.count)
    }

    // MARK: - The narrower list

    /// A store that lists an id it cannot read back, as a keychain item that
    /// no longer decodes does.
    actor UnreadableCredentialSource: CredentialSource {
        private let ids: [String]
        init(_ ids: [String]) { self.ids = ids }
        func providerIds() -> [String] { ids }
        func credentials(for providerId: String) -> OAuthCredentials? { nil }
        func store(_ credentials: OAuthCredentials, for providerID: String) {}
        func remove(_ providerID: String) {}
    }

    /// What the composer asks for: one model list per account, nothing else.
    /// The asked-for models stand exactly as asked — a live provider's own
    /// list is where its models come from, and it names models no bundled
    /// catalog has, so nothing is cut against a catalog.
    @Test
    func `a narrower list answers only the models it was asked for`() async throws {
        let relay = OAuthCredentials(access: "relay-SECRET", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://relay.example.invalid/v1"), "defaultModel": .string("relay-default"),
        ])
        let key = OAuthCredentials(access: "deepseek-SECRET", refresh: "", expires: .max)
        let desk = AccountDesk(store: DeliveredCredentialSource([
            CredentialProviderID.openAICompatible: relay,
            CredentialProviderID.deepSeek: key,
        ]))
        let asked = [
            AgentProvider.openAICompatible.rawValue: ["cn:deepseek-v4.1-flash", "cn:deepseek-v4.1-flash", "", "another"],
        ]
        let narrow = await desk.list(extraModels: asked, onlyExtraModels: true)

        // Every provider is still answered, in kwwk's order, and still signed in.
        #expect(narrow.accounts.map(\.provider) == AgentProvider.signInOrder)
        let relayed = try #require(narrow.accounts.first { $0.provider == .openAICompatible })
        #expect(relayed.signedIn)
        #expect(relayed.models == ["cn:deepseek-v4.1-flash", "another"])
        // An account asked for nothing names no model, and no catalog is read
        // for it: no levels, no tiers, no capabilities.
        let quiet = try #require(narrow.accounts.first { $0.provider == .deepSeek })
        #expect(quiet.signedIn)
        #expect(quiet.models == [])
        #expect(quiet.reasoningEfforts == nil)
        #expect(quiet.serviceTiers == nil)
        #expect(quiet.capabilities == nil)

        // Settings and onboarding read the whole catalogue, as before, with
        // the caller's own models added to it.
        let wide = await desk.list(extraModels: [AgentProvider.openAICompatible.rawValue: ["another"]]).accounts
        let wideRelay = try #require(wide.first { $0.provider == .openAICompatible })
        let wideKey = try #require(wide.first { $0.provider == .deepSeek })
        #expect(wideRelay.models == ["relay-default", "another"])
        #expect(wideKey.models == ["deepseek-flash", "deepseek-v4-pro"])
        #expect(wideKey.capabilities?.isEmpty == false)
    }

    /// A narrower list does not carry the whole catalogue in its other fields
    /// either: the levels and tiers it answers are the ones for the models it
    /// named, while the whole list keeps every field it always had.
    @Test
    func `a narrower list trims the levels and tiers to the models it named`() async throws {
        let subscription = OAuthCredentials(access: "token", refresh: "refresh", expires: 1)
        let desk = AccountDesk(store: DeliveredCredentialSource([
            AgentProvider.openAICodex.storeID: subscription,
        ]))
        let asked = [
            AgentProvider.openAICodex.rawValue: ["gpt-6-sol"],
        ]
        let narrow = await desk.list(extraModels: asked, onlyExtraModels: true).accounts
        let codex = try #require(narrow.first { $0.provider == .openAICodex })
        #expect(codex.models == ["gpt-6-sol"])
        #expect(codex.serviceTiers?.keys.sorted() == ["gpt-6-sol"])
        #expect(codex.reasoningEfforts?.keys.allSatisfy { $0 == "gpt-6-sol" } == true)

        let wide = await desk.list().accounts
        let wideCodex = try #require(wide.first { $0.provider == .openAICodex })
        #expect((wideCodex.serviceTiers?.count ?? 0) > 1)
    }

    /// An item that does not decode stays signed in — Sign Out is how it goes
    /// away — and names no model, in either list.
    @Test
    func `an item that cannot be read stays signed in and names no model`() async throws {
        let desk = AccountDesk(store: UnreadableCredentialSource(["anthropic-api-key", "openai-compatible"]))
        let asked = [AgentProvider.openAICompatible.rawValue: ["asked-model"]]
        for accounts in [
            await desk.list(extraModels: asked, onlyExtraModels: true).accounts,
            await desk.list(extraModels: asked).accounts,
        ] {
            #expect(Set(accounts.filter(\.signedIn).map(\.provider)) == [.anthropic, .openAICompatible])
            for account in accounts where account.signedIn {
                #expect(account.models == nil)
                #expect(account.reasoningEfforts == nil)
                #expect(account.serviceTiers == nil)
                #expect(account.capabilities == nil)
                #expect(account.account == nil)
            }
        }
    }

    // MARK: - Every login kwwk offers

    @Test
    func `DeepSeek signs in with a key alone and signs out independently`() async throws {
        let other = OAuthCredentials(access: "other-SECRET", refresh: "", expires: .max)
        let store = DeliveredCredentialSource([CredentialProviderID.openAICompatible: other])
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { provider, key, _ in
            #expect(provider == .deepSeek)
            #expect(key.access == "deepseek-SECRET")
        })
        let recorder = SignInRecorder()
        let task = TaskID("deepseek-sign-in")
        try await desk.start(AgentSignInRequest(provider: .deepSeek), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(AgentProvider.deepSeek.keyFields.first { $0.field == .baseURL }?.defaultValue == DeepSeekProvider.baseURL)
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "deepseek-SECRET"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let account = try #require(await desk.list().accounts.first { $0.provider == .deepSeek })
        #expect(account.signedIn)
        #expect(account.account == "api.deepseek.com")
        #expect(account.models?.contains("deepseek-flash") == true)
        #expect(!recorder.transcript.contains("SECRET"))
        try await desk.signOut(.deepSeek)
        #expect(try await store.credentials(for: CredentialProviderID.deepSeek) == nil)
        #expect(try await store.credentials(for: CredentialProviderID.openAICompatible) == other)
    }

    /// OpenCode's plans are kwwk's typed-key logins: the key, a default
    /// model left out, and the plan's catalog listed.
    @Test(arguments: [(AgentProvider.openCodeGo, OpenCodePlan.go), (AgentProvider.openCodeZen, OpenCodePlan.zen)])
    func `OpenCode signs in with a key and lists its plan's catalog`(provider: AgentProvider, plan: OpenCodePlan) async throws {
        let other = OAuthCredentials(access: "other-SECRET", refresh: "", expires: .max)
        let store = DeliveredCredentialSource([CredentialProviderID.openAICompatible: other])
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { verified, key, _ in
            #expect(verified == provider)
            #expect(key.access == "oc_sk_SECRET")
            #expect(key.extras.isEmpty)
        })
        let recorder = SignInRecorder()
        let task = TaskID("\(plan.id)-sign-in")
        try await desk.start(AgentSignInRequest(provider: provider), taskID: task, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events.first?.kind == "input")
        #expect(provider.keyFields.map(\.field) == [.apiKey, .defaultModel])
        #expect(provider.signInMethods == [.apiKey])
        try await desk.respond(AgentSignInRespondRequest(taskID: task, fields: [.apiKey: "oc_sk_SECRET"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        let account = try #require(await desk.list().accounts.first { $0.provider == provider })
        #expect(account.signedIn)
        #expect(account.models?.contains(plan.defaultModel) == true)
        #expect(!recorder.transcript.contains("SECRET"))
        try await desk.signOut(provider)
        #expect(try await store.credentials(for: plan.id) == nil)
        #expect(try await store.credentials(for: CredentialProviderID.openAICompatible) == other)
    }

    /// The test that fails when kwwk gains a login: every subscription
    /// `OAuthSubscriptions.login` runs has a provider here that signs in by
    /// a flow (not a typed key). Display order is Apelin's own.
    @Test
    func `every kwwk subscription has a provider`() {
        for subscription in OAuthSubscriptions.providers {
            let provider = AgentProvider.allCases.first { $0.storeID == subscription.id }
            #expect(provider != nil, "kwwk signs in to \(subscription.id), which AgentProvider lacks")
            #expect(provider.map { $0.signInMethod != .apiKey } == true, "\(subscription.id) is a kwwk flow, not a key")
        }
        #expect(Array(AgentProvider.signInOrder.prefix(4)) == [.openAICodex, .anthropicOAuth, .githubCopilot, .cursor])
        #expect(AgentProvider.signInOrder.filter { $0.signInMethod == .apiKey }
            == [.openAI, .deepSeek, .openCodeGo, .openCodeZen, .google, .anthropic, .openAICompatible])
    }

    /// Every login kwwk can store and register for a session
    /// (`providerDirectory`, the list `registerStored` serves) has a
    /// provider here; Apelin's own registration adds DeepSeek.
    @Test
    func `every stored provider is registered by kwwk or Apelin`() {
        let kwwk = Set(providerDirectory.map(\.storeId))
        let apelin = Set(AgentProvider.allCases.map(\.storeID))
        #expect(kwwk.subtracting(apelin).isEmpty, "kwwk stores \(kwwk.subtracting(apelin).sorted()) with no provider")
        #expect(apelin.subtracting(kwwk) == [CredentialProviderID.deepSeek])
        // A store id kwwk keeps as a typed key and does not sign in to is
        // a key form here.
        let subscriptions = Set(OAuthSubscriptions.providers.map(\.id))
        for descriptor in providerDirectory where descriptor.formTitle != nil && !subscriptions.contains(descriptor.storeId) {
            let provider = AgentProvider.allCases.first { $0.storeID == descriptor.storeId }
            #expect(provider?.signInMethods.contains(.apiKey) == true, "\(descriptor.storeId) has no key form")
        }
    }

    /// KWWKCli's API-key forms, as mirrored: the key first and secure, each
    /// form only the fields `agentSignInRespond` knows.
    @Test
    func `each key form asks for a key first, as KWWKCli's does`() {
        #expect(SignInKeyForms.all.map(\.provider) == [
            .anthropic, .openAI, .google, .deepSeek, .openCodeGo, .openCodeZen, .openRouter, .openAICompatible,
        ])
        for form in SignInKeyForms.all {
            #expect(form.fields.first == KeyField(field: .apiKey, required: true, placeholder: form.fields.first?.placeholder))
            #expect(form.fields.filter(\.secure).count == 1)
            #expect(!form.fields.contains { $0.field == .callbackURL })
        }
        for provider in AgentProvider.allCases where provider.signInMethods.contains(.apiKey) {
            #expect(!provider.keyFields.isEmpty, "\(provider) takes a key but has no form")
        }
    }

    /// A device flow whose page arrives with the code (Kimi, xAI): the code
    /// is shown to check, not to type; Kimi's login, on either site, is
    /// handed the device id that site's last sign-in recorded, never kwwk's
    /// file.
    @Test(arguments: [AgentProvider.kimiCoding, .kimiCodingGlobal])
    func `Kimi's device flow keeps the device the stored sign-in recorded`(site: AgentProvider) async throws {
        let seen = SignInRecorder()
        let login: SignInLogin = { provider, callbacks, options in
            #expect(provider == site)
            let identity = try #require(options.kimiIdentity)
            seen.reporter.emit(TaskID("seen"), identity.deviceId, nil)
            let code = OAuthLogin.DeviceCode(
                code: "KIMI-0001",
                verificationURL: URL(string: "https://www.kimi.com/code/authorize_device?user_code=KIMI-0001")!,
                pageHoldsCode: true,
            )
            await callbacks.onDeviceCode?(code)
            return try await callbacks.browser!.run(code.verificationURL) {
                var issued = Self.issued
                issued.extras[KimiIdentity.deviceIDExtra] = .string(identity.deviceId)
                return issued
            }
        }
        let previous = OAuthCredentials(access: "old-SECRET", refresh: "old-refresh-SECRET", expires: 1, extras: [
            KimiIdentity.deviceIDExtra: .string("0123456789abcdef0123456789abcdef"),
        ])
        let store = DeliveredCredentialSource([site.storeID: previous])
        let desk = AccountDesk(store: store, login: login, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: site), taskID: TaskID("k1"), reporter: recorder.reporter)
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(recorder.events.map(\.kind) == ["deviceCode"])
        #expect(recorder.events[0].payload?["pageHoldsCode"] == .bool(true))
        #expect(seen.events.map(\.kind) == ["0123456789abcdef0123456789abcdef"])
        let stored = try #require(try await store.credentials(for: site.storeID))
        #expect(stored.extras[KimiIdentity.deviceIDExtra] == .string("0123456789abcdef0123456789abcdef"))
        #expect(!recorder.transcript.contains("SECRET"))

        // With nothing stored, a new id in kwwk's format.
        let fresh = KimiIdentity.identity(recordedIn: nil).deviceId
        #expect(fresh.count == 32 && fresh.allSatisfy({ $0.isHexDigit }) && fresh == fresh.lowercased())
    }

    /// A page the flow polls the provider for (Cursor, Qoder, WorkBuddy,
    /// Z.ai) or a listener kwwk binds itself (Kiro): the page is named with
    /// no paste offered, and a pasted address is refused.
    @Test
    func `a polled browser flow names its page and takes no pasted address`() async throws {
        let (approval, approve) = AsyncStream<Void>.makeStream()
        let login: SignInLogin = { provider, callbacks, options in
            #expect(provider == .cursor)
            #expect(options == SignInOptions())
            return try await callbacks.browser!.run(URL(string: "https://cursor.com/loginDeepControl?uuid=u")!) {
                for await _ in approval {
                    return Self.issued
                }
                throw CancellationError()
            }
        }
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: login, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: .cursor), taskID: TaskID("c1"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events == [SignInRecorder.Event(kind: "authorize", payload: .object([
            "url": .string("https://cursor.com/loginDeepControl?uuid=u"),
            "acceptsCallbackURL": .bool(false),
        ]))])
        do {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("c1"), fields: [.callbackURL: "http://localhost:1/x?code=c"]))
            Issue.record("a polled flow took a pasted address")
        } catch let error as ApelinError {
            #expect(error.code == .conflict)
        }
        approve.yield()
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "cursor") == Self.issued)
        let account = await desk.list().accounts.first { $0.provider == .cursor }
        #expect(account?.signedIn == true)
        #expect(account?.method == .browser)
    }

    /// OpenRouter both ways under one store id: its browser sign-in by
    /// default, its key form when asked for; any other method is refused
    /// before the task starts.
    @Test
    func `OpenRouter signs in by browser or by key, and nothing else`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let listed = await desk.list().accounts.first { $0.provider == .openRouter }
        #expect(listed?.method == .browser)
        #expect(listed?.alternativeMethods == [.apiKey])
        #expect(await desk.list().accounts.filter { $0.alternativeMethods != nil }.map(\.provider) == [.openRouter])

        let recorder = SignInRecorder()
        await #expect(throws: ApelinError.self) {
            try await desk.start(AgentSignInRequest(provider: .openRouter, method: .deviceCode), taskID: TaskID("o0"), reporter: recorder.reporter)
        }
        await #expect(throws: ApelinError.self) {
            try await desk.start(AgentSignInRequest(provider: .cursor, method: .apiKey), taskID: TaskID("o0"), reporter: recorder.reporter)
        }
        #expect(recorder.events.isEmpty && recorder.state == nil)

        try await desk.start(AgentSignInRequest(provider: .openRouter, method: .apiKey), taskID: TaskID("o1"), reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        #expect(recorder.events[0].payload?["fields"] == .array([
            .object([
                "key": .string("apiKey"), "required": .bool(true), "secure": .bool(true),
                "placeholder": .string("sk-or-v1-…"),
            ]),
            .object([
                "key": .string("defaultModel"), "required": .bool(false), "secure": .bool(false),
                "placeholder": .string("anthropic/claude-sonnet-5"),
            ]),
        ]))
        // OpenRouter's form has no endpoint to give.
        await #expect(throws: ApelinError.self) {
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("o1"), fields: [.apiKey: "sk-or-SECRET", .baseURL: "https://x.invalid"]))
        }
        try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("o1"), fields: [.apiKey: "sk-or-SECRET"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: "openrouter")?.access == "sk-or-SECRET")
        #expect(try await store.credentials(for: "openrouter")?.extras["apelinSignInMethod"] == .string("apiKey"))
        #expect(!recorder.transcript.contains("SECRET"))
    }

    /// The keys kwwk's CLI asks for beyond the first four: OpenAI's and
    /// Google's, each with its own default endpoint as the label.
    @Test
    func `OpenAI's and Google's keys are stored under kwwk's ids with their endpoints as labels`() async throws {
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        for (provider, id, host) in [
            (AgentProvider.openAI, "openai-api-key", "api.openai.com"),
            (.google, "google-api-key", "generativelanguage.googleapis.com"),
        ] {
            let recorder = SignInRecorder()
            try await desk.start(AgentSignInRequest(provider: provider), taskID: TaskID("k-\(id)"), reporter: recorder.reporter)
            try await recorder.waitFor { !$0.events.isEmpty }
            guard case let .array(fields)? = recorder.events.first?.payload?["fields"], fields.count == 2 else {
                Issue.record("\(provider) asked for \(String(describing: recorder.events.first?.payload))")
                continue
            }
            #expect(fields[1]["key"] == .string("baseUrl"))
            #expect(fields[1]["defaultValue"] == .string("https://\(host)"))
            try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("k-\(id)"), fields: [.apiKey: "key-SECRET"]))
            try await recorder.waitFor { $0.state != nil }
            #expect(recorder.state == .succeeded)
            #expect(try await store.credentials(for: id)?.access == "key-SECRET")
            #expect(await desk.list().accounts.first { $0.provider == provider }?.account == host)
            #expect(!recorder.transcript.contains("SECRET"))
        }
    }

    /// 故意不响应取消，用来模拟晚到的供应商网络请求。
    actor UncancellableAccountGate {
        private var continuation: CheckedContinuation<Void, Never>?
        private(set) var entered = false
        private var released = false

        func wait() async {
            entered = true
            if released { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func release() {
            released = true
            continuation?.resume()
            continuation = nil
        }
        func waitUntilEntered() async throws {
            for _ in 0 ..< 500 {
                if entered { return }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            throw POSIXError(.ETIMEDOUT)
        }
    }

    @Test
    func `退出不等待忽略取消的模型验证且迟到结果不能复活凭据`() async throws {
        let provider = AgentProvider.openAICompatible
        let second = AccountIDs.extra(provider, 2)
        let candidate = OAuthCredentials(access: "second-SECRET", refresh: "", expires: .max)
        let store = DeliveredCredentialSource([second: candidate])
        let gate = UncancellableAccountGate()
        let desk = AccountDesk(store: store, verifyKey: { _, credentials, _ in
            guard credentials.extras["apiFormat"] == .string(AgentAPIFormat.responses.rawValue) else {
                throw ProviderEndpointRequirement.responsesOnly
            }
            await gate.wait()
        })
        let recorder = SignInRecorder()
        try await desk.activateModels(
            AgentModelActivateRequest(provider: provider, accountID: second, models: ["test-model"]),
            taskID: TaskID("late-activation"), reporter: recorder.reporter,
        )
        try await gate.waitUntilEntered()
        // 直到 signOut 已返回才释放网络结果，证明退出无需等待不配合取消的任务。
        try await desk.signOut(provider, accountID: second)
        #expect(try await store.credentials(for: second) == nil)
        await gate.release()
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .cancelled)
        #expect(try await store.credentials(for: second) == nil)
        #expect(!recorder.events.contains { $0.kind == "modelVerified" })
    }

    @Test
    func `退出后显式重新登录使用新代次且旧登录不能覆盖它`() async throws {
        let provider = AgentProvider.openRouter
        let second = AccountIDs.extra(provider, 2)
        let gate = UncancellableAccountGate()
        let store = DeliveredCredentialSource()
        let desk = AccountDesk(store: store, login: { _, _, _ in
            await gate.wait()
            return OAuthCredentials(access: "late-SECRET", refresh: "", expires: .max)
        }, verifyKey: { _, _, _ in })
        let old = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: provider, accountID: second), taskID: TaskID("late-login"), reporter: old.reporter)
        try await gate.waitUntilEntered()
        try await desk.signOut(provider, accountID: second)
        let fresh = SignInRecorder()
        try await desk.start(AgentSignInRequest(provider: provider, method: .apiKey, accountID: second), taskID: TaskID("fresh-login"), reporter: fresh.reporter)
        try await fresh.waitFor { !$0.events.isEmpty }
        try await desk.respond(AgentSignInRespondRequest(taskID: TaskID("fresh-login"), fields: [.apiKey: "fresh-SECRET"]))
        try await fresh.waitFor { $0.state != nil }
        #expect(fresh.state == .succeeded)
        await gate.release()
        try await old.waitFor { $0.state != nil }
        #expect(old.state == .cancelled)
        #expect(try await store.credentials(for: second)?.access == "fresh-SECRET")
    }

    // MARK: - 多账号隔离

    /// 记录凭据读取；损坏条目仍在 providerIds 中，以覆盖退出时的解码失败。
    actor AccountAccessRecorder: CredentialSource {
        private var entries: [String: OAuthCredentials]
        private var unreadable: Set<String>
        private(set) var readIDs: [String] = []

        init(_ entries: [String: OAuthCredentials] = [:], unreadable: Set<String> = []) {
            self.entries = entries
            self.unreadable = unreadable
        }

        func providerIds() -> [String] { Set(entries.keys).union(unreadable).sorted() }
        func credentials(for providerId: String) throws -> OAuthCredentials? {
            readIDs.append(providerId)
            if unreadable.contains(providerId) { throw POSIXError(.EIO) }
            return entries[providerId]
        }
        func store(_ credentials: OAuthCredentials, for providerID: String) {
            entries[providerID] = credentials
            unreadable.remove(providerID)
        }
        func remove(_ providerID: String) {
            entries.removeValue(forKey: providerID)
            unreadable.remove(providerID)
        }
    }

    @Test
    func `账号后缀只接受规范形式且空位可以再次分配`() {
        let provider = AgentProvider.anthropicOAuth
        let base = provider.storeID
        #expect(AccountIDs.belongs(base, to: provider))
        #expect(AccountIDs.belongs("\(base)#2", to: provider))
        #expect(AccountIDs.belongs("\(base)#9", to: provider))
        for suffix in ["#1", "#02", "#+2", "#10", "#2#2", "#2\n", "#"] {
            #expect(!AccountIDs.belongs(base + suffix, to: provider))
        }
        #expect(!AccountIDs.belongs(AgentProvider.openAI.storeID, to: provider))
        #expect(AccountIDs.next(for: provider, taken: [base, "\(base)#3"]) == "\(base)#2")
        #expect(AccountIDs.next(for: provider, taken: Set([base] + (2 ... 9).map { "\(base)#\($0)" })) == nil)
    }

    @Test
    func `首账号退出后仍列出自定义端点的额外账号`() async throws {
        let provider = AgentProvider.openAICompatibleEndpoint(2)
        let second = AccountIDs.extra(provider, 2)
        let store = DeliveredCredentialSource([
            second: OAuthCredentials(access: "endpoint-SECRET", refresh: "", expires: .max),
        ])
        let desk = AccountDesk(store: store)
        let rows = await desk.list(onlyExtraModels: true).accounts
        #expect(rows.contains { $0.provider == provider && $0.storeID == second && $0.signedIn })
        #expect(rows.filter { $0.provider == provider }.count == 1)
        #expect(rows.contains { $0.provider == .openAICompatible && !$0.signedIn })
    }

    @Test
    func `同服务商的每份凭据单独列出且窄列表不回填目录`() async throws {
        let provider = AgentProvider.deepSeek
        let base = provider.storeID
        let second = AccountIDs.extra(provider, 2)
        let broken = AccountIDs.extra(provider, 3)
        let store = AccountAccessRecorder([
            base: OAuthCredentials(access: "key-first-SECRET", refresh: "", expires: .max),
            second: OAuthCredentials(access: "key-second-SECRET", refresh: "", expires: .max),
        ], unreadable: [broken])
        let desk = AccountDesk(store: store)
        let rows = await desk.list(extraModels: [provider.rawValue: ["custom", "custom", ""]], onlyExtraModels: true)
            .accounts.filter { $0.provider == provider }
        try #require(rows.count == 3)
        #expect(rows.map(\.storeID) == [base, second, broken])
        #expect(rows.allSatisfy({ $0.signedIn }))
        #expect(rows[0].models == ["custom"])
        #expect(rows[1].models == [])
        #expect(rows[0].poolID != rows[1].poolID)
        #expect(rows[2].models == nil && rows[2].poolID == nil)
        let encoded = try JSONCoding.encode(rows)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("SECRET"))
    }

    @Test
    func `附加账号登录不覆盖首账号且编辑读取按账号隔离`() async throws {
        let provider = AgentProvider.deepSeek
        let original = OAuthCredentials(access: "first-SECRET", refresh: "", expires: .max)
        let store = DeliveredCredentialSource([provider.storeID: original])
        let second = AccountIDs.extra(provider, 2)
        let desk = AccountDesk(store: store, login: Self.neverCalled, listener: Self.silent, verifyKey: { _, _, _ in })
        let recorder = SignInRecorder()
        let taskID = TaskID("multi-account")
        try await desk.start(AgentSignInRequest(provider: provider, accountID: second), taskID: taskID, reporter: recorder.reporter)
        try await recorder.waitFor { !$0.events.isEmpty }
        try await desk.respond(AgentSignInRespondRequest(taskID: taskID, fields: [.apiKey: "second-SECRET"]))
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: provider.storeID) == original)
        #expect(try await desk.apiConfiguration(for: provider, accountID: second).values["apiKey"] == "second-SECRET")
        #expect(!recorder.transcript.contains("SECRET"))
        try await desk.signOut(provider, accountID: second)
        #expect(try await store.credentials(for: second) == nil)
        #expect(try await store.credentials(for: provider.storeID) == original)
    }

    @Test
    func `模型验证切换接口格式时只更新所选账号`() async throws {
        let provider = AgentProvider.openAICompatible
        let second = AccountIDs.extra(provider, 2)
        let original = OAuthCredentials(access: "first-SECRET", refresh: "", expires: .max)
        let candidate = OAuthCredentials(access: "second-SECRET", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://relay.example.invalid"),
            "defaultModel": .string("test-model"),
        ])
        let store = DeliveredCredentialSource([provider.storeID: original, second: candidate])
        let desk = AccountDesk(store: store, verifyKey: { actualProvider, credentials, model in
            #expect(actualProvider == provider)
            #expect(credentials.access == candidate.access)
            #expect(model == "test-model")
            guard credentials.extras["apiFormat"] == .string(AgentAPIFormat.responses.rawValue) else {
                throw ProviderEndpointRequirement.responsesOnly
            }
        })
        let recorder = SignInRecorder()
        try await desk.activateModels(
            AgentModelActivateRequest(provider: provider, accountID: second, models: ["test-model"]),
            taskID: TaskID("activate-second"), reporter: recorder.reporter,
        )
        try await recorder.waitFor { $0.state != nil }
        #expect(recorder.state == .succeeded)
        #expect(try await store.credentials(for: provider.storeID) == original)
        #expect(try await store.credentials(for: second)?.extras["apiFormat"] == .string(AgentAPIFormat.responses.rawValue))
        #expect(!recorder.transcript.contains("SECRET"))
    }

    @Test
    func `跨服务商及非规范账号在任何凭据读取前拒绝`() async throws {
        let provider = AgentProvider.deepSeek
        let store = AccountAccessRecorder()
        let desk = AccountDesk(store: store)
        for id in [AgentProvider.openAI.storeID, "", "\(provider.storeID)#02", "\(provider.storeID)#2#2"] {
            await #expect(throws: ApelinError.self) { _ = try await desk.apiConfiguration(for: provider, accountID: id) }
            await #expect(throws: ApelinError.self) { _ = try await desk.models(for: provider, accountID: id) }
            await #expect(throws: ApelinError.self) { try await desk.signOut(provider, accountID: id) }
            await #expect(throws: ApelinError.self) {
                try await desk.start(AgentSignInRequest(provider: provider, accountID: id), taskID: TaskID("invalid"), reporter: SignInRecorder().reporter)
            }
            await #expect(throws: ApelinError.self) {
                try await desk.activateModels(AgentModelActivateRequest(provider: provider, accountID: id, models: ["test"]), taskID: TaskID("invalid-model"), reporter: SignInRecorder().reporter)
            }
            #expect(throws: ApelinError.self) { _ = try AgentWorker.provider(provider: provider, model: "test", accountID: id) }
        }
        #expect(await store.readIDs.isEmpty)
    }

    @Test
    func `损坏凭据可以退出且全部退出清理每个账号的额度池`() async throws {
        let provider = AgentProvider.anthropicOAuth
        let first = provider.storeID
        let second = AccountIDs.extra(provider, 2)
        let broken = AccountIDs.extra(provider, 3)
        let store = AccountAccessRecorder([first: Self.issued, second: Self.issued], unreadable: [broken])
        let desk = AccountDesk(store: store)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("accounts-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = ApelinDataRoot(home: home)
        let cache = QuotaCacheStore(dataRoot: root)
        for id in [first, second, broken] {
            cache.mergePassiveUpdate(poolID: "oauth:\(id)", provider: provider, accountLabel: nil,
                                     windows: [], balances: [], planName: nil, isExhausted: false)
        }
        try await desk.signOut(provider, dataRoot: root)
        #expect(await store.providerIds().isEmpty)
        for id in [first, second, broken] { #expect(cache.pool(for: "oauth:\(id)") == nil) }
    }

    @Test
    func `退出保留其他服务商仍共享的密钥额度池`() async throws {
        let shared = OAuthCredentials(access: "shared-SECRET", refresh: "", expires: .max)
        let second = AccountIDs.extra(.deepSeek, 2)
        let store = DeliveredCredentialSource([
            AgentProvider.deepSeek.storeID: shared,
            second: OAuthCredentials(access: "other-SECRET", refresh: "", expires: .max),
            AgentProvider.openAI.storeID: shared,
        ])
        let desk = AccountDesk(store: store)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("account-pools-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = ApelinDataRoot(home: home)
        let cache = QuotaCacheStore(dataRoot: root)
        let sharedID = QuotaPoolIdentity.poolID(provider: .deepSeek, storeID: AgentProvider.deepSeek.storeID, credentials: shared, usesAPIKey: true)
        let other = try #require(try await store.credentials(for: second))
        let otherID = QuotaPoolIdentity.poolID(provider: .deepSeek, storeID: second, credentials: other, usesAPIKey: true)
        for pool in [sharedID, otherID] {
            cache.mergePassiveUpdate(poolID: pool, provider: .deepSeek, accountLabel: nil,
                                     windows: [], balances: [], planName: nil, isExhausted: false)
        }
        try await desk.signOut(.deepSeek, dataRoot: root)
        #expect(cache.pool(for: sharedID) != nil)
        #expect(cache.pool(for: otherID) == nil)
        try await desk.signOut(.openAI, dataRoot: root)
        #expect(cache.pool(for: sharedID) == nil)
    }

    @Test
    func `缓存额度查询只返回所选账号并拒绝跨服务商请求`() async throws {
        let first = AgentProvider.deepSeek.storeID
        let second = AccountIDs.extra(.deepSeek, 2)
        let store = AccountAccessRecorder([
            first: OAuthCredentials(access: "first", refresh: "", expires: .max),
            second: OAuthCredentials(access: "second", refresh: "", expires: .max),
        ])
        let desk = AccountDesk(store: store)
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("account-quota-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let root = ApelinDataRoot(home: home)
        let reply = try await desk.quotas(AgentProviderQuotaRequest(provider: .deepSeek, mode: .cachedOnly, accountID: second), dataRoot: root)
        #expect(reply.quotas.count == 1)
        #expect(await store.readIDs == [second])
        await #expect(throws: ApelinError.self) {
            _ = try await desk.quotas(AgentProviderQuotaRequest(provider: .openAI, mode: .cachedOnly, accountID: second), dataRoot: root)
        }
        #expect(await store.readIDs == [second])
    }

    /// Every renewing login remains supported, but a session constructs
    /// only the selected account's refresher (and none for API keys).
    @Test
    func `sessions refresh every renewing login without kwwk's files`() {
        let ids = Set(AgentProvider.allCases.flatMap { KimiIdentity.refreshers(for: $0.storeID).map(\.id) })
        #expect(ids.isSuperset(of: OAuthSubscriptions.refreshedIds))
        #expect(ids.contains("devin"))
    }
}
