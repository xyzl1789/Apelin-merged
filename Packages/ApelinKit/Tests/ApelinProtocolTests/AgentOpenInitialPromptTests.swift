import ApelinProtocol
import XCTest

final class AgentOpenInitialPromptTests: XCTestCase {
    func testFirstPromptKeepsItsMessageIDAndRunModeAcrossTheWire() throws {
        let id = UUID()
        let request = AgentOpenRequest(
            projectName: "Example",
            approvalMode: .relaxed,
            prompt: "Start the task",
            runMode: .plan,
            messageID: id,
        )

        let encoded = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(AgentOpenRequest.self, from: encoded)

        XCTAssertEqual(decoded.prompt, "Start the task")
        XCTAssertEqual(decoded.runMode, .plan)
        XCTAssertEqual(decoded.messageID, id)
    }
}
