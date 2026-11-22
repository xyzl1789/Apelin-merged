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

    func testImportPreviewAcceptsHTTPAndListsUnsupportedTransports() throws {
        let store = MCPServerStore(root: URL(fileURLWithPath: "/unused"))
        let preview = try store.parseImport("""
        {
          "mcpServers": {
            "docs": {
              "type": "http",
              "url": "https://example.com/mcp",
              "headers": {"Authorization": "Bearer secret"},
              "description": "文档工具"
            },
            "local": {"command": "npx", "args": ["-y", "server"]}
          }
        }
        """)
        XCTAssertEqual(preview.servers.count, 1)
        XCTAssertEqual(preview.servers[0].connection.name, "docs")
        XCTAssertEqual(preview.servers[0].connection.headers["Authorization"], "Bearer secret")
        XCTAssertEqual(preview.servers[0].connection.note, "文档工具")
        XCTAssertEqual(preview.unsupported.count, 1)
        XCTAssertTrue(preview.unsupported[0].contains("local"))
    }

    func testImportPreviewReportsOAuthAndEnvironmentReferencesAsUnsupported() throws {
        let store = MCPServerStore(root: URL(fileURLWithPath: "/unused"))
        let preview = try store.parseImport("""
        {
          "mcpServers": {
            "oauth": {"type": "http", "url": "https://example.com/mcp", "oauth": {"clientId": "client"}},
            "templated": {"type": "http", "url": "https://example.com/$$MCP_PATH", "headers": {"Authorization": "Bearer $$TOKEN"}}
          }
        }
        """)
        XCTAssertTrue(preview.servers.isEmpty)
        XCTAssertEqual(preview.unsupported.count, 2)
        XCTAssertTrue(preview.unsupported.joined(separator: " ").contains("oauth"))
        XCTAssertTrue(preview.unsupported.joined(separator: " ").contains("环境变量"))
    }

    func testImportPreviewKeepsValidEntriesWhenOneHTTPEntryIsInvalid() throws {
        let store = MCPServerStore(root: URL(fileURLWithPath: "/unused"))
        let preview = try store.parseImport("""
        {
          "mcpServers": {
            "docs": {"type": "http", "url": "https://example.com/mcp"},
            "bad-url": {"type": "http", "url": "file:///tmp/server"},
            "bad-header": {"type": "http", "url": "https://example.com/mcp", "headers": {"X-Test": 7}}
          }
        }
        """)
        XCTAssertEqual(preview.servers.map(\.connection.name), ["docs"])
        XCTAssertEqual(preview.unsupported.count, 2)
    }

    func testImportMergeAndExportRoundTrip() throws {
        let store = MCPServerStore(root: URL(fileURLWithPath: "/unused"))
        let old = MCPServerRecord(
            id: "stable-id",
            connection: try MCPConnection(name: "docs", url: "https://old.example/mcp"),
            enabled: false,
        )
        let original = MCPServerSnapshot(servers: [old])
        let preview = try store.parseImport("""
        {"mcpServers":{"docs":{"type":"streamable-http","url":"https://new.example/mcp","headers":{"X-Api-Key":"secret"},"enabled":true}}}
        """)
        let merged = try store.merging(preview, into: original)
        XCTAssertEqual(merged.servers.items.count, 1)
        XCTAssertEqual(merged.servers.items[0].id, "stable-id")
        XCTAssertTrue(merged.servers.items[0].enabled)
        XCTAssertEqual(merged.servers.items[0].connection.url, "https://new.example/mcp")

        let text = try store.exportJSON(merged.servers.items)
        let roundTrip = try store.parseImport(text)
        XCTAssertEqual(roundTrip.servers.items.map(\.connection), merged.servers.items.map(\.connection))
        XCTAssertTrue(roundTrip.unsupported.isEmpty)
    }

    func testRejectsInvalidImportEnvelope() {
        let store = MCPServerStore(root: URL(fileURLWithPath: "/unused"))
        XCTAssertThrowsError(try store.parseImport(#"{"servers":{}}"#))
        XCTAssertThrowsError(try store.parseImport("not json"))
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
