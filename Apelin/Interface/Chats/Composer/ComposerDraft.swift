// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import Foundation

/// What a conversation has typed and attached but not sent; saved with its ChatRecord.
struct ComposerDraft: Codable, Sendable {
    var id = UUID()
    var text = ""
    var attachments: [ComposerAttachment] = []
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
