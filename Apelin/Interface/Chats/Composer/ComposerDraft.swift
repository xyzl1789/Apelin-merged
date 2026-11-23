// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Foundation

/// What a conversation has typed and attached but not sent; saved with its ChatRecord.
struct ComposerDraft: Codable, Sendable {
    var id = UUID()
    var text = ""
    var attachments: [ComposerAttachment] = []

    mutating func appendShare(text: String, files: [ComposerAttachment], limit: Int) -> Bool {
        guard attachments.count + files.count <= limit else { return false }
        // 旧发送回执不能清掉分享后已变化的草稿，即使文字未改。
        id = UUID()
        if !text.isEmpty {
            if !self.text.isEmpty { self.text += "\n\n" }
            self.text += text
        }
        attachments += files
        return true
    }
}

struct ComposerAttachment: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    var name: String
    /// 旧草稿的内联数据与粘贴的文本、照片都走这里；文件导入只留磁盘副本的 UUID。
    var data = Data()
    var text: String?
    var isImage = false
    /// 指向数据文件夹里的副本，绝不存外部路径。
    var storedFile: UUID?
    var storedBytes: Int?
    var mimeType: String?
    var shareBatch: UUID?

    var byteCount: Int { storedBytes ?? data.count }
}
