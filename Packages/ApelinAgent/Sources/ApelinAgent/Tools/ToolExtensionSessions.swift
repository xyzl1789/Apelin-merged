import struct ApelinProtocol.AgentAttachment
import struct ApelinProtocol.ApelinError
import Foundation
import KWWKAgent
import KWWKAI

/// 扩展会话按标识及版本复用；升级时先关闭旧版本，再启动新版本。
/// 每次打开及关闭共享同一个任务，防止并发等待者重复关闭或泄漏迟到的会话。
actor ToolExtensionSessions {
    private final class Entry {
        let version: String
        let context: String
        let opening: Task<String, Error>
        var closing: Task<Void, Never>?

        init(version: String, context: String, opening: Task<String, Error>) {
            self.version = version
            self.context = context
            self.opening = opening
        }
    }

    private let backend: any AgentHostBackend
    private let journal: SessionJournal?
    private var entries: [String: Entry] = [:]
    private var closed = false
    private var shutdown: Task<Void, Never>?
    /// 最近一次两轮之间刷新所提供的扩展版本。
    /// 拒绝迟到的旧工具闭包，避免重新启动已退役的版本。
    private var offeredVersions: [String: Set<String>]?

    init(backend: any AgentHostBackend, journal: SessionJournal? = nil) {
        self.backend = backend
        self.journal = journal
    }

    /// 仅对宿主确认已不存在的会话重试一次；不自动重放工具业务错误。
    func call(_ tool: ExtensionTool, arguments: JSONValue) async throws -> ToolExtensionCallResponse {
        let (entry, session) = try await session(for: tool)
        do {
            return try await backend.callToolExtension(Self.request(tool, arguments, in: session))
        } catch let error as ApelinError where error.code == .notFound {
            if let current = entries[tool.extensionID], current !== entry, current.version != tool.extensionVersion {
                throw error
            }
            if entries[tool.extensionID] === entry {
                await retire(entry, reason: "session-not-found").value
                if entries[tool.extensionID] === entry {
                    entries[tool.extensionID] = nil
                }
            }
            // 关闭旧会话期间可能已升级，不能用旧工具声明重新打开旧版本。
            if let current = entries[tool.extensionID], current !== entry, current.version != tool.extensionVersion {
                throw error
            }
            let (_, reopened) = try await self.session(for: tool)
            return try await backend.callToolExtension(Self.request(tool, arguments, in: reopened))
        }
    }

    /// 扩展清单在两轮之间更新时，退役已移除或替换版本的会话，并保留未变扩展。
    /// 首次挂起前登记关闭任务，使并发打开的新版本等待旧进程退出。
    func refresh(keeping tools: [ExtensionTool]) async {
        guard !closed else { return }
        var versionsByID: [String: Set<String>] = [:]
        for tool in tools {
            versionsByID[tool.extensionID, default: []].insert(tool.extensionVersion)
        }
        offeredVersions = versionsByID

        let stale = entries.keys.sorted().compactMap { id -> (String, Entry, Task<Void, Never>)? in
            guard let entry = entries[id] else { return nil }
            let versions = versionsByID[id] ?? []
            guard entry.closing != nil || versions.count != 1 || !versions.contains(entry.version) else {
                return nil
            }
            return (id, entry, retire(entry, reason: "manifest-changed"))
        }
        for (id, entry, closing) in stale {
            await closing.value
            if entries[id] === entry {
                entries[id] = nil
            }
        }
    }

    func closeAll() async {
        if let shutdown {
            await shutdown.value
            return
        }
        closed = true
        let pending = entries.keys.sorted().compactMap { entries[$0] }
        entries = [:]
        let shutdown = Task {
            for entry in pending { await retire(entry, reason: "conversation-closed").value }
        }
        self.shutdown = shutdown
        await shutdown.value
    }

    private func session(for tool: ExtensionTool) async throws -> (Entry, String) {
        guard !closed else { throw Self.closing }
        if let offeredVersions,
           offeredVersions[tool.extensionID]?.contains(tool.extensionVersion) != true
        {
            throw Self.offerChanged
        }
        let entry: Entry
        if let current = entries[tool.extensionID], current.version == tool.extensionVersion, current.closing == nil {
            entry = current
        } else {
            let previous = entries[tool.extensionID].map { retire($0, reason: "version-replaced") }
            let backend = backend
            let journal = journal
            let extensionID = tool.extensionID
            let context = "extension=\(extensionID) version=\(tool.extensionVersion) opening=\(UUID().uuidString.lowercased())"
            journal?.toolExtensionLifecycle("排队打开 event=open-queued \(context)")
            let opening = Task {
                if let previous { await previous.value }
                journal?.toolExtensionLifecycle("请求打开 event=open-requested \(context)")
                do {
                    let session = try await backend.openToolExtension(id: extensionID)
                    journal?.toolExtensionLifecycle("打开完成 event=opened \(context) tool_session=\(session)")
                    return session
                } catch {
                    journal?.toolExtensionLifecycle("打开失败 event=open-failed \(context) error=\(error.localizedDescription)", level: .warning)
                    throw error
                }
            }
            entry = Entry(version: tool.extensionVersion, context: context, opening: opening)
            entries[tool.extensionID] = entry
        }
        let session: String
        do {
            session = try await entry.opening.value
        } catch {
            if entries[tool.extensionID] === entry {
                entries[tool.extensionID] = nil
            }
            throw error
        }
        guard !closed, entries[tool.extensionID] === entry, entry.closing == nil else {
            await retire(entry, reason: "late-open").value
            throw Self.closing
        }
        return (entry, session)
    }

    /// 无论升级、关闭还是迟到的打开结果，每个实际会话只关闭一次。
    private func retire(_ entry: Entry, reason: String) -> Task<Void, Never> {
        if let closing = entry.closing { return closing }
        let opening = entry.opening
        let backend = backend
        let journal = journal
        let context = entry.context
        journal?.toolExtensionLifecycle("登记退役 event=retire-requested \(context) reason=\(reason)")
        let closing = Task {
            guard let session = try? await opening.value else {
                journal?.toolExtensionLifecycle("无会话可关闭 event=close-skipped \(context) reason=open-failed")
                return
            }
            journal?.toolExtensionLifecycle("请求关闭 event=close-requested \(context) tool_session=\(session)")
            do {
                try await backend.closeToolExtension(sessionID: session)
                // 这是关闭请求的应答，不替代宿主 waitpid 成功后的进程回收证据。
                journal?.toolExtensionLifecycle("关闭应答 event=close-acknowledged \(context) tool_session=\(session)")
            } catch {
                journal?.toolExtensionLifecycle("关闭失败 event=close-failed \(context) tool_session=\(session) error=\(error.localizedDescription)", level: .warning)
            }
        }
        entry.closing = closing
        return closing
    }

    private static let closing = ConversationClosingError()
    private static let offerChanged = ExtensionOfferChangedError()

    private static func request(_ tool: ExtensionTool, _ arguments: JSONValue, in session: String) -> ToolExtensionCallRequest {
        ToolExtensionCallRequest(sessionID: session, tool: tool.name, arguments: arguments, timeoutSeconds: tool.timeoutSeconds)
    }
}

