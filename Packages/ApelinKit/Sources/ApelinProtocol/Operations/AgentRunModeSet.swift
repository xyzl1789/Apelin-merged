import Foundation

/// 这段对话**下一段**运行采用的模式，告诉一个已经打开的会话——读者在一轮
/// 运行中改了药丸，是想让排在它后面的消息以新模式运行，而不是让当前这轮
/// 中途停下或受限。nil 让对话回到下一条提示所说的模式。
///
/// 提示总会自带自己的模式（`AgentPromptRequest` 的 `runMode`），优先于这里；
/// 这里设的模式供本轮结束后由排队启动的那一轮使用，因为它没有提示随行。
public struct AgentSetRunModeRequest: OperationRequest {
    public typealias Response = Acknowledged
    public static let operation = AppOperation.agentSetRunMode

    public var sessionID: String
    public var mode: AgentRunMode?

    public init(sessionID: String, mode: AgentRunMode?) {
        self.sessionID = sessionID
        self.mode = mode
    }
}

public extension ApelinService {
    @discardableResult
    func agentSetRunMode(sessionID: String, mode: AgentRunMode?) async throws -> Acknowledged {
        try await send(AgentSetRunModeRequest(sessionID: sessionID, mode: mode))
    }
}
