import ApelinCore
import Foundation

func checkShareTransfer() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let folders = try ShareTransfer.directories(root)
    let batchID = UUID()
    let staged = folders.staging.appendingPathComponent(batchID.uuidString)
    let pending = folders.pending.appendingPathComponent(batchID.uuidString)
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: false)
    let fileID = UUID()
    let file = ShareTransfer.File(id: fileID, name: "例子.txt", mimeType: "text/plain")
    let target = UUID()
    let text = "一段文字\nhttps://example.com/"
    let createdAt = Date()
    let original = ShareTransfer.Batch(target: target, text: text, files: [file], createdAt: createdAt)
    try ShareTransfer.write(original, to: staged)
    precondition(!FileManager.default.fileExists(atPath: pending.path))
    try Data([1, 2, 3]).write(to: staged.appendingPathComponent(fileID.uuidString))
    try FileManager.default.moveItem(at: staged, to: pending)
    var batch = try ShareTransfer.batch(at: pending)
    precondition(batch.target == target && batch.text == text && batch.files.first?.id == fileID)
    precondition(ShareTransfer.size(of: pending.appendingPathComponent(fileID.uuidString)) == 3)
    batch.target = nil
    try ShareTransfer.write(batch, to: pending)
    let retargeted = try ShareTransfer.batch(at: pending)
    precondition(retargeted.target == nil && retargeted.text == text && retargeted.files.first?.name == file.name)

    let duplicate = ShareTransfer.Batch(target: target, text: text, files: [file, file], createdAt: createdAt)
    try ShareTransfer.write(duplicate, to: pending)
    precondition((try? ShareTransfer.batch(at: pending)) == nil)
    let tooLong = ShareTransfer.Batch(target: target, text: String(repeating: "长", count: ShareTransfer.textLimit), files: [], createdAt: createdAt)
    try ShareTransfer.write(tooLong, to: pending)
    precondition((try? ShareTransfer.batch(at: pending)) == nil)

    let link = pending.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: root)
    precondition(!ShareTransfer.isDirectory(link) && ShareTransfer.size(of: link) == nil)

    let existing = ComposerAttachment(name: "已经存在的附件")
    let new = ComposerAttachment(name: file.name, storedFile: fileID, shareBatch: batchID)
    let a = ComposerDraft(text: "A 的草稿")
    var b = ComposerDraft(text: "B 的草稿", attachments: [existing])
    let oldID = b.id
    precondition(b.appendShare(text: text, files: [new], limit: ShareTransfer.fileLimit))
    precondition(b.id != oldID && b.text == "B 的草稿\n\n" + text)
    precondition(a.text == "A 的草稿" && a.attachments.isEmpty)
    precondition(b.attachments == [existing, new])
    let before = b.id
    precondition(!b.appendShare(text: "不得覆盖", files: [new], limit: 2))
    precondition(b.id == before && b.text == "B 的草稿\n\n" + text && b.attachments == [existing, new])

    var record = ChatRecord(summary: .untitled(lastInteraction: createdAt, projectName: nil), draft: b)
    record.receivedShares = [batchID]
    let data = try JSONEncoder().encode(record)
    let saved = try JSONDecoder().decode(ChatRecord.self, from: data)
    precondition(saved.receivedShares?.contains(batchID) == true && saved.draft.attachments.last?.shareBatch == batchID)

    // 工作区里后来写入同名路径的文件不能算作可清理的分享副本。
    let folder = DataFolder(root: root)
    let relative = "Attachments/" + UUID().uuidString.lowercased()
    let work = root.appendingPathComponent("Temporary/" + record.summary.id.uuidString)
    try FileManager.default.createDirectory(at: work.appendingPathComponent("Attachments"), withIntermediateDirectories: true)
    let copy = work.appendingPathComponent(relative)
    try Data([3, 2, 1]).write(to: copy)
    let history = SharedHistoryFile(path: relative, name: file.name, draftFile: fileID, summary: record.summary, folder: folder)
    precondition(history.localURL(in: record.summary, folder: folder) == copy)
    try Data([9, 8, 7, 6]).write(to: copy, options: .atomic)
    precondition(history.localURL(in: record.summary, folder: folder) == nil)
}
