import Foundation

/// 一条用量记录：一次模型回复完成时由供应商统计的 token 数。
/// 与会话日志（events.jsonl）分开，落在数据根下，供设置页的用量统计读取。
/// 放在 ApelinCore：写入方（apelin-agent）与读取方（App）都用它，
/// App 不必为此引入 agent 的第三方依赖。
public struct UsageRecord: Codable, Sendable, Equatable {
    /// 记录时刻。
    public var time: Date
    /// 记录它的会话 id。
    public var sessionID: String
    /// 该会话的项目名（临时对话为其临时 id）。
    public var project: String
    /// 发出这次请求时使用的模型 id。
    public var model: String
    /// 全新读取的输入 token。
    public var input: Int
    /// 输出 token。
    public var output: Int
    /// 从缓存读取的输入 token。
    public var cacheRead: Int
    /// 写入缓存的输入 token。
    public var cacheWrite: Int

    public init(time: Date, sessionID: String, project: String, model: String,
                input: Int, output: Int, cacheRead: Int, cacheWrite: Int) {
        self.time = time
        self.sessionID = sessionID
        self.project = project
        self.model = model
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var promptTokens: Int { input + cacheRead + cacheWrite }
}

/// 用量记录器：向 `<数据根>/usage/usage.jsonl` 追加一条 JSON 行。
/// 追加失败只被放弃，绝不影响会话本身。
public struct UsageRecorder {
    public let root: URL

    /// `usage/usage.jsonl` 的位置。
    public static func file(in dataRootURL: URL) -> URL {
        dataRootURL.appendingPathComponent("usage", isDirectory: true)
            .appendingPathComponent("usage.jsonl", isDirectory: false)
    }

    public static let maximumLines = 5000

    public init(dataRoot: URL) {
        root = Self.file(in: dataRoot)
    }

    /// 追加一条记录。行数超过上限时从头截掉最旧的一半，避免文件无限增长。
    public func record(_ entry: UsageRecord) {
        do {
            let directory = root.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(entry)
            guard let line = String(data: data, encoding: .utf8) else { return }
            let handle = try FileHandle(forWritingTo: root)
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try handle.write(contentsOf: Data((line + "\n").utf8))
            try Self.trimIfNeeded(root, limit: Self.maximumLines)
        } catch {
            // 打不开、写不进都不算会话的错：静默放弃这一条。
        }
    }

    /// 文件行数超过 `limit` 时，保留最新的约一半。
    public static func trimIfNeeded(_ url: URL, limit: Int) throws {
        guard limit > 0,
              let current = try? String(contentsOf: url, encoding: .utf8),
              current.split(separator: "\n", omittingEmptySubsequences: false).count > limit else { return }
        let lines = current.split(separator: "\n", omittingEmptySubsequences: false)
        let kept = lines.suffix(limit / 2)
        let next = kept.joined(separator: "\n").appending("\n")
        try next.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 读出全部记录；坏行跳过，好行保留。
    public static func readAll(from url: URL) -> [UsageRecord] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap {
            try? decoder.decode(UsageRecord.self, from: Data($0.utf8))
        }
    }

    /// 清空全部记录：删掉文件本身。
    public static func clear(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
