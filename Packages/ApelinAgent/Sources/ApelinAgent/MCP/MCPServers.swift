import Foundation
import KWWKAgent
import KWWKMCP

/// An MCP server the session may use. HTTP only (streamable HTTP, through
/// KWWKMCP): there is no stdio case to express, because stdio servers are
/// switched off on iOS upstream and §7 leaves them out of M1.
///
/// Header values may hold a token, so this value is never written into the
/// session directory.
public struct MCPServerConfiguration: Sendable, Hashable {
    public var name: String
    public var url: URL
    public var headers: [String: String]
    public var description: String?

    public init(name: String, url: URL, headers: [String: String] = [:], description: String? = nil) throws {
        guard let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" else {
            throw ToolArgumentError("MCP 服务器 \(name) 必须使用 http 或 https")
        }
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
            throw ToolArgumentError("MCP 服务器名称只能用字母、数字、_ 和 -")
        }
        self.name = name
        self.url = url
        self.headers = headers
        self.description = description
    }

    var kwwkConfig: MCPServerConfig {
        MCPServerConfig(name: name, transport: .http(url: url, headers: headers), description: description)
    }
}

/// Connects the configured servers and hands back their tools. Every MCP
/// tool is a system tool to the approval gate: a server's own description of
/// a tool is never a reason to let it through.
enum MCPBridge {
    static func connect(
        _ servers: [MCPServerConfiguration],
        timeout: TimeInterval = 15,
    ) async -> (MCPManager?, [AgentTool]) {
        guard !servers.isEmpty else { return (nil, []) }
        let manager = MCPManager(
            configs: servers.map(\.kwwkConfig),
            clientName: "Apelin",
            clientVersion: "1",
        )
        await manager.start()
        _ = await manager.waitForStartup(timeout: timeout)
        return await (manager, manager.tools().map(\.tool))
    }
}
