import Foundation
import SQLite3
import Testing
@testable import ApelinCore

struct UsageLedgerTests {
    private func root() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("usage-ledger-\(UUID().uuidString)", isDirectory: true)
    }

    private func entry(_ index: Int, session: String = "s", account: String? = "a", model: String = "m") -> UsageRecord {
        UsageRecord(time: Date(timeIntervalSince1970: Double(index)), sessionID: session, project: "p", model: model,
                    provider: "openai", providerIdentity: account.map { UsageProviderIdentity(accountID: $0, endpointHost: "example.com") },
                    input: 10, output: 20, cacheRead: 3, cacheWrite: 4, requestID: "reply-\(index)")
    }

    private func execute(_ sql: String, root: URL) throws {
        var handle: OpaquePointer?
        #expect(sqlite3_open(UsageLedger.file(in: root).path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        #expect(sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK)
    }

    @Test func trimmingDetailsKeepsEveryTotalAndOldModel() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root, recentLimit: 2)
        try ledger.record(entry(1, session: "old", account: "old", model: "old"))
        for index in 2 ... 8 { try ledger.record(entry(index)) }
        let snapshot = try ledger.snapshot()
        #expect(snapshot.recent.count == 2)
        #expect(snapshot.recent.map(\.requestID) == ["reply-8", "reply-7"])
        #expect(snapshot.rollups.reduce(0) { $0 + $1.count } == 8)
        #expect(snapshot.rollups.reduce(0) { $0 + $1.record.promptTokens } == 136)
        #expect(snapshot.rollups.contains { $0.record.sessionID == "old" && $0.record.model == "old" })
        let providers = UsageProviderSummary.summarize(snapshot.rollups, unknown: "未知")
        #expect(providers.count == 2)
        #expect(providers.reduce(0) { $0 + $1.count } == 8)
        #expect(providers.reduce(0) { $0 + $1.input } == 80)
        let withCache = UsageProviderSummary.summarize(snapshot.rollups, unknown: "未知", includingCache: true)
        #expect(withCache.reduce(0) { $0 + $1.input } == 136)
    }

    @Test func repeatedReplyStaysDeduplicatedAfterItsDetailWasPruned() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root, recentLimit: 1)
        try ledger.record(entry(1))
        try ledger.record(entry(2))
        var retry = entry(1)
        retry.input = 999
        try ledger.record(retry)
        let snapshot = try UsageLedger(dataRoot: root, recentLimit: 1).snapshot()
        #expect(snapshot.rollups.reduce(0) { $0 + $1.count } == 2)
        #expect(snapshot.rollups.reduce(0) { $0 + $1.record.input } == 20)
        #expect(snapshot.recent.count == 1)
    }

    @Test func identityAndSessionAreNeverBorrowed() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root)
        try ledger.record(entry(1, session: "one", account: "a"))
        try ledger.record(entry(1, session: "two", account: "a"))
        try ledger.record(entry(2, session: "one", account: "b"))
        try ledger.record(entry(3, session: "one", account: nil))
        let snapshot = try ledger.snapshot()
        #expect(snapshot.rollups.count == 4)
        #expect(snapshot.rollups.filter { $0.record.sessionID == "one" }.reduce(0) { $0 + $1.count } == 3)
        #expect(UsageProviderSummary.summarize(snapshot.rollups, unknown: "未知").count == 3)
    }

    @Test func oldLinesImportOnceAndOriginalBytesStayUntouched() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = UsageRecorder.file(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var record = entry(1, account: nil)
        record.requestID = nil
        record.provider = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line = String(decoding: try encoder.encode(record), as: UTF8.self)
        let original = Data((line + "\n坏行\n" + line + "\n").utf8)
        try original.write(to: url)
        let ledger = UsageLedger(dataRoot: root, recentLimit: 1)
        let first = try ledger.snapshot()
        #expect(first.rollups.reduce(0) { $0 + $1.count } == 2)
        #expect(first.unreadableLegacyLines == 1)
        #expect(first.rollups.allSatisfy { $0.record.provider == nil && $0.record.providerIdentity == nil })
        let second = try UsageLedger(dataRoot: root).snapshot()
        #expect(second.rollups == first.rollups)
        #expect(try Data(contentsOf: url) == original)
        try ledger.clear()
        #expect(try ledger.snapshot().rollups.isEmpty)
        #expect(try ledger.snapshot().recent.isEmpty)
        #expect(try Data(contentsOf: url) == original)
        try ledger.record(entry(10))
        #expect(try ledger.snapshot().rollups.reduce(0) { $0 + $1.count } == 1)
    }

    @Test func malformedLegacyFileIsNotReplacedOrMarkedImported() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = UsageRecorder.file(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0xFF, 0xFE])
        try bytes.write(to: url)
        #expect(throws: (any Error).self) { try UsageLedger(dataRoot: root).snapshot() }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func failedTransactionKeepsPendingAndRollsBackReceipt() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root)
        _ = try ledger.snapshot()
        try execute("CREATE TRIGGER reject_totals BEFORE INSERT ON totals BEGIN SELECT RAISE(ABORT,'test'); END", root: root)
        #expect(throws: (any Error).self) { try ledger.record(entry(1)) }
        let pending = root.appendingPathComponent("usage/pending")
        #expect(try FileManager.default.contentsOfDirectory(atPath: pending.path).count == 1)
        try execute("DROP TRIGGER reject_totals", root: root)
        let recovered = try ledger.snapshot()
        #expect(recovered.rollups.reduce(0) { $0 + $1.count } == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: pending.path).isEmpty)
        try ledger.record(entry(1))
        #expect(try ledger.snapshot().rollups.reduce(0) { $0 + $1.count } == 1)
    }

    @Test func pendingReplayAfterCommittedTransactionDoesNotCountTwice() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root)
        try ledger.record(entry(1))
        var receipt = ""
        var payload = ""
        var handle: OpaquePointer?
        #expect(sqlite3_open(UsageLedger.file(in: root).path, &handle) == SQLITE_OK)
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(handle, "SELECT receipt,payload FROM details", -1, &statement, nil) == SQLITE_OK)
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        receipt = String(cString: sqlite3_column_text(statement, 0))
        payload = String(cString: sqlite3_column_text(statement, 1))
        sqlite3_finalize(statement)
        sqlite3_close(handle)
        let pending = root.appendingPathComponent("usage/pending/\(receipt).json")
        try Data(payload.utf8).write(to: pending)
        #expect(try ledger.snapshot().rollups.reduce(0) { $0 + $1.count } == 1)
        #expect(!FileManager.default.fileExists(atPath: pending.path))
        // 清空后旧回复重放不能使统计复活；不同新请求仍正常入账。
        try ledger.clear()
        try ledger.record(entry(1))
        #expect(try ledger.snapshot().rollups.isEmpty)
        try ledger.record(entry(2))
        #expect(try ledger.snapshot().rollups.reduce(0) { $0 + $1.count } == 1)
    }

    @Test func concurrentWritersDoNotLoseOrDuplicateUsage() async throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root, recentLimit: 3)
        let records = (0 ..< 40).map { entry($0) }
        try await withThrowingTaskGroup(of: Void.self) { group in
            for record in records + records {
                group.addTask { try ledger.record(record) }
            }
            try await group.waitForAll()
        }
        let snapshot = try ledger.snapshot()
        #expect(snapshot.recent.count == 3)
        #expect(snapshot.rollups.reduce(0) { $0 + $1.count } == 40)
        #expect(snapshot.rollups.reduce(0) { $0 + $1.record.input } == 400)
    }

    @Test func noDetailsStillRetainsDailyTotalsAcrossReopen() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root, recentLimit: 0)
        try ledger.record(entry(1))
        try ledger.record(entry(86401))
        let snapshot = try UsageLedger(dataRoot: root, recentLimit: 0).snapshot()
        #expect(snapshot.recent.isEmpty)
        #expect(snapshot.rollups.count == 2)
        #expect(snapshot.rollups.reduce(0) { $0 + $1.count } == 2)
    }

    @Test func unreadableDatabaseIsNeverReplacedWithEmptyStatistics() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = UsageLedger.file(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let original = Data("不是数据库".utf8)
        try original.write(to: url)
        #expect(throws: (any Error).self) { try UsageLedger(dataRoot: root).record(entry(1)) }
        #expect(throws: (any Error).self) { try UsageLedger(dataRoot: root).snapshot() }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("usage/pending").path).count == 1)
    }

    @Test func clearIsNotBlockedBySingleColumnOverflowInPending() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root)
        var massive = entry(1)
        massive.input = Int.max / 8
        massive.output = 0
        massive.cacheRead = 0
        massive.cacheWrite = 0
        for index in 1 ... 8 {
            massive.requestID = "massive-\(index)"
            try ledger.record(massive)
        }
        massive.requestID = "massive-9"
        #expect(throws: (any Error).self) { try ledger.record(massive) }
        // 清空不能先恢复第九条：它在SQL层失败，早于全局预算检查。
        try ledger.clear()
        #expect(try ledger.snapshot().rollups.isEmpty)
        try ledger.record(entry(100))
        #expect(try ledger.snapshot().rollups.reduce(0) { $0 + $1.count } == 1)
    }

    @Test func explicitClearCanSkipUnreadableLegacyWithoutReimportingIt() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = UsageRecorder.file(in: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data([0xFF, 0xFE])
        try bytes.write(to: url)
        let ledger = UsageLedger(dataRoot: root)
        try ledger.clear()
        let snapshot = try ledger.snapshot()
        #expect(snapshot.rollups.isEmpty)
        #expect(snapshot.unreadableLegacyLines == 0)
        #expect(try Data(contentsOf: url) == bytes)
    }

    private func failedPending(root: URL, ledger: UsageLedger) throws -> (file: URL, data: Data) {
        _ = try ledger.snapshot()
        try execute("CREATE TRIGGER reject_pending BEFORE INSERT ON totals BEGIN SELECT RAISE(ABORT,'test'); END", root: root)
        #expect(throws: (any Error).self) { try ledger.record(entry(1)) }
        try execute("DROP TRIGGER reject_pending", root: root)
        let pending = root.appendingPathComponent("usage/pending")
        let files = try FileManager.default.contentsOfDirectory(at: pending, includingPropertiesForKeys: nil)
        let file = try #require(files.first)
        return (file, try Data(contentsOf: file))
    }

    @Test func unreadableSameKeyPendingDoesNotPretendTheRequestWasRecorded() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root)
        let pending = try failedPending(root: root, ledger: ledger)
        let bad = Data("损坏".utf8)
        try bad.write(to: pending.file)
        #expect(throws: (any Error).self) { try ledger.record(entry(1)) }
        #expect(try Data(contentsOf: pending.file) == bad)
        #expect(try ledger.snapshot().rollups.isEmpty)
        try pending.data.write(to: pending.file)
        #expect(try ledger.snapshot().rollups.reduce(0) { $0 + $1.count } == 1)
    }

    @Test func clearTombstonesEvenUnreadablePending() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root)
        let pending = try failedPending(root: root, ledger: ledger)
        try Data("暂时无法解码".utf8).write(to: pending.file)
        try ledger.clear()
        try pending.data.write(to: pending.file)
        #expect(try ledger.snapshot().rollups.isEmpty)
        #expect(try ledger.snapshot().recent.isEmpty)
        try ledger.record(entry(2))
        #expect(try ledger.snapshot().rollups.reduce(0) { $0 + $1.count } == 1)
    }

    @Test func combinedTokenOverflowRollsBackEvenWhenEverySQLColumnFits() throws {
        let root = root()
        defer { try? FileManager.default.removeItem(at: root) }
        let ledger = UsageLedger(dataRoot: root)
        var massive = entry(1)
        massive.input = Int.max / 8
        massive.output = Int.max / 8
        massive.cacheRead = Int.max / 8
        massive.cacheWrite = Int.max / 8
        try ledger.record(massive)
        massive.requestID = "second"
        try ledger.record(massive)
        massive.requestID = "third"
        #expect(throws: (any Error).self) { try ledger.record(massive) }
        var db: OpaquePointer?
        #expect(sqlite3_open(UsageLedger.file(in: root).path, &db) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        #expect(sqlite3_prepare_v2(db, "SELECT SUM(requests) FROM totals", -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        #expect(sqlite3_step(statement) == SQLITE_ROW)
        #expect(sqlite3_column_int64(statement, 0) == 2)
        // 超界待入账不会让清空按钮失效：清空跳过恢复，只留墓碑后再验空值。
        try ledger.clear()
        #expect(try ledger.snapshot().rollups.isEmpty)
    }

    @Test func stableIDScopesReplyToItsSessionAndIsOrderIndependent() throws {
        let one = ["text": "相同内容", "time": "100"]
        let two = ["time": "100", "text": "相同内容"]
        let id = try UsageLedger.requestID(sessionID: "a", message: one)
        #expect(id == (try UsageLedger.requestID(sessionID: "a", message: two)))
        #expect(id != (try UsageLedger.requestID(sessionID: "b", message: one)))
        #expect(id != (try UsageLedger.requestID(sessionID: "a", message: ["text": "相同内容", "time": "101"])))
        #expect(!id.contains("相同内容"))
    }
}
