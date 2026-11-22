import ApelinCore
import ApelinProtocol
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

/// Read-only tool enumeration used by Settings. It creates a short-lived
/// client, lists tools, then closes the HTTP session without retaining auth.
public enum MCPServerToolInspector {
    public static func list(
        name: String,
        url: String,
        headers: [String: String],
        timeout: TimeInterval = 15,
    ) async throws -> [AgentMCPToolSummary] {
        guard let endpoint = URL(string: url),
              let scheme = endpoint.scheme?.lowercased(), scheme == "http" || scheme == "https",
              endpoint.host?.isEmpty == false
        else { throw ToolArgumentError("MCP 服务器地址无效") }
        let connection = try MCPServerConfiguration(name: name, url: endpoint, headers: headers)
        let client = MCPClient(
            transport: MCPStreamableHTTPTransport(
                url: connection.url, headers: connection.headers,
                requestTimeoutSeconds: timeout,
            ),
            clientName: "Apelin",
            clientVersion: "1",
            requestTimeoutSeconds: timeout,
        )
        do {
            try await client.connect(timeoutSeconds: timeout)
            let tools = try await client.listTools(timeoutSeconds: timeout)
            await client.close()
            return tools.prefix(256).map { tool in
                AgentMCPToolSummary(
                    name: String(tool.name.prefix(256)),
                    description: tool.description.map { String($0.prefix(2_000)) },
                )
            }
        } catch {
            await client.close()
            throw MCPServerToolInspectionError.unavailable
        }
    }
}

public enum MCPServerToolInspectionError: Error, LocalizedError, Sendable {
    case unavailable

    public var errorDescription: String? {
        "无法连接 MCP 服务器或读取工具列表，请检查服务器地址与请求头。"
    }
}
