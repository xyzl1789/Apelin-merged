import ApelinCore
import Foundation
import XCTest

final class ProjectInstructionsFileTests: XCTestCase {
    func testPrefersAgentsAndFallsBackWhenItIsBlank() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertNil(ProjectInstructionsFile.read(projectRoot: root.path))
        try "备用说明".write(to: root.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectInstructionsFile.read(projectRoot: root.path)?.file, "CLAUDE.md")
        try "  项目说明\n".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let reading = try XCTUnwrap(ProjectInstructionsFile.read(projectRoot: root.path))
        XCTAssertEqual(reading.file, "AGENTS.md")
        XCTAssertEqual(reading.text, "项目说明")
        try " \n\t".write(to: root.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectInstructionsFile.read(projectRoot: root.path)?.text, "备用说明")
    }

    func testRejectsLinksOutsideProjectEvenWithSharedPathPrefix() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        let sibling = root.appendingPathComponent("project-other", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        let outside = sibling.appendingPathComponent("outside.md")
        try "项目外内容".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("AGENTS.md"), withDestinationURL: outside)
        XCTAssertNil(ProjectInstructionsFile.read(projectRoot: project.path))
        try "安全备用内容".write(to: project.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectInstructionsFile.read(projectRoot: project.path)?.text, "安全备用内容")
        XCTAssertNil(ProjectInstructionsFile.read(projectRoot: project.path + "\0suffix"))
    }

    func testAcceptsCanonicalRootAliasAndLinksInsideProject() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let target = project.appendingPathComponent("notes.md")
        try "内部说明".write(to: target, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("AGENTS.md"), withDestinationURL: target)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: project)
        XCTAssertEqual(ProjectInstructionsFile.read(projectRoot: alias.path)?.text, "内部说明")
    }

    func testSkipsDirectoriesAndLeavesFilesUntouched() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("AGENTS.md"), withIntermediateDirectories: false)
        let file = root.appendingPathComponent("CLAUDE.md")
        try "  保留原始空白\n".write(to: file, atomically: true, encoding: .utf8)
        let before = try Data(contentsOf: file)
        XCTAssertEqual(ProjectInstructionsFile.read(projectRoot: root.path)?.text, "保留原始空白")
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)), ["AGENTS.md", "CLAUDE.md"])
    }

    func testKeepsExistingByteLimitAndTruncationMarker() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("AGENTS.md")
        let limit = ProjectInstructionsFile.maximumBytes
        XCTAssertEqual(limit, 16 * 1024)
        let body = String(repeating: "x", count: limit)
        try body.write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectInstructionsFile.read(projectRoot: root.path)?.text, body)
        try (body + "y").write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(ProjectInstructionsFile.read(projectRoot: root.path)?.text, body + ProjectInstructionsFile.truncationNote)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), body + "y")
    }
}
