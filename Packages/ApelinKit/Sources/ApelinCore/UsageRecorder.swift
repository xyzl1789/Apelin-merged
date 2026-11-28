import Foundation
import os

/// 一条用量记录：一次模型回复完成时由供应商统计的 token 数。
/// 与会话日志（events.jsonl）分开，落在数据根下，供设置页的用量统计读取。
/// 放在 ApelinCore：写入方（apelin-agent）与读取方（App）都用它，
/// App 不必为此引入 agent 的第三方依赖。
public struct UsageRecord: Codable, Sendable, Equatable {
    /// 记录时刻。
    public var time: Date
    /// 一次模型回复的稳定标识；老文件缺少它时由迁移器按原行及出现次序生成标识。
    public var requestID: String?
    /// 记录它的会话 id。
    public var sessionID: String
    /// 该会话的项目名（临时对话为其临时 id）。
    public var project: String
    /// 发出这次请求时使用的模型 id。
    public var model: String
    /// 该请求走的供应商 id（如 `anthropic`、`openai`）；旧记录没有此字段，
    /// 读作 nil，统计里归到「未知」。
    public var provider: String?
    /// 实际使用的服务商实例与安全域名；旧记录缺少此字段，保持原来的分组。
    public var providerIdentity: UsageProviderIdentity?
    /// 全新读取的输入 token。
    public var input: Int
    /// 输出 token。
    public var output: Int
    /// 从缓存读取的输入 token。
    public var cacheRead: Int
    /// 写入缓存的输入 token。
    public var cacheWrite: Int

    public init(time: Date, sessionID: String, project: String, model: String,
                provider: String? = nil, providerIdentity: UsageProviderIdentity? = nil,
                input: Int, output: Int, cacheRead: Int, cacheWrite: Int,
                requestID: String? = UUID().uuidString) {
        self.requestID = requestID
        self.time = time
        self.sessionID = sessionID
        self.project = project
        self.model = model
        self.provider = provider
        self.providerIdentity = providerIdentity
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    public var promptTokens: Int { input + cacheRead + cacheWrite }
}

/// 用量写入门面。旧 JSONL 仅作为一次性导入源，之后只写事务账本。
public struct UsageRecorder {
    public let root: URL
    private static let log = Logger(subsystem: "wiki.qaq.apelin", category: "用量账本")

    /// 旧文件位置不变，升级时保留原件，不再裁剪或追加。
    public static func file(in dataRootURL: URL) -> URL {
        dataRootURL.appendingPathComponent("usage", isDirectory: true)
            .appendingPathComponent("usage.jsonl", isDirectory: false)
    }

    public static let maximumLines = 5000

    public init(dataRoot: URL) {
        root = Self.file(in: dataRoot)
    }

    private var ledger: UsageLedger {
        UsageLedger(dataRoot: root.deletingLastPathComponent().deletingLastPathComponent(), recentLimit: Self.maximumLines)
    }

    public static func requestID<Message: Encodable>(sessionID: String, message: Message) -> String {
        do { return try UsageLedger.requestID(sessionID: sessionID, message: message) }
        catch {
            log.error("无法生成用量去重标识，已为本次记录分配独立标识。")
            return UUID().uuidString
        }
    }

    /// 失败不打断对话。已进入待入账目录的请求会在后续读写时重试。
    @discardableResult
    public func record(_ entry: UsageRecord) -> Bool {
        do {
            try ledger.record(entry)
            return true
        } catch {
            Self.log.error("用量暂未入账；若待入账记录已落盘，后续将自动重试。")
            return false
        }
    }

    /// 兼容旧读取接口，只返回近期明细。累计统计必须用 snapshot()。
    public static func readAll(from url: URL) -> [UsageRecord] {
        do {
            return try UsageLedger(dataRoot: url.deletingLastPathComponent().deletingLastPathComponent()).snapshot().recent
        } catch {
            log.error("无法读取近期用量，原数据已保留。")
            return []
        }
    }
}
