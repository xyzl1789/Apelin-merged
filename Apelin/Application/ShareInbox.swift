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