private struct ExtensionOfferChangedError: Error, LocalizedError {
    var errorDescription: String? {
        "扩展定义已在两轮之间更新。请使用刷新后的工具定义重试。"
    }
}

/// An extension's error answer, as the call's failed result.
struct ToolExtensionError: Error, LocalizedError {
    var message: String
    /// The extension's code: `timeout` when it did not answer in time.
    var code: String
    var errorDescription: String? {
        message
    }

    init(_ tool: ExtensionTool, _ failure: ToolExtensionFailure) {
        message = "\(tool.extensionName) answered \(failure.code): \(failure.message)"
        code = failure.code
    }
}

extension ToolRunner {
    /// One call of an extension's tool. The files it returned are copied
    /// into the workspace's `Attachments/`, named in the text so file_read
    /// reads them, and listed in `details` for the app to show, as
    /// file_show's copies are; an image is put before the model as well.
    func runExtension(
        _ tool: ExtensionTool,
        arguments: JSONValue,
        cancellation: CancellationHandle?,
    ) async throws -> AgentToolResult {
        let sessions = toolExtensions
        let response = try await Self.untilCancelled(cancellation) {
            try await sessions.call(tool, arguments: arguments)
        }
        if let failure = response.failure {
            throw ToolExtensionError(tool, failure)
        }
        var copies: [AgentAttachment] = []
        var images: [ToolResultBlock] = []
        var listed: [String] = []
        do {
            for file in response.files {
                let data = try Self.read(file)
                let name = String((file.name ?? "file").prefix(255))
                let mimeType = file.mimeType ?? FileShow.mimeType(of: name, data: data)
                // Named as the session names a tool's image (`saveAttachment`).
                let path = "Attachments/" + UUID().uuidString.lowercased()
                try root.resolveForWrite(path).commit(data, exclusive: true)
                copies.append(AgentAttachment(path: path, name: name, mimeType: mimeType))
                listed.append("- \(path): \(name), \(mimeType), \(data.count) bytes")
                if let image = try? FileImage.read(data, frame: nil, name: name) {
                    images.append(.image(ImageContent(data: image.data.base64EncodedString(), mimeType: image.mimeType)))
                }
            }
        } catch {
            for copy in copies {
                unlink((root.path as NSString).appendingPathComponent(copy.path))
            }
            throw error
        }
        var parts = response.text.isEmpty ? [] : [response.text]
        if !listed.isEmpty {
            parts.append("Files it returned, shown to the user in this conversation and saved for file_read:\n"
                + listed.joined(separator: "\n"))
        }
        let text = parts.isEmpty ? "\(tool.name) answered with nothing." : parts.joined(separator: "\n\n")
        return AgentToolResult(content: [.text(TextContent(text: text))] + images, details: FileShow.details(copies))
    }

    /// A returned file whole, as large as an attachment may be.
    private static func read(_ file: ToolExtensionFile) throws -> Data {
        defer { file.descriptor.close() }
        let limit = AgentSession.maximumAttachmentBytes
        let handle = FileHandle(fileDescriptor: file.descriptor.rawValue, closeOnDealloc: false)
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else {
            throw ToolArgumentError("\(file.name ?? "A file") the tool returned is over the \(limit >> 20) MB an attachment may be")
        }
        return data
    }
}
