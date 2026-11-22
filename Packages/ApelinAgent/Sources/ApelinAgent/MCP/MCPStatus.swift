import Foundation
import KWWKMCP

/// MCP 服务器在本会话里的连接状态。数值取自 KWWKMCP 自己报告的
/// `MCPServerStatus`，不读配置——配置里写了但没连上的服务器没有工具，
/// 不能当作可用的一样告诉模型。
///
/// 这里用自己的 `MCPServerPhase` 和 `MCPServerSummary`，测试不必构造
/// KWWKMCP 的内部类型；`init(statuses:)` 负责把上游状态翻译过来。
public enum MCPServerPhase: String, Sendable, Hashable {
    case connecting
    case connected
    case disconnected
    case failed
    case authorizationRequired = "authorization required"
    case closed
}

/// 一台服务器的状态摘要。reason 是服务器给的任意文本，已压成一行。
public struct MCPServerSummary: Sendable, Hashable {
    public var name: String
    public var phase: MCPServerPhase
    public var reason: String?
    public var toolCount: Int

    public init(name: String, phase: MCPServerPhase, reason: String? = nil, toolCount: Int) {
        self.name = name
        self.phase = phase
        self.reason = reason
        self.toolCount = toolCount
    }

    /// 断线或失败但上游仍保留工具时，工具依旧可调用。
    public var isAvailable: Bool {
        switch phase {
        case .connected: return true
        case .disconnected, .failed: return toolCount > 0
        case .connecting, .authorizationRequired, .closed: return false
        }
    }
}

public struct MCPStatusReport: Sendable, Hashable {
    public var servers: [MCPServerSummary]

    public init(_ servers: [MCPServerSummary]) {
        self.servers = servers
    }

    /// 把 KWWKMCP 报告的当前状态翻译成本报告。
    public init(statuses: [MCPServerStatus]) {
        servers = statuses.map { status in
            let phase: MCPServerPhase
            let reason: String?
            switch status.state {
            case .connecting:
                phase = .connecting
                reason = nil
            case .connected:
                phase = .connected
                reason = nil
            case .disconnected(let why):
                phase = .disconnected
                reason = why
            case .failed(let why):
                phase = .failed
                reason = why
            case .authorizationRequired(let why):
                phase = .authorizationRequired
                reason = why
            case .closed:
                phase = .closed
                reason = nil
            }
            return MCPServerSummary(
                name: status.name,
                phase: phase,
                reason: Self.brief(reason),
                toolCount: status.toolCount
            )
        }
    }

    /// 现在确实有工具的服务器名字，用来让系统提示词只列可用的服务器。
    public var availableNames: Set<String> {
        Set(servers.filter { $0.isAvailable }.map(\.name))
    }

    /// 服务器给的任意文本压成一行并限长，避免换行打断提示词块和会话日志。
    private static func brief(_ value: String?) -> String? {
        guard let value else { return nil }
        let oneLine = value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !oneLine.isEmpty else { return nil }
        return String(oneLine.prefix(200))
    }
}
