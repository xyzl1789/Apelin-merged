import Foundation

/// 累计行代表同一天、同一会话、模型与实际账号的多次请求；不是伪造的单次请求。
public struct UsageRollup: Sendable, Equatable {
    public var record: UsageRecord
    public var count: Int

    public init(record: UsageRecord, count: Int = 1) {
        self.record = record
        self.count = count
    }
}

/// 累计与明细来自同一个事务快照，清理明细不会减少累计。
public struct UsageSnapshot: Sendable {
    public var rollups: [UsageRollup]
    public var recent: [UsageRecord]
    public var unreadableLegacyLines: Int

    public init(rollups: [UsageRollup] = [], recent: [UsageRecord] = [], unreadableLegacyLines: Int = 0) {
        self.rollups = rollups
        self.recent = recent
        self.unreadableLegacyLines = unreadableLegacyLines
    }
}
