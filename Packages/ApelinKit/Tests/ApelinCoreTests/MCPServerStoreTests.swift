import ApelinCore
import Darwin
import Foundation
import XCTest

final class MCPServerStoreTests: XCTestCase {
    func testStoresEnabledConnectionsAndPermissions() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPServerStore(root: root)
        let connection = try MCPConnection(
            name: "docs",
            url: "https://example.com/mcp",
            headers: ["Authorization": "Bearer secret"],
            note: "文档"
        )
        let saved = try store.save(MCPServerSnapshot(servers: [
            MCPServerRecord(connection: connection),
            MCPServerRecord(connection: try MCPConnection(name: "off", url: "http://127.0.0.1:8080/mcp"), enabled: false),
        ]))
        XCTAssertEqual(saved.servers.items.count, 2)

        let read = try store.read()
        XCTAssertEqual(read.servers.items, saved.servers.items)
        XCTAssertEqual(try store.enabledConnections(), [connection])

        var info = stat()
        XCTAssertEqual(lstat(store.file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o077, 0)
        var directoryInfo = stat()
        XCTAssertEqual(lstat(store.file.deletingLastPathComponent().path, &directoryInfo), 0)
        XCTAssertEqual(directoryInfo.st_mode & 0o077, 0)
    }

    func testRejectsInvalidConnections() {
        XCTAssertThrowsError(try MCPConnection(name: "bad name", url: "https://example.com"))
        XCTAssertThrowsError(try MCPConnection(name: "ok", url: "ftp://example.com"))
        XCTAssertThrowsError(try MCPConnection(name: "ok", url: "https://example.com", headers: ["X": "a\nb"]))
    }

    func testUnreadableRecordDoesNotEraseTheOthers() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPServerStore(root: root)
        let directory = store.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let json = """
        [
          {"id":"good","connection":{"name":"docs","url":"https://example.com/mcp","headers":{}},"enabled":true},
          {"id":"bad","connection":{"name":"oops","url":"not a url","headers":{}}}
        ]
        """
        try json.write(to: store.file, atomically: true, encoding: .utf8)
        let read = try store.read()
        XCTAssertEqual(read.servers.items.count, 1)
        XCTAssertEqual(read.servers.items.first?.id, "good")
        XCTAssertEqual(read.servers.unreadable.count, 1)
        let rewritten = try store.save(read)
        XCTAssertEqual(rewritten.servers.unreadable.count, 1)
        XCTAssertEqual(try String(contentsOf: store.file, encoding: .utf8).contains("bad"), true)
    }

    func testBadFileIsSetAsideNotSilentlyReplaced() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MCPServerStore(root: root)
        let directory = store.file.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "not json".write(to: store.file, atomically: true, encoding: .utf8)
        let read = try store.read()
        XCTAssertTrue(read.servers.items.isEmpty)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("servers.json.unreadable-") })
    }
}
