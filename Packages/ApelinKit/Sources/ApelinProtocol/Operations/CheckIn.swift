import Foundation

/// 每日签到属于哪些平台。每个平台的登录凭据与「模型服务商」里的是同一份，
/// 因此这里只认登录过的账号，不另存 token。
public enum CheckInPlatform: String, Codable, Sendable, CaseIterable {
    case workBuddy = "workbuddy"
    case traeCN = "trae-cn"
    case qoderCN = "qoder-cn"

    /// 平台自己的名字，品牌名不翻译。
    public var brand: String {
        switch self {
        case .workBuddy: "WorkBuddy"
        case .traeCN: "Trae CN"
        case .qoderCN: "Qoder CN"
        }
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
    /// 账户累计积分，只有服务端给了才有。
    public var total: String?
    /// 连续签到天数。
    public var streak: Int?
    /// 失败或「没有活动」时的原因，页面据此本地化。
    public var reason: CheckInReason?
    /// 这次结果是谁给的、什么时候，缓存按本地日历日判断是否还新鲜。
    public var updatedAt: Date

    public init(platform: CheckInPlatform, outcome: CheckInOutcome, credit: String? = nil,
                total: String? = nil, streak: Int? = nil, reason: CheckInReason? = nil,
                updatedAt: Date = Date()) {
        self.platform = platform
        self.outcome = outcome
        self.credit = credit
        self.total = total
        self.streak = streak
        self.reason = reason
        self.updatedAt = updatedAt
    }

    /// 今天已经签过（领取成功或服务端说领过了）。
    public var isDone: Bool {
        outcome == .claimed || outcome == .alreadyClaimed
    }
}

/// 签到请求：`platforms` 为空表示三个平台都问一遍；`force` 为 false 时
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
