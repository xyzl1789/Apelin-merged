import Darwin
import Foundation

/// One HTTP MCP server, as every process that opens an agent session needs
/// to see it. The app stores these records, the host carries them on an open
/// request, and the worker turns them into KWWKMCP's configuration. Header
/// values may hold a token, so the file is 0600 and never goes in a session
/// directory.
public struct MCPConnection: Codable, Equatable, Hashable, Sendable {
    public var name: String
    public var url: String
    public var headers: [String: String]
    public var note: String?

    public init(name: String, url: String, headers: [String: String] = [:], note: String? = nil) throws {
        guard Self.validName(name) else { throw MCPStoreError.invalidName }
        guard let parsed = URL(string: url),
              let scheme = parsed.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              parsed.host?.isEmpty == false
        else { throw MCPStoreError.invalidURL }
        guard url.utf8.count <= 2048 else { throw MCPStoreError.invalidURL }
        guard headers.count <= 64,
              headers.allSatisfy({ $0.key.utf8.count <= 256 && $0.value.utf8.count <= 8192 })
        else { throw MCPStoreError.invalidHeader }
        for (key, value) in headers {
            guard !key.isEmpty, key.utf8.allSatisfy({
                (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) ||
                "!#$%&'*+-.^_`|~".utf8.contains($0)
            }), !value.utf8.contains(0),
                  !value.contains(where: { $0.isNewline || $0 == "\r" })
            else { throw MCPStoreError.invalidHeader }
        }
        self.name = name
        self.url = url
        self.headers = headers
        self.note = note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    public init(from decoder: Decoder) throws {
        let value = try Stored(from: decoder)
        try self.init(name: value.name, url: value.url, headers: value.headers, note: value.note)
    }

    private struct Stored: Decodable {
        var name: String
        var url: String
        var headers: [String: String]
        var note: String?
    }

    public static func validName(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64, name.utf8.allSatisfy({
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45
        }) else { return false }
        return true
    }

    /// The parsed URL, after `init` has validated it. The failable form is
    /// deliberate: a record read from disk has already passed validation.
    public var parsedURL: URL? { URL(string: url) }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// A stored server: its connection and whether the agent should connect to
/// it. Disabling keeps the record (and any token in it) for later.
public struct MCPServerRecord: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public var connection: MCPConnection
    public var enabled: Bool

    public init(id: String = UUID().uuidString.lowercased(), connection: MCPConnection, enabled: Bool = true) {
        self.id = id
        self.connection = connection
        self.enabled = enabled
    }
}

/// The whole file. Unreadable records are kept as they were, never replaced
/// by an empty list the next save would make permanent.
public struct MCPServerSnapshot: Codable {
    public var servers: PreservedList<MCPServerRecord>

    public init(servers: [MCPServerRecord] = [], unreadable: [JSONValue] = []) {
        self.servers = PreservedList(servers, unreadable: unreadable)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        servers = try container.decode(PreservedList<MCPServerRecord>.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(servers)
    }
}

/// Reads and writes `MCP/servers.json` under the app's data folder. One disk
/// authority: every mutation locks, rereads, validates and writes a fresh
/// file by rename. A file that does not read at all is set aside, never
/// silently replaced.
public struct MCPServerStore: Sendable {
    public static let maximumServers = 32
    private static let maximumFileBytes = 1024 * 1024
    private let root: URL

    public init(root: URL) {
        self.root = root
    }

    public var file: URL {
        root.appendingPathComponent("MCP", isDirectory: true)
            .appendingPathComponent("servers.json")
    }

