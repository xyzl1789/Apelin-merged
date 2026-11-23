import Foundation

/// 扩展只接触这个 App Group：目标列表没有草稿、正文或凭据。
enum ShareTransfer {
    static let group = "group.wiki.qaq.apelin"
    // 只通知主应用读收件箱，不携带正文、文件路径或会话 ID。
    static let wakeURL = URL(string: "apelin://share")
    /// 唤起链接认的那一段。
    static let wakeKind = "share"

    /// 收到的链接是不是唤起收件箱：只认 `apelin://share`，尾部斜杠、
    /// 大小写或宽松写法 `apelin:share` 都算同一个，别的路径不算。
    static func wakes(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "apelin", url.query == nil, url.fragment == nil else { return false }
        let rest = url.pathComponents.filter { $0 != "/" }
        if let host = url.host?.lowercased(), !host.isEmpty { return host == wakeKind && rest.isEmpty }
        return rest == [wakeKind]
    }

    static let fileLimit = 8
    static let bytesLimit = 50 * 1024 * 1024
    static let textLimit = 64 * 1024

    struct Destination: Codable, Equatable, Sendable {
        let id: UUID
        let title: String
        let project: String?
    }

    struct File: Codable, Sendable {
        let id: UUID
        let name: String
        let mimeType: String?
    }

    struct Batch: Codable, Sendable {
        // nil 表示新建：批次 UUID 同时作为新会话 ID，重试不会新建第二次。
        var target: UUID?
        let text: String
        let files: [File]
        let createdAt: Date
        // 旧版暂存没有此字段，按「加入草稿」处理。
        var opensConversation: Bool?
    }

    static var root: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appendingPathComponent("ShareTransfers", isDirectory: true)
    }

    static func directories(_ root: URL) throws -> (pending: URL, staging: URL) {
        let pending = root.appendingPathComponent("Pending", isDirectory: true)
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        for url in [root, pending, staging] {
            if !FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
            guard isDirectory(url) else { throw CocoaError(.fileReadInvalidFileName) }
        }
        return (pending, staging)
    }

    static func isDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    struct FileIdentity: Codable, Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanos: Int64
    }

    static func identity(of url: URL) -> FileIdentity? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { return nil }
        return FileIdentity(device: Int32(info.st_dev), inode: UInt64(info.st_ino), size: info.st_size,
                            modifiedSeconds: Int64(info.st_mtimespec.tv_sec), modifiedNanos: Int64(info.st_mtimespec.tv_nsec))
    }

    static func size(of url: URL) -> Int64? { identity(of: url)?.size }

    static func list(at parent: URL) -> [URL] {
        guard isDirectory(parent) else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
    }

    static func batch(at directory: URL) throws -> Batch {
        let manifest = directory.appendingPathComponent("batch.json")
        guard isDirectory(directory), let size = size(of: manifest), size <= 512 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let batch = try JSONDecoder().decode(Batch.self, from: Data(contentsOf: manifest))
        guard batch.text.utf8.count <= textLimit, batch.files.count <= fileLimit,
              Set(batch.files.map(\.id)).count == batch.files.count,
              !batch.text.isEmpty || !batch.files.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return batch
    }

    static func write(_ batch: Batch, to directory: URL) throws {
        try JSONEncoder().encode(batch).write(to: directory.appendingPathComponent("batch.json"), options: .atomic)
    }

    static func destinations(at root: URL) -> [Destination] {
        let file = root.appendingPathComponent("destinations.json")
        guard isDirectory(root), let size = size(of: file), size <= 8 * 1024 * 1024,
              let data = try? Data(contentsOf: file) else { return [] }
        // 这是供扩展只读的会话快照；扩展从不回写。
        return (try? JSONDecoder().decode([Destination].self, from: data)) ?? [] // persisted-read: 只读投递目标快照
    }

    static func writeDestinations(_ destinations: [Destination]) throws {
        guard let root else { throw CocoaError(.fileNoSuchFile) }
        _ = try directories(root)
        try JSONEncoder().encode(destinations).write(to: root.appendingPathComponent("destinations.json"), options: .atomic)
    }
}
