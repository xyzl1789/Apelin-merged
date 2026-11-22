@testable import ApelinAgent
import Testing

/// MCP 状态的离线测试：不连接服务器，只验证有工具的服务器会被标记为可用。
@Suite("MCP 连接状态报告")
struct MCPStatusReportTests {
    @Test
    func `只把真正有工具的服务器列为可用，断线但保留工具的仍可用`() {
        let report = MCPStatusReport([
            .init(name: "docs", phase: .connected, toolCount: 2),
            .init(name: "auth", phase: .authorizationRequired, reason: "401", toolCount: 0),
            .init(name: "down", phase: .failed, reason: "连接被拒绝", toolCount: 0),
            .init(name: "flaky", phase: .disconnected, reason: "连接重置", toolCount: 3),
            .init(name: "later", phase: .connecting, toolCount: 0),
        ])
        #expect(report.availableNames == ["docs", "flaky"])
        #expect(!report.availableNames.contains("auth"))
        #expect(!report.availableNames.contains("down"))
        #expect(!report.availableNames.contains("later"))
    }
}
