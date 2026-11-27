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
        let opening: Task<String, Error>
        var closing: Task<Void, Never>?

        init(version: String, opening: Task<String, Error>) {
            self.version = version
            self.opening = opening
        }
    }

    private let backend: any AgentHostBackend
    private var entries: [String: Entry] = [:]
    private var closed = false
    private var shutdown: Task<Void, Never>?

    init(backend: any AgentHostBackend) {
        self.backend = backend
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
                await retire(entry).value
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

    func closeAll() async {
        if let shutdown {
            await shutdown.value
            return
        }
        closed = true
        let pending = entries.keys.sorted().compactMap { entries[$0] }
        entries = [:]
        let shutdown = Task {
            for entry in pending { await retire(entry).value }
        }
        self.shutdown = shutdown
        await shutdown.value
    }

    private func session(for tool: ExtensionTool) async throws -> (Entry, String) {
        guard !closed else { throw Self.closing }
        let entry: Entry
        if let current = entries[tool.extensionID], current.version == tool.extensionVersion, current.closing == nil {
            entry = current
        } else {
            let previous = entries[tool.extensionID].map { retire($0) }
            let backend = backend
            let extensionID = tool.extensionID
            let opening = Task {
                if let previous { await previous.value }
                return try await backend.openToolExtension(id: extensionID)
            }
            entry = Entry(version: tool.extensionVersion, opening: opening)
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
        guard !closed, entries[tool.extensionID] === entry else {
            await retire(entry).value
            throw Self.closing
        }
        return (entry, session)
    }

    /// 无论升级、关闭还是迟到的打开结果，每个实际会话只关闭一次。
    private func retire(_ entry: Entry) -> Task<Void, Never> {
        if let closing = entry.closing { return closing }
        let opening = entry.opening
        let backend = backend
        let closing = Task {
            if let session = try? await opening.value {
                try? await backend.closeToolExtension(sessionID: session)
            }
        }
        entry.closing = closing
        return closing
    }

    private static let closing = ConversationClosingError()

    private static func request(_ tool: ExtensionTool, _ arguments: JSONValue, in session: String) -> ToolExtensionCallRequest {
        ToolExtensionCallRequest(sessionID: session, tool: tool.name, arguments: arguments, timeoutSeconds: tool.timeoutSeconds)
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
