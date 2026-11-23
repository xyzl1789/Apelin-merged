import ApelinCore
import Foundation

/// 系统「分享到 Apelin」的收件箱：分享扩展把一批文件按
/// `<batch>/<id>/<原文件>` 写进 App Group，这里读取并在草稿入档后回执。
enum ShareInbox {
    struct Item {
        let batch: UUID
        let id: UUID
        let url: URL
    }

    private static var directory: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.wiki.qaq.apelin")?
            .appendingPathComponent("ShareInbox", isDirectory: true)
    }

    // 只走进真正的目录，绝不跟提供者给的符号链接。
    private static func children(_ parent: URL) -> [URL] {
        var info = stat()
        guard lstat(parent.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return [] }
        return (try? FileManager.default.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil)) ?? []
    }

    static func items() -> [Item] {
        guard let directory else { return [] }
        var result: [Item] = []
        for batch in children(directory) {
            guard let batchID = UUID(uuidString: batch.lastPathComponent) else { continue }
            for item in children(batch) {
                guard let id = UUID(uuidString: item.lastPathComponent), let file = children(item).first else { continue }
                var info = stat()
                guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
                result.append(Item(batch: batchID, id: id, url: file))
            }
        }
        return result
    }

    struct Pending: Sendable {
        let id: UUID
        let directory: URL
        let batch: ShareTransfer.Batch
    }

    struct StoredBatch: Sendable {
        let id: UUID
        let batch: ShareTransfer.Batch?
        let bytes: Int64
    }

    nonisolated static func storedBatches() -> [StoredBatch] {
        guard let root = ShareTransfer.root, ShareTransfer.isDirectory(root) else { return [] }
        return ShareTransfer.list(at: root.appendingPathComponent("Pending")).compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent), id.uuidString == url.lastPathComponent,
                  ShareTransfer.isDirectory(url) else { return nil }
            let bytes = ShareTransfer.list(at: url).reduce(Int64(0)) { $0 + (ShareTransfer.size(of: $1) ?? 0) }
            return StoredBatch(id: id, batch: try? ShareTransfer.batch(at: url), bytes: bytes)
        }.sorted { ($0.batch?.createdAt ?? .distantPast) < ($1.batch?.createdAt ?? .distantPast) }
    }

    /// 系统可能在复制中终止扩展；只收走一天前的未发布目录。
    nonisolated static func reapAbandonedStaging(now: Date = Date()) {
        guard let root = ShareTransfer.root, ShareTransfer.isDirectory(root) else { return }
        let staging = root.appendingPathComponent("Staging")
        for directory in ShareTransfer.list(at: staging) {
            guard let id = UUID(uuidString: directory.lastPathComponent), id.uuidString == directory.lastPathComponent,
                  ShareTransfer.isDirectory(directory),
                  let modified = try? directory.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) > 86_400 else { continue }
            try? FileManager.default.removeItem(at: directory)
        }
    }

    nonisolated static func pendingDirectory(_ id: UUID) -> URL? {
        guard let root = ShareTransfer.root, ShareTransfer.isDirectory(root) else { return nil }
        let pending = root.appendingPathComponent("Pending")
        guard ShareTransfer.isDirectory(pending) else { return nil }
        let directory = pending.appendingPathComponent(id.uuidString)
        return ShareTransfer.isDirectory(directory) ? directory : nil
    }

    nonisolated static func removeBatch(_ id: UUID) throws {
        guard let directory = pendingDirectory(id) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    nonisolated static func acknowledgeBatch(_ id: UUID) {
        try? removeBatch(id)
    }

    // 会话头是回执：崩溃后重复删除是安全的。
    static func acknowledge(_ attachments: [ComposerAttachment]) {
        guard let directory else { return }
        for attachment in attachments {
            guard let batch = attachment.shareBatch, let id = attachment.storedFile else { continue }
            let parent = directory.appendingPathComponent(batch.uuidString)
            let item = parent.appendingPathComponent(id.uuidString)
            guard let root = CanonicalPath.resolve(directory.path),
                  CanonicalPath.resolve(item.path) == root + "/" + batch.uuidString + "/" + id.uuidString
            else { continue }
            for file in children(item) { unlink(file.path) }
            rmdir(item.path)
            rmdir(parent.path)
        }
    }
}
