import ApelinProtocol
import Foundation

/// 模型在回复正文里写的 `![描述](文件.png)`、`[文件](报告.md)` 引用：
/// 指向会话目录内文件的，解析成消息附件，走现有的相册与文件卡片管线；
/// http(s) 等外链、锚点与代码块里的引用都不算。
enum ChatInlineFiles {
    /// 扫描正文，返回每处图片引用与其在文本里的 NSRange（供移除）。
    /// 逐行扫，跳过围栏代码块；行内代码里的引用不算。
    static func imageReferences(in text: String) -> [(range: NSRange, path: String)] {
        let ns = text as NSString
        var results: [(NSRange, String)] = []
        var insideFence = false
        var offset = 0
        for rawLine in text.components(separatedBy: "\n") {
            let lineLength = (rawLine as NSString).length
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                offset += lineLength + 1
                continue
            }
            if !insideFence {
                var position = offset
                let end = offset + lineLength
                while position < end {
                    guard let match = firstImageReference(in: ns, range: NSRange(location: position, length: end - position))
                    else { break }
                    results.append((match.range, match.path))
                    position = NSMaxRange(match.range)
                }
            }
            offset += lineLength + 1
        }
        return results.map { ($0.0, $0.1) }
    }

    private static func firstImageReference(in ns: NSString, range: NSRange) -> (range: NSRange, path: String)? {
        let bang = ns.range(of: "![", options: [], range: range)
        guard bang.location != NSNotFound else { return nil }
        let search = NSRange(location: NSMaxRange(bang), length: ns.length - NSMaxRange(bang))
        let closeAlt = ns.range(of: "](", options: [], range: search)
        guard closeAlt.location != NSNotFound else { return nil }
        let after = NSRange(location: NSMaxRange(closeAlt), length: ns.length - NSMaxRange(closeAlt))
        let closePath = ns.range(of: ")", options: [], range: after)
        guard closePath.location != NSNotFound else { return nil }
        let path = ns.substring(with: NSRange(location: NSMaxRange(closeAlt), length: closePath.location - NSMaxRange(closeAlt)))
        guard !path.isEmpty, !path.contains("("), !path.contains(")") else { return nil }
        // 外链与锚点不算文件。
        let lower = path.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("mailto:")
            || lower.hasPrefix("apelin://") || lower.hasPrefix("#")
        {
            return nil
        }
        let full = NSRange(location: bang.location, length: NSMaxRange(closePath) - bang.location)
        return (full, path)
    }

    /// 引用的扩展名是不是系统可直接显示的图片（PNG/JPG/GIF/WebP/SVG 等）。
    static func isImagePath(_ path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        let imageExts = ["png", "jpg", "jpeg", "gif", "webp", "svg", "heic", "heif", "bmp", "tiff", "ico"]
        return imageExts.contains(ext)
    }

    /// 把正文里已解析成附件的图片引用整条移除（连同行尾换行），
    /// 避免相册下面再出现一行死路径；留下的连续空行合并掉。
    static func removingImageReferences(_ text: String, ranges: [NSRange]) -> String {
        guard !ranges.isEmpty else { return text }
        let ns = NSMutableAttributedString(string: text)
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            guard range.location != NSNotFound, NSMaxRange(range) <= ns.length else { continue }
            var deletion = range
            if NSMaxRange(range) < ns.length, (ns.string as NSString).character(at: NSMaxRange(range)) == 0x0A {
                deletion.length += 1
            }
            ns.deleteCharacters(in: deletion)
        }
        var result = ns.string
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        if result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ""
        }
        // 引用常在段落结尾：收掉尾部的空行与空白。
        return result.trimmingCharacters(in: CharacterSet(charactersIn: " \t\n\r"))
    }
}
