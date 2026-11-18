import Litext
import UIKit

/// 聊天内搜索的命中高亮中心，照 Minis 的 ChatSearchHighlightCenter：
/// 搜索侧只把「当前查询 + 当前聚焦的命中」交给它，渲染侧（消息行、
/// Markdown 视图）按消息 ID 来问自己的高亮状态。状态变化由
/// ChatController 通过 reconfigureRow 驱动，这里不主动通知。
@MainActor
final class ChatSearchHighlightCenter {
    /// 一条消息的高亮状态：在这段显示文本里找 `query`，本条是否是
    /// 当前聚焦的命中（下一处/上一处跳到的那条消息）。
    struct State: Equatable {
        let query: String
        let isCurrent: Bool
    }

    private(set) var query: String = ""
    private var currentMessageID: UUID?
    /// 搜索打开时命中的消息集合：只有这些行需要重配重绘。
    private(set) var highlightedIDs: Set<UUID> = []

    /// 搜索状态整体交给它；query 为空即清空。
    func apply(query: String, highlightedIDs: Set<UUID>, current: UUID?) {
        self.query = query
        self.highlightedIDs = query.isEmpty ? [] : highlightedIDs
        currentMessageID = query.isEmpty ? nil : current
    }

    func clear() {
        apply(query: "", highlightedIDs: [], current: nil)
    }

    func state(for messageID: UUID) -> State? {
        guard highlightedIDs.contains(messageID) else { return nil }
        return State(query: query, isCurrent: messageID == currentMessageID)
    }
}

/// 高亮颜色，照 Minis 的 ChatSearchHighlightStyle：全部命中是荧光笔黄，
/// 当前命中是更醒目的橙。只加背景色，不改行高与字号。
enum ChatSearchHighlightStyle {
    static func matchColor() -> UIColor {
        .systemYellow.withAlphaComponent(0.45)
    }

    static func currentColor() -> UIColor {
        .systemOrange.withAlphaComponent(0.85)
    }
}

/// 在显示文本上找出 query 的全部出现区间。与 SearchScorer 的折叠
/// （大小写、变音符号不敏感）一致，用 Foundation 的本地化搜索保持
/// 区间对齐原字符串，不自己在折叠串上定位（折叠会改变长度）。
enum ChatSearchMatcher {
    static func ranges(of query: String, in text: String) -> [NSRange] {
        guard !query.isEmpty, !text.isEmpty else { return [] }
        var result: [NSRange] = []
        let nsText = text as NSString
        var cursor = 0
        while cursor < nsText.length {
            let range = nsText.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: NSRange(location: cursor, length: nsText.length - cursor),
            )
            guard range.location != NSNotFound, range.length > 0 else { break }
            result.append(range)
            cursor = NSMaxRange(range)
        }
        return result
    }
}

/// 给 Litext 的 `lineRenderer` 用的绘制器：在每行的背景层，把该行内
/// 落在高亮区间里的字符画上色块。Litext 用 CoreText 绘制，字符串的
/// `.backgroundColor` 属性不会自动渲染，lineRenderer 正是官方为此留的
/// 钩子（流式动画帧也走它，所以高亮不会在渐显时丢）。
@MainActor
final class ChatSearchHighlightRenderer: TextLabel.LineRenderer {
    private var ranges: [NSRange] = []
    private var isCurrent = false
    private let matchColor = ChatSearchHighlightStyle.matchColor()
    private let currentColor = ChatSearchHighlightStyle.currentColor()

    /// `text` 是这段标签正显示的文本（Markdown 视图是渲染后文档的
    /// 字符串），区间在它上面定位，保证与绘制的字符对齐。
    func update(state: ChatSearchHighlightCenter.State?, text: String) {
        guard let state, !state.query.isEmpty else {
            ranges = []
            isCurrent = false
            return
        }
        ranges = ChatSearchMatcher.ranges(of: state.query, in: text)
        isCurrent = state.isCurrent
    }

    func clear() {
        ranges = []
        isCurrent = false
    }

    override func drawBackground(
        of line: CTLine,
        at _: Int,
        in context: CGContext,
        layout: TextLabel.Layout,
    ) {
        guard !ranges.isEmpty else { return }
        let cfRange = CTLineGetStringRange(line)
        let lineRange = NSRange(location: cfRange.location, length: cfRange.length)
        guard lineRange.location != NSNotFound, lineRange.length > 0 else { return }
        let text = layout.attributedString.string as NSString
        if !isCurrent {
            for range in ranges {
                draw(color: matchColor, range: range, lineRange: lineRange, text: text, layout: layout, context: context)
            }
        } else {
            // 当前命中的消息：先画全部命中的黄，再把每处画成橙盖上去。
            for range in ranges {
                draw(color: matchColor, range: range, lineRange: lineRange, text: text, layout: layout, context: context)
            }
            for range in ranges {
                draw(color: currentColor, range: range, lineRange: lineRange, text: text, layout: layout, context: context)
            }
        }
    }

    /// 一段出现区间与当前行相交部分的色块：取它的 CoreText 布局矩形
    /// 直接填充。drawBackground 收到的上下文已翻进 CoreText 空间
    /// （左下原点），rects(for:) 返回的也是这一空间。
    private func draw(
        color: UIColor,
        range: NSRange,
        lineRange: NSRange,
        text: NSString,
        layout: TextLabel.Layout,
        context: CGContext,
    ) {
        let overlap = NSIntersectionRange(range, lineRange)
        guard overlap.location != NSNotFound, overlap.length > 0 else { return }
        // 修整区间到字符边界，避免把代理对（emoji 等）从中剖开。
        var location = overlap.location
        var length = overlap.length
        while length > 0, location + length < text.length, text.character(at: location).isHighSurrogate {
            location += 1
            length -= 1
        }
        while length > 0, text.character(at: location + length - 1).isLowSurrogate {
            length -= 1
        }
        guard length > 0 else { return }
        let rects = layout.rects(for: NSRange(location: location, length: length))
        guard !rects.isEmpty else { return }
        context.saveGState()
        context.setFillColor(color.cgColor)
        for rect in rects {
            context.fill(rect)
        }
        context.restoreGState()
    }
}

private extension UniChar {
    /// UTF-16 代理对：高位 0xD800–0xDBFF，低位 0xDC00–0xDFFF。
    var isHighSurrogate: Bool { (0xD800 ... 0xDBFF).contains(self) }
    var isLowSurrogate: Bool { (0xDC00 ... 0xDFFF).contains(self) }
}
