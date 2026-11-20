@testable import ApelinAgent
import Testing

/// 连接状态报告的离线测试：不连任何服务器，只检查从状态到提示词/日志的翻译。
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

    @Test
    func `不可用的服务器进入 system-state，原因压成一行`() throws {
        let report = MCPStatusReport([
            .init(name: "docs", phase: .connected, toolCount: 1),
            .init(name: "down", phase: .failed, reason: "line1\nline2", toolCount: 0),
        ])
        let line = try #require(report.stateLine)
        #expect(line.contains("down (failed: line1 line2)"))
        #expect(line.hasPrefix("- MCP servers not available right now:"))
        #expect(!line.contains("docs"))
        #expect(!line.contains("\n"))
        #expect(MCPStatusReport([.init(name: "docs", phase: .connected, toolCount: 1)]).stateLine == nil)
        #expect(MCPStatusReport([]).stateLine == nil)
        // connecting 是短暂状态，不该在每条消息里吓唬模型。
        #expect(MCPStatusReport([.init(name: "later", phase: .connecting, toolCount: 0)]).stateLine == nil)
    }

    @Test
    func `给会话日志的中文诊断只报需要读者知道的状态`() {
        let report = MCPStatusReport([
            .init(name: "down", phase: .failed, reason: "连接被拒绝", toolCount: 0),
            .init(name: "auth", phase: .authorizationRequired, reason: nil, toolCount: 0),
            .init(name: "flaky", phase: .disconnected, reason: nil, toolCount: 0),
            .init(name: "docs", phase: .connected, toolCount: 1),
            .init(name: "later", phase: .connecting, toolCount: 0),
        ])
        let messages = report.diagnosticMessages
        #expect(messages.count == 3)
        #expect(messages[0].contains("连接失败（连接被拒绝）"))
        #expect(messages[1].contains("需要重新授权"))
        #expect(messages[2].contains("正在自动重连"))
    }

    @Test
    func `状态行渲染在 system-state 块内、闭合标签之前`() throws {
        let report = MCPStatusReport([.init(name: "down", phase: .failed, toolCount: 0)])
        let line = try #require(report.stateLine)
        var facts = SystemState.Facts(
            languages: ["en-US"], region: "US", date: Date(), timeZone: .gmt, mode: .confirm)
        facts.mcpNote = line
        let block = SystemState.make(facts)
        let lines = block.components(separatedBy: "\n")
        let note = lines.firstIndex { $0 == line }
        let close = lines.firstIndex { $0 == SystemState.closingTag }
        #expect(note != nil && close != nil && note! < close!, "状态行必须在闭合标签之前: \(block)")
        #expect(block.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(SystemState.closingTag))
    }
}
