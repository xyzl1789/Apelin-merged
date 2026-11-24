import Foundation

/// 每日签到属于哪些平台。每个平台的登录凭据与「模型服务商」里的是同一份，
/// 因此这里只认登录过的账号，不另存 token。
public enum CheckInPlatform: String, Codable, Sendable, CaseIterable {
    case workBuddy = "workbuddy"
    case workBuddyAI = "workbuddy-ai"
    case traeCN = "trae-cn"
    case qoderCN = "qoder-cn"
    case qoder = "qoder"

    /// 平台自己的名字，品牌名不翻译。
    public var brand: String {
        switch self {
        case .workBuddy: "WorkBuddy"
        case .workBuddyAI: "WorkBuddy AI"
        case .traeCN: "Trae CN"
        case .qoderCN: "Qoder CN"
        case .qoder: "Qoder"
        }
    }
}

/// 成长中心里一项动作的结果。只带标题、成败和一句已经翻好的原因，
/// 服务端正文与 token 都不进这里，穿过协议线也就到不了界面。
public struct CheckInDetail: Codable, Sendable, Equatable {
    public var title: String
    public var succeeded: Bool
    /// 一句中文说明（成功写拿到什么，失败写为什么没做成），最多 120 字符。
    public var note: String

    public init(title: String, succeeded: Bool, note: String) {
        self.title = String(title.prefix(80))
        self.succeeded = succeeded
        self.note = String(note.prefix(120))
    }
}

/// 一个平台今天的结果。`claimed` 与 `alreadyClaimed` 是「今天签到了」，
/// 服务端不会给第二次；`nothingToDo` 是没有活动可领，明天再问。
public enum CheckInOutcome: String, Codable, Sendable {
    case claimed
    case alreadyClaimed
    case nothingToDo
    case notSignedIn
    case failed
}

/// 失败时机器可读的原因，页面自己翻成本地话。服务端正文（可能含 token 或
/// 账号信息）永远不回给 App。
public enum CheckInReason: String, Codable, Sendable {
    /// 凭据缺失或已失效，需要重新登录这个账号。
    case signedOut
    case network
    /// 服务端限流，今天稍晚再试。
    case rateLimited
    /// 服务端拒绝了这个请求（设备标识被拒、领取被拒）。
    case rejected
    /// 服务端错误码或无法识别的响应。
    case server
}

/// 一个平台一次签到的结果，可直接缓存与展示：不含 token，也不含响应正文。
public struct CheckInResult: Codable, Sendable, Equatable {
    public var platform: CheckInPlatform
    public var outcome: CheckInOutcome
    /// 本次或今日领到的积分，服务端给的写法，最多 32 字符。
    public var credit: String?
    /// 账户当前可用积分/额度；查不到时保持 nil，绝不写成 0。
    public var available: String?
    /// 账户累计已用积分/额度；查不到时保持 nil。
    public var used: String?
    /// 活动累计积分等平台额外统计，不能当作当前余额。
    public var total: String?
    /// 连续签到天数。
    public var streak: Int?
    /// 失败或「没有活动」时的原因，页面据此本地化。
    public var reason: CheckInReason?
    /// 成长中心里各动作的结果：没做完的写清原因，红点据此亮起。
    public var details: [CheckInDetail]?
    /// 这次结果是谁给的、什么时候，缓存按本地日历日判断是否还新鲜。
    public var updatedAt: Date

    public init(platform: CheckInPlatform, outcome: CheckInOutcome, credit: String? = nil,
                available: String? = nil, used: String? = nil, total: String? = nil,
                streak: Int? = nil, reason: CheckInReason? = nil,
                details: [CheckInDetail]? = nil, updatedAt: Date = Date()) {
        self.platform = platform
        self.outcome = outcome
        self.credit = credit
        self.available = available
        self.used = used
        self.total = total
        self.streak = streak
        self.reason = reason
        self.details = details
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case platform, outcome, credit, available, used, total, streak, reason, details, updatedAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        platform = try values.decode(CheckInPlatform.self, forKey: .platform)
        outcome = try values.decode(CheckInOutcome.self, forKey: .outcome)
        credit = try values.decodeIfPresent(String.self, forKey: .credit)
        available = try values.decodeIfPresent(String.self, forKey: .available)
        used = try values.decodeIfPresent(String.self, forKey: .used)
        total = try values.decodeIfPresent(String.self, forKey: .total)
        streak = try values.decodeIfPresent(Int.self, forKey: .streak)
        reason = try values.decodeIfPresent(CheckInReason.self, forKey: .reason)
        details = try values.decodeIfPresent([CheckInDetail].self, forKey: .details)
        updatedAt = try values.decode(Date.self, forKey: .updatedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(platform, forKey: .platform)
        try values.encode(outcome, forKey: .outcome)
        try values.encodeIfPresent(credit, forKey: .credit)
        try values.encodeIfPresent(available, forKey: .available)
        try values.encodeIfPresent(used, forKey: .used)
        try values.encodeIfPresent(total, forKey: .total)
        try values.encodeIfPresent(streak, forKey: .streak)
        try values.encodeIfPresent(reason, forKey: .reason)
        try values.encodeIfPresent(details, forKey: .details)
        try values.encode(updatedAt, forKey: .updatedAt)
    }

    /// 今天已经签过（领取成功或服务端说领过了）。
    public var isDone: Bool {
        outcome == .claimed || outcome == .alreadyClaimed
    }
}

/// 签到请求：`platforms` 为空表示所有平台都问一遍；`force` 为 false 时
/// worker 复用当天缓存，因此设置页打开一次不会重复请求服务端。
public struct AgentCheckInRequest: OperationRequest {
    public typealias Response = AgentCheckInResponse
    public static let operation = AppOperation.agentCheckIn
    public var platforms: [CheckInPlatform]
    public var force: Bool
    public init(platforms: [CheckInPlatform] = [], force: Bool = false) {
        self.platforms = platforms
        self.force = force
    }
}

/// 每个被问到的平台一行，未登录的也在里面，页面才知道哪一行该怎么写。
public struct AgentCheckInResponse: Codable, Sendable, Equatable {
    public var results: [CheckInResult]
    public init(results: [CheckInResult] = []) {
        self.results = results
    }
}

public extension ApelinService {
    func agentCheckIn(platforms: [CheckInPlatform] = [], force: Bool = false) async throws -> AgentCheckInResponse {
        try await send(AgentCheckInRequest(platforms: platforms, force: force))
    }
}
