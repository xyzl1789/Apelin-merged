import Foundation
import KWWKAI

/// 只识别供应商错误里的明确轮数限制；普通回复、工具输出与额度错误不参与。
enum ConversationTurnLimit {
    static func matches(_ message: String) -> Bool {
        let text = message.lowercased()
        guard text.contains("/compact"), text.contains("/new") else { return false }
        return text.range(
            of: #"当前会话模型已回复\s*[0-9]+\s*轮\s*[，,。.]\s*达到上限|this\s+conversation\s+has\s+reached\s+[0-9]+\s+model\s+turns\b"#,
            options: .regularExpression
        ) != nil
    }

    static func matchingMessage(_ candidates: [String?]) -> String? {
        candidates.compactMap { $0 }.first(where: { matches($0) })
    }

    static func matchingMessage(_ failure: ProviderFailure) -> String? {
        matchingMessage([failure.message, failure.upstreamMessage])
    }

    static func matches(_ failure: ProviderFailure) -> Bool {
        matchingMessage(failure) != nil
    }

    static func assistantCount(_ messages: [Message]) -> Int {
        messages.reduce(into: 0) { count, message in
            if case .assistant = message { count += 1 }
        }
    }
}
