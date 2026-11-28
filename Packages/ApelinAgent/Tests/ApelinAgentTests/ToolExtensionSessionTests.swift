@testable import ApelinAgent
import struct ApelinProtocol.ApelinError
import Foundation
import KWWKAI
import Testing

/// 用明确的挂起点控制竞态，不靠扩展进程启动速度。
private actor ExtensionSessionGate {
    private var released = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        released = true
        let pending = waiters
        waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private actor ExtensionSessionTrace {
    private(set) var events: [String] = []
    func add(_ event: String) { events.append(event) }
}

@Suite("扩展会话升级与回收", .timeLimit(.minutes(1)))
struct ToolExtensionSessionTests {
    private static func tool(_ version: String = "1.0.0", id: String = "example.sessions") -> ExtensionTool {
        ExtensionTool(name: "analyze_functions", extensionID: id, extensionName: "测试扩展",
                      extensionVersion: version, timeoutSeconds: 30, required: [])
    }

    private static func journal(in home: TemporaryHome) -> (SessionJournal, DiagnosticJournal) {
        let file = DiagnosticJournal(folder: home.projectURL, name: "extension-lifecycle")
        return (SessionJournal(sessionID: "log-session", file: file,
                               redaction: JournalRedaction(home: home.projectURL.path, installRoot: nil)), file)
    }

    private static func events(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            line.split(separator: " ").first(where: { $0.hasPrefix("event=") }).map { String($0.dropFirst(6)) }
        }
    }

    @Test
    func `同版本并发调用共享打开任务及会话`() async throws {
        let backend = MockBackend()
        let entered = ExtensionSessionGate(), release = ExtensionSessionGate()
        await backend.setToolSessionHooks(opening: { _ in
            await entered.release()
            await release.wait()
        })
        let sessions = ToolExtensionSessions(backend: backend)
        let calls = (0..<12).map { _ in Task { try await sessions.call(Self.tool(), arguments: [:]) } }
        await entered.wait()
        await release.release()
        for call in calls { _ = try await call.value }
        #expect(await backend.toolSessionsOpened == ["example.sessions"])
        #expect(await backend.toolCalls.count == 12)
        #expect(await backend.toolCalls.allSatisfy { $0.sessionID == "tool-session-1" })
        await sessions.closeAll()
        #expect(await backend.toolSessionsClosed == ["tool-session-1"])
    }

    @Test
    func `升级先关闭旧会话并发新调用仅打开一次`() async throws {
        let backend = MockBackend()
        let closing = ExtensionSessionGate(), release = ExtensionSessionGate()
        let trace = ExtensionSessionTrace()
        await backend.setToolSessionHooks(opening: { id in
            await trace.add("打开 \(id)")
        }, closing: { id in
            await trace.add("关闭开始 \(id)")
            if id == "tool-session-1" {
                await closing.release()
                await release.wait()
            }
            await trace.add("关闭结束 \(id)")
        })
        let sessions = ToolExtensionSessions(backend: backend)
        _ = try await sessions.call(Self.tool(), arguments: [:])
        let first = Task { try await sessions.call(Self.tool("1.0.1"), arguments: [:]) }
        await closing.wait()
        let second = Task { try await sessions.call(Self.tool("1.0.1"), arguments: [:]) }
        await release.release()
        _ = try await first.value
        _ = try await second.value
        #expect(await trace.events == ["打开 tool-session-1", "关闭开始 tool-session-1",
                                       "关闭结束 tool-session-1", "打开 tool-session-2"])
        #expect(await backend.toolSessionsOpened.count == 2)
        #expect(await backend.toolCalls.map(\.sessionID) == ["tool-session-1", "tool-session-2", "tool-session-2"])
        await sessions.closeAll()
        #expect(await backend.toolSessionsClosed == ["tool-session-1", "tool-session-2"])
    }

    @Test
    func `关闭期间迟到的打开结果不转发调用且只回收一次`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let (journal, file) = Self.journal(in: home)
        let backend = MockBackend()
        let opening = ExtensionSessionGate(), releaseOpen = ExtensionSessionGate()
        let closing = ExtensionSessionGate(), releaseClose = ExtensionSessionGate()
        await backend.setToolSessionHooks(opening: { id in
            if id == "tool-session-2" {
                await opening.release()
                await releaseOpen.wait()
            }
        }, closing: { id in
            if id == "tool-session-1" {
                await closing.release()
                await releaseClose.wait()
            }
        })
        let sessions = ToolExtensionSessions(backend: backend, journal: journal)
        _ = try await sessions.call(Self.tool(id: "a.fixture"), arguments: [:])
        let late = Task { try await sessions.call(Self.tool(id: "b.fixture"), arguments: [:]) }
        await opening.wait()
        let shutdown = Task { await sessions.closeAll() }
        // a 的关闭钩子证明 closeAll 已封闭入口，而 b 仍在打开中。
        await closing.wait()
        await releaseOpen.release()
        await #expect(throws: ConversationClosingError.self) { try await late.value }
        #expect(await backend.toolCalls.count == 1)
        await releaseClose.release()
        await shutdown.value
        #expect(await backend.toolSessionsClosed.sorted() == ["tool-session-1", "tool-session-2"])
        await #expect(throws: ConversationClosingError.self) {
            try await sessions.call(Self.tool(), arguments: [:])
        }
        #expect(await backend.toolSessionsOpened.count == 2)
        journal.drain()
        let lateLines = file.contents().split(separator: "\n").filter { $0.contains("extension=b.fixture ") }.joined(separator: "\n")
        #expect(Self.events(in: lateLines) == ["open-queued", "open-requested", "opened", "retire-requested", "close-requested", "close-acknowledged"])
    }

    @Test
    func `重复关闭均等待同一个实际关闭任务`() async throws {
        let backend = MockBackend()
        let closing = ExtensionSessionGate(), release = ExtensionSessionGate()
        let trace = ExtensionSessionTrace()
        await backend.setToolSessionHooks(closing: { _ in
            await closing.release()
            await release.wait()
            await trace.add("实际关闭结束")
        })
        let sessions = ToolExtensionSessions(backend: backend)
        _ = try await sessions.call(Self.tool(), arguments: [:])
        let first = Task { await sessions.closeAll(); await trace.add("首次关闭返回") }
        await closing.wait()
        let started = ExtensionSessionGate()
        let second = Task {
            await started.release()
            await sessions.closeAll()
            await trace.add("再次关闭返回")
        }
        await started.wait()
        await release.release()
        await first.value
        await second.value
        #expect(await backend.toolSessionsClosed == ["tool-session-1"])
        let events = await trace.events
        #expect(events.first == "实际关闭结束")
        #expect(events.count == 3)
    }

    @Test
    func `打开失败不缓存失败任务下次可以重试`() async throws {
        let backend = MockBackend()
        await backend.setToolSessionHooks(opening: { id in
            if id == "tool-session-1" { throw ApelinError(.unavailable, "首次打开失败") }
        })
        let sessions = ToolExtensionSessions(backend: backend)
        await #expect(throws: ApelinError.self) { try await sessions.call(Self.tool(), arguments: [:]) }
        _ = try await sessions.call(Self.tool(), arguments: [:])
        #expect(await backend.toolSessionsOpened.count == 2)
        #expect(await backend.toolCalls.map(\.sessionID) == ["tool-session-2"])
        await sessions.closeAll()
        #expect(await backend.toolSessionsClosed == ["tool-session-2"])
    }

    @Test
    func `宿主失效会话仅重开一次而不是无限重放`() async throws {
        let backend = MockBackend()
        await backend.setToolSessionHooks(calling: { _ in throw ApelinError(.notFound, "会话不存在") })
        let sessions = ToolExtensionSessions(backend: backend)
        await #expect(throws: ApelinError.self) { try await sessions.call(Self.tool(), arguments: [:]) }
        #expect(await backend.toolSessionsOpened.count == 2)
        #expect(await backend.toolCalls.count == 2)
        await sessions.closeAll()
        #expect(await backend.toolSessionsClosed == ["tool-session-1", "tool-session-2"])
    }

    @Test
    func `业务失败及其他宿主错误均不自动重放`() async throws {
        let backend = MockBackend()
        let sessions = ToolExtensionSessions(backend: backend)
        await backend.setToolAnswer { _ in
            ToolExtensionCallResponse(text: "", failure: ToolExtensionFailure(code: "invalidArguments", message: "参数无效"))
        }
        let response = try await sessions.call(Self.tool(), arguments: [:])
        #expect(response.failure?.code == "invalidArguments")
        await backend.setToolSessionHooks(calling: { _ in throw ApelinError(.unavailable, "服务暂不可用") })
        await #expect(throws: ApelinError.self) { try await sessions.call(Self.tool(), arguments: [:]) }
        #expect(await backend.toolSessionsOpened.count == 1)
        #expect(await backend.toolCalls.count == 2)
        await sessions.closeAll()
    }

    @Test
    func `清单刷新先关闭旧版并拒绝迟到的旧闭包但保留未变扩展`() async throws {
        let backend = MockBackend()
        let sessions = ToolExtensionSessions(backend: backend)
        let old = Self.tool("1.0.0", id: "changed.extension")
        let stable = Self.tool("1.0.0", id: "stable.extension")
        _ = try await sessions.call(old, arguments: [:])
        _ = try await sessions.call(stable, arguments: [:])

        let upgraded = Self.tool("1.0.1", id: "changed.extension")
        await sessions.refresh(keeping: [upgraded, stable])
        #expect(await backend.toolSessionsClosed == ["tool-session-1"])

        do {
            _ = try await sessions.call(old, arguments: [:])
            Issue.record("刷新后不应再启动旧版本工具闭包")
        } catch {
            #expect(error.localizedDescription.contains("更新"))
        }
        _ = try await sessions.call(upgraded, arguments: [:])
        _ = try await sessions.call(stable, arguments: [:])

        #expect(await backend.toolSessionsOpened == ["changed.extension", "stable.extension", "changed.extension"])
        #expect(await backend.toolCalls.map(\.sessionID) == ["tool-session-1", "tool-session-2", "tool-session-3", "tool-session-2"])
        await sessions.closeAll()
        #expect(Set(await backend.toolSessionsClosed) == Set(["tool-session-1", "tool-session-2", "tool-session-3"]))
    }

    @Test
    func `刷新移除扩展会关闭旧会话并拒绝其迟到闭包`() async throws {
        let backend = MockBackend()
        let sessions = ToolExtensionSessions(backend: backend)
        let removed = Self.tool("1.0.0", id: "removed.extension")
        _ = try await sessions.call(removed, arguments: [:])

        await sessions.refresh(keeping: [])
        #expect(await backend.toolSessionsClosed == ["tool-session-1"])
        do {
            _ = try await sessions.call(removed, arguments: [:])
            Issue.record("移除后不应再启动已卸载扩展")
        } catch {
            #expect(error.localizedDescription.contains("更新"))
        }
        #expect(await backend.toolSessionsOpened == ["removed.extension"])
        await sessions.closeAll()
        #expect(await backend.toolSessionsClosed == ["tool-session-1"])
    }

    @Test
    func `版本刷新等待旧服务退出后再打开新版且并发等待者只打开一次`() async throws {
        let backend = MockBackend()
        let closing = ExtensionSessionGate(), release = ExtensionSessionGate()
        let trace = ExtensionSessionTrace()
        await backend.setToolSessionHooks(opening: { id in
            await trace.add("打开 \(id)")
        }, closing: { id in
            await trace.add("关闭开始 \(id)")
            if id == "tool-session-1" {
                await closing.release()
                await release.wait()
            }
            await trace.add("关闭结束 \(id)")
        })
        let sessions = ToolExtensionSessions(backend: backend)
        _ = try await sessions.call(Self.tool("1.0.0"), arguments: [:])

        let refreshed = Task { await sessions.refresh(keeping: [Self.tool("1.0.1")]) }
        await closing.wait()
        let first = Task { try await sessions.call(Self.tool("1.0.1"), arguments: [:]) }
        let second = Task { try await sessions.call(Self.tool("1.0.1"), arguments: [:]) }
        await release.release()
        await refreshed.value
        _ = try await first.value
        _ = try await second.value

        #expect(await trace.events == [
            "打开 tool-session-1",
            "关闭开始 tool-session-1",
            "关闭结束 tool-session-1",
            "打开 tool-session-2",
        ])
        #expect(await backend.toolSessionsOpened.count == 2)
        #expect(await backend.toolCalls.map(\.sessionID) == ["tool-session-1", "tool-session-2", "tool-session-2"])
        await sessions.closeAll()
    }

    @Test
    func `关闭日志只在实际应答后确认且与打开共用关联标识`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let (journal, file) = Self.journal(in: home)
        let backend = MockBackend()
        let closing = ExtensionSessionGate(), release = ExtensionSessionGate()
        await backend.setToolSessionHooks(closing: { _ in
            await closing.release()
            await release.wait()
        })
        let sessions = ToolExtensionSessions(backend: backend, journal: journal)
        _ = try await sessions.call(Self.tool(), arguments: [:])
        let refreshed = Task { await sessions.refresh(keeping: [Self.tool("1.0.1")]) }
        await closing.wait()
        journal.drain()
        let pending = file.contents()
        #expect(pending.contains("event=close-requested"))
        #expect(pending.contains("reason=manifest-changed"))
        #expect(!pending.contains("event=close-acknowledged"), "关闭仍阻塞时不能记录成功")
        #expect(!pending.contains("process-reaped"), "对话日志不冒充宿主的进程回收证据")
        await release.release()
        await refreshed.value
        await sessions.closeAll()
        journal.drain()
        let text = file.contents()
        #expect(Self.events(in: text) == ["open-queued", "open-requested", "opened", "retire-requested", "close-requested", "close-acknowledged"])
        let lines = text.split(separator: "\n").filter { $0.contains("event=") }
        let attempts = lines.compactMap { $0.split(separator: " ").first(where: { $0.hasPrefix("opening=") }).map(String.init) }
        #expect(attempts.count == 6 && Set(attempts).count == 1)
        #expect(lines.allSatisfy { $0.contains("session=log-session at=") && $0.contains("version=1.0.0 ") })
        #expect(await backend.toolSessionsOpened.count == 1, "刷新本身不能打开新版")
        #expect(await backend.toolCalls.count == 1)
    }

    @Test
    func `打开及关闭失败写警告但不伪造成功`() async throws {
        let home = try TemporaryHome()
        defer { home.remove() }
        let (journal, file) = Self.journal(in: home)
        let backend = MockBackend()
        let secret = "ghp_" + String(repeating: "a1", count: 18)
        await backend.setToolSessionHooks(opening: { id in
            if id == "tool-session-1" { throw ApelinError(.unavailable, "打开失败 token=\(secret)") }
        }, closing: { _ in
            throw ApelinError(.unavailable, "关闭失败 token=\(secret)")
        })
        let sessions = ToolExtensionSessions(backend: backend, journal: journal)
        await #expect(throws: ApelinError.self) { try await sessions.call(Self.tool(), arguments: [:]) }
        _ = try await sessions.call(Self.tool(), arguments: [:])
        await sessions.closeAll()
        journal.drain()
        let text = file.contents()
        #expect(text.contains("event=open-failed") && text.contains("event=close-failed"))
        #expect(text.contains("|warning|"))
        #expect(!text.contains("event=close-acknowledged"))
        #expect(!text.contains(secret), "失败信息也要统一脱敏")
        #expect(Self.events(in: text).filter { $0 == "opened" }.count == 1)
        #expect(await backend.toolSessionsClosed == ["tool-session-2"])
    }

    @Test
    func `清单刷新与重复关闭并发时共用原关闭任务`() async throws {
        let backend = MockBackend()
        let oldClosing = ExtensionSessionGate(), releaseOld = ExtensionSessionGate()
        let stableClosing = ExtensionSessionGate(), releaseStable = ExtensionSessionGate()
        await backend.setToolSessionHooks(closing: { id in
            if id == "tool-session-1" {
                await oldClosing.release()
                await releaseOld.wait()
            } else {
                await stableClosing.release()
                await releaseStable.wait()
            }
        })
        let sessions = ToolExtensionSessions(backend: backend)
        let old = Self.tool(id: "b.changed"), stable = Self.tool(id: "a.stable")
        let upgraded = Self.tool("1.0.1", id: "b.changed")
        _ = try await sessions.call(old, arguments: [:])
        _ = try await sessions.call(stable, arguments: [:])
        let refreshed = Task { await sessions.refresh(keeping: [upgraded, stable]) }
        await oldClosing.wait()
        let first = Task { await sessions.closeAll() }
        // a.stable 的关闭证明 closeAll 已封闭入口，而刷新仍在等旧版关闭。
        await stableClosing.wait()
        let second = Task { await sessions.closeAll() }
        await #expect(throws: ConversationClosingError.self) {
            try await sessions.call(upgraded, arguments: [:])
        }
        await releaseStable.release()
        await releaseOld.release()
        await refreshed.value
        await first.value
        await second.value
        #expect(await backend.toolSessionsClosed == ["tool-session-1", "tool-session-2"])
        #expect(await backend.toolSessionsOpened == ["b.changed", "a.stable"])
        #expect(await backend.toolCalls.count == 2)
    }

    @Test
    func `旧调用迟到的失效错误不能替换已升级会话`() async throws {
        let backend = MockBackend()
        let calling = ExtensionSessionGate(), release = ExtensionSessionGate()
        await backend.setToolSessionHooks(calling: { request in
            if request.sessionID == "tool-session-1" {
                await calling.release()
                await release.wait()
                throw ApelinError(.notFound, "旧会话已结束")
            }
            return ToolExtensionCallResponse(text: "新会话")
        })
        let sessions = ToolExtensionSessions(backend: backend)
        let old = Task { try await sessions.call(Self.tool(), arguments: [:]) }
        await calling.wait()
        _ = try await sessions.call(Self.tool("1.0.1"), arguments: [:])
        await release.release()
        await #expect(throws: ApelinError.self) { try await old.value }
        _ = try await sessions.call(Self.tool("1.0.1"), arguments: [:])
        #expect(await backend.toolSessionsOpened.count == 2)
        #expect(await backend.toolCalls.map(\.sessionID) == ["tool-session-1", "tool-session-2", "tool-session-2"])
        await sessions.closeAll()
        #expect(await backend.toolSessionsClosed == ["tool-session-1", "tool-session-2"])
    }
}
