import Foundation

/// 代理和设置预览共用的项目说明读取器：先读 AGENTS.md，再读 CLAUDE.md。
/// 仅接受规范路径仍位于项目内的普通文件，保持现有正文上限和截断标记。
public enum ProjectInstructionsFile {
    public static let names = ["AGENTS.md", "CLAUDE.md"]
    public static let maximumBytes = 16 * 1024
    public static let truncationNote = "\n… (truncated)"

    public static func read(projectRoot: String) -> (file: String, text: String)? {
        guard let root = CanonicalPath.resolve(projectRoot) else { return nil }
        for file in names {
            guard let path = CanonicalPath.resolve(root + "/" + file),
                  CanonicalPath.isCanonical(path, inside: root),
                  let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let handle = FileHandle(forReadingAtPath: path) else { continue }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: maximumBytes + 1)) ?? Data()
            var text = String(decoding: data.prefix(maximumBytes), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            if data.count > maximumBytes {
                text += truncationNote
            }
            return (file, text)
        }
        return nil
    }
}
