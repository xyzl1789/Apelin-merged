import Foundation

/// 按消息、文本和宽度保存 Markdown 文档高度，避免流式批次重复解析。
@MainActor
enum ChatRowHeights {
    private struct Key: Hashable {
        let id: UUID
        let text: String
        let width: CGFloat
        let textSize: String
    }

    private static var heights: [Key: CGFloat] = [:]
    private static let capacity = 192

    static func height(id: UUID, text: String, width: CGFloat, textSize: String) -> CGFloat? {
        heights[Key(id: id, text: text, width: width, textSize: textSize)]
    }

    static func store(_ height: CGFloat, id: UUID, text: String, width: CGFloat, textSize: String) {
        guard height.isFinite, height > 0 else { return }
        if heights.count >= capacity {
            heights.removeAll(keepingCapacity: true)
        }
        heights[Key(id: id, text: text, width: width, textSize: textSize)] = height
    }

    /// 切换对话或重建列表后，旧对话的测量不能复用。
    static func forget() {
        heights.removeAll(keepingCapacity: true)
    }
}