    public func read() throws -> MCPServerSnapshot {
        var info = stat()
        guard lstat(file.path, &info) == 0 else {
            if errno == ENOENT { return MCPServerSnapshot() }
            throw MCPStoreError.unsafeFile
        }
        guard info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_mode & 0o077 == 0
        else { throw MCPStoreError.unsafeFile }
        guard let canonicalRoot = CanonicalPath.resolve(root.path),
              let canonicalDirectory = CanonicalPath.resolve(file.deletingLastPathComponent().path),
              CanonicalPath.isCanonical(canonicalDirectory, inside: canonicalRoot),
              CanonicalPath.components(canonicalDirectory).count == CanonicalPath.components(canonicalRoot).count + 1,
              CanonicalPath.components(canonicalDirectory).last == "MCP"
        else { throw MCPStoreError.unsafeFile }
        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            if (error as? CocoaError)?.code == .fileReadNoSuchFile { return MCPServerSnapshot() }
            throw error
        }
        guard data.count <= Self.maximumFileBytes else { throw MCPStoreError.full }
        do {
            let value = try JSONDecoder().decode(MCPServerSnapshot.self, from: data)
            try validate(value)
            return value
        } catch is DecodingError {
            // A damaged file is kept beside itself, not overwritten.
            guard UnreadableFile.setAside(file) != nil else { throw MCPStoreError.unsafeFile }
            return MCPServerSnapshot()
        }
    }

    @discardableResult
    public func save(_ snapshot: MCPServerSnapshot) throws -> MCPServerSnapshot {
        try validate(snapshot)
        let folder = DataFolder(root: root)
        let directory = file.deletingLastPathComponent()
        try folder.makeLevels(to: directory)
        guard let canonicalRoot = CanonicalPath.resolve(root.path),
              let canonicalDirectory = CanonicalPath.resolve(directory.path),
              CanonicalPath.isCanonical(canonicalDirectory, inside: canonicalRoot),
              CanonicalPath.components(canonicalDirectory).count == CanonicalPath.components(canonicalRoot).count + 1,
              CanonicalPath.components(canonicalDirectory).last == "MCP"
        else { throw MCPStoreError.unsafeFile }
        // Header values may be tokens: only mobile may read this folder.
        guard chmod(canonicalDirectory, 0o700) == 0 else { throw posixError() }
        let descriptor = open(canonicalDirectory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw posixError() }
        defer { close(descriptor) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(snapshot)
        guard data.count <= Self.maximumFileBytes else { throw MCPStoreError.full }
        let temporary = ".servers-\(UUID().uuidString).tmp"
        let output = openat(descriptor, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard output >= 0 else { throw posixError() }
        defer { close(output); unlinkat(descriptor, temporary, 0) }
        let handle = FileHandle(fileDescriptor: output, closeOnDealloc: false)
        try handle.write(contentsOf: data)
        guard fsync(output) == 0,
              renameat(descriptor, temporary, descriptor, "servers.json") == 0,
              fsync(descriptor) == 0
        else { throw posixError() }
        return snapshot
    }

    public func enabledConnections() throws -> [MCPConnection] {
        try read().servers.items.filter(\.enabled).map(\.connection)
    }

    private func validate(_ snapshot: MCPServerSnapshot) throws {
        let records = snapshot.servers.items
        guard records.count + snapshot.servers.unreadable.count <= Self.maximumServers else { throw MCPStoreError.full }
        var ids = Set<String>()
        var names = Set<String>()
        for record in records {
            guard !record.id.isEmpty, !record.id.utf8.contains(0), ids.insert(record.id).inserted else {
                throw MCPStoreError.duplicateID
            }
            // Recheck on read too: a record edited outside the app must not
            // reach the worker with a scheme or name the bridge rejects.
            _ = try MCPConnection(
                name: record.connection.name,
                url: record.connection.url,
                headers: record.connection.headers,
                note: record.connection.note
            )
            guard names.insert(record.connection.name).inserted else { throw MCPStoreError.duplicateName }
        }
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
}

public enum MCPStoreError: Error, Equatable, LocalizedError {
    case invalidName
    case invalidURL
    case invalidHeader
    case duplicateID
    case duplicateName
    case full
    case unsafeFile

    public var errorDescription: String? {
        switch self {
        case .invalidName: return "MCP 服务器名称只能用英文字母、数字、_ 和 -，且不超过 64 个字符。"
        case .invalidURL: return "MCP 服务器地址必须是有效的 http 或 https URL。"
        case .invalidHeader: return "MCP 请求头格式无效，或超过长度限制。"
        case .duplicateID: return "MCP 服务器记录 ID 重复。"
        case .duplicateName: return "MCP 服务器名称不能重复。"
        case .full: return "MCP 服务器数量或配置文件已达上限。"
        case .unsafeFile: return "MCP 配置文件无法安全读写。"
        }
    }
}
