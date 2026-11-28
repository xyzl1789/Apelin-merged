import CryptoKit
import Darwin
import Foundation
import SQLite3

/// 系统 SQLite 账本：累计按日/会话/模型/账号存储，明细单独限量。
/// 所有入口共用跨进程锁；迁移、待入账恢复、累计和明细在一个事务内提交。
public struct UsageLedger: Sendable {
    public let dataRoot: URL
    public let recentLimit: Int

    public init(dataRoot: URL, recentLimit: Int = 5000) {
        self.dataRoot = dataRoot
        self.recentLimit = max(0, recentLimit)
    }

    public static func file(in dataRoot: URL) -> URL {
        dataRoot.appendingPathComponent("usage", isDirectory: true).appendingPathComponent("usage.sqlite")
    }

    private var directory: URL { Self.file(in: dataRoot).deletingLastPathComponent() }
    private var pendingDirectory: URL { directory.appendingPathComponent("pending", isDirectory: true) }

    /// 消息正文只在内存中编码求摘要，不进入数据库、待入账文件或日志。
    public static func requestID<Message: Encodable>(sessionID: String, message: Message) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let messageData = try encoder.encode(message)
        return digest(Data(sessionID.utf8) + Data([0]) + messageData)
    }

    /// 先原子保存待入账记录。数据库锁定、损坏或磁盘故障时不伪造成功，下次入口会重试。
    public func record(_ entry: UsageRecord) throws {
        try validate(entry)
        try locked {
            try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true)
            let key = try receiptID(entry)
            let pending = pendingDirectory.appendingPathComponent(key + ".json")
            // 同一标识的首次内容获胜；重放不得覆盖已经持久化的原始用量。
            if !FileManager.default.fileExists(atPath: pending.path) {
                try Self.encoder().encode(entry).write(to: pending, options: .atomic)
            }
            try transaction { db in
                var recorded = false
                try db.rows("SELECT receipt FROM receipts WHERE receipt=?", [.text(key)]) { _ in recorded = true }
                guard recorded else { throw LedgerError.pending }
            }
        }
    }

    public func snapshot() throws -> UsageSnapshot {
        try locked {
            try transaction { db in
                var rollups: [UsageRollup] = []
                try db.rows("SELECT latest,session,project,model,provider,account,host,requests,input,output,cache_read,cache_write FROM totals ORDER BY day,group_key") { statement in
                    let identity = db.text(statement, 5).map {
                        UsageProviderIdentity(accountID: $0, endpointHost: db.text(statement, 6))
                    }
                    let record = UsageRecord(
                        time: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                        sessionID: db.text(statement, 1)!, project: db.text(statement, 2)!,
                        model: db.text(statement, 3)!, provider: db.text(statement, 4), providerIdentity: identity,
                        input: Int(sqlite3_column_int64(statement, 8)), output: Int(sqlite3_column_int64(statement, 9)),
                        cacheRead: Int(sqlite3_column_int64(statement, 10)), cacheWrite: Int(sqlite3_column_int64(statement, 11)),
                        requestID: nil,
                    )
                    rollups.append(UsageRollup(record: record, count: Int(sqlite3_column_int64(statement, 7))))
                }
                var recent: [UsageRecord] = []
                try db.rows("SELECT payload FROM details ORDER BY time DESC,receipt DESC LIMIT ?", [.integer(recentLimit)]) { statement in
                    guard let payload = db.text(statement, 0)?.data(using: .utf8) else { throw LedgerError.invalidData }
                    // 明细不重新写回；坏行留在数据库，单条损坏不抹掉累计或其他明细。
                    if let record = try? Self.decoder().decode(UsageRecord.self, from: payload) {
                        recent.append(record)
                    }
                }
                var invalid = 0
                try db.rows("SELECT value FROM metadata WHERE key='legacy_bad_lines'") { statement in
                    invalid = Int(db.text(statement, 0) ?? "0") ?? 0
                }
                return UsageSnapshot(rollups: rollups, recent: recent, unreadableLegacyLines: invalid)
            }
        }
    }

    /// 保留迁移标记及去重收据，避免旧文件、待入账重试在清空后重新算进来。
    /// 收据只有不可逆摘要，不保存 token、账号、会话正文或其他统计字段。
    public func clear() throws {
        try locked {
            try transaction(drainingPending: false) { db in
                // 清空前暂时不可读的文件也要留收据，日后恢复可读时不得复活。
                if FileManager.default.fileExists(atPath: pendingDirectory.path) {
                    let files = try FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: nil)
                    for file in files where file.pathExtension == "json" {
                        let key = file.deletingPathExtension().lastPathComponent
                        guard key.utf8.count == 64, key.utf8.allSatisfy({ (48 ... 57).contains($0) || (97 ... 102).contains($0) }) else { continue }
                        try db.run("INSERT OR IGNORE INTO receipts(receipt) VALUES(?)", [.text(key)])
                    }
                }
                try db.run("DELETE FROM totals")
                try db.run("DELETE FROM details")
                try db.run("UPDATE metadata SET value='0' WHERE key='legacy_bad_lines'")
            }
        }
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lock = directory.appendingPathComponent("usage.lock")
        let fd = lock.path.withCString { Darwin.open($0, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0o600) }
        guard fd >= 0 else { throw LedgerError.lock }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw LedgerError.lock }
        defer { _ = flock(fd, LOCK_UN) }
        return try operation()
    }

    /// 文件锁覆盖整个事务和待入账文件清理，多个 agent/App 同时访问不会相互覆盖。
    private func transaction<T>(drainingPending: Bool = true, _ operation: (Database) throws -> T) throws -> T {
        let db = try Database(url: Self.file(in: dataRoot))
        try db.run("BEGIN IMMEDIATE")
        var committed = false
        defer { if !committed { try? db.run("ROLLBACK") } }
        try createSchema(db)
        var pending: [URL] = []
        if drainingPending {
            try migrateLegacy(db)
            pending = try drainPending(db)
        } else {
            // 显式清空也跳过旧文件导入；坏旧行或超界旧数据不能阻塞重置。
            try db.run("INSERT OR IGNORE INTO metadata(key,value) VALUES('legacy_imported','1')")
            try db.run("INSERT OR IGNORE INTO metadata(key,value) VALUES('legacy_bad_lines','0')")
        }
        try db.run("DELETE FROM details WHERE receipt NOT IN (SELECT receipt FROM details ORDER BY time DESC,receipt DESC LIMIT ?)", [.integer(recentLimit)])
        let result = try operation(db)
        try validateBudget(db)
        try db.run("COMMIT")
        committed = true
        // 事务已提交，即使删除失败或在这里中断，下次也由收据去重。
        for file in pending { try? FileManager.default.removeItem(at: file) }
        return result
    }

    /// 不只限制单列：所有维度的四类 token 合计也必须可被 Int 精确表示。
    /// SQLite SUM 检查每列跨行溢出，受检加法再检查各列合并，任何异常整次回滚。
    private func validateBudget(_ db: Database) throws {
        try db.rows("SELECT COALESCE(SUM(requests),0),COALESCE(SUM(input),0),COALESCE(SUM(output),0),COALESCE(SUM(cache_read),0),COALESCE(SUM(cache_write),0) FROM totals") { statement in
            guard sqlite3_column_int64(statement, 0) >= 0 else { throw LedgerError.capacity }
            var total = 0
            for index in Int32(1) ... Int32(4) {
                let value = Int(sqlite3_column_int64(statement, index))
                let next = total.addingReportingOverflow(value)
                guard value >= 0, !next.overflow else { throw LedgerError.capacity }
                total = next.partialValue
            }
        }
    }

    private func createSchema(_ db: Database) throws {
        var version = 0
        try db.rows("PRAGMA user_version") { version = Int(sqlite3_column_int64($0, 0)) }
        guard version == 0 || version == 1 else { throw LedgerError.schema }
        try db.run("CREATE TABLE IF NOT EXISTS metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        try db.run("CREATE TABLE IF NOT EXISTS receipts(receipt TEXT PRIMARY KEY)")
        try db.run("""
        CREATE TABLE IF NOT EXISTS totals(
            group_key TEXT PRIMARY KEY,day INTEGER NOT NULL,session TEXT NOT NULL,project TEXT NOT NULL,
            model TEXT NOT NULL,provider TEXT,account TEXT,host TEXT,latest REAL NOT NULL,
            requests INTEGER NOT NULL,input INTEGER NOT NULL,output INTEGER NOT NULL,
            cache_read INTEGER NOT NULL,cache_write INTEGER NOT NULL,
            CHECK(typeof(requests)='integer' AND typeof(input)='integer' AND typeof(output)='integer'
                AND typeof(cache_read)='integer' AND typeof(cache_write)='integer'))
        """)
        try db.run("CREATE INDEX IF NOT EXISTS totals_session ON totals(session)")
        try db.run("CREATE INDEX IF NOT EXISTS totals_day ON totals(day)")
        try db.run("CREATE TABLE IF NOT EXISTS details(receipt TEXT PRIMARY KEY,time REAL NOT NULL,payload TEXT NOT NULL)")
        try db.run("CREATE INDEX IF NOT EXISTS details_time ON details(time DESC,receipt DESC)")
        try db.run("PRAGMA user_version=1")
    }

    private func migrateLegacy(_ db: Database) throws {
        var done = false
        try db.rows("SELECT value FROM metadata WHERE key='legacy_imported'") { _ in done = true }
        guard !done else { return }
        let url = UsageRecorder.file(in: dataRoot)
        var bad = 0
        if FileManager.default.fileExists(atPath: url.path) {
            // 原文件完整保留：读失败/非UTF8不标迁移成功，不改写或删除旧统计。
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { throw LedgerError.invalidData }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var occurrences: [String: Int] = [:]
            for line in text.split(separator: "\n") {
                let payload = Data(line.utf8)
                guard let record = try? decoder.decode(UsageRecord.self, from: payload),
                      (try? validate(record)) != nil else {
                    bad += 1
                    continue
                }
                let hash = Self.digest(payload)
                let occurrence = occurrences[hash, default: 0]
                occurrences[hash] = occurrence + 1
                // 无ID的旧行不能简单按内容去重：两条相同旧行也是两次已记录请求。
                let key = record.requestID == nil ? "legacy-\(hash)-\(occurrence)" : try receiptID(record)
                try insert(record, receipt: key, db: db)
            }
        }
        try db.run("INSERT INTO metadata(key,value) VALUES('legacy_bad_lines',?)", [.text(String(bad))])
        try db.run("INSERT INTO metadata(key,value) VALUES('legacy_imported','1')")
    }

    private func drainPending(_ db: Database) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: pendingDirectory.path) else { return [] }
        let files = try FileManager.default.contentsOfDirectory(at: pendingDirectory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        var completed: [URL] = []
        for file in files where file.pathExtension == "json" {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // 某条坏记录留原位供排查，不阻止其他请求恢复。数据库错误仍传播并回滚。
            let entry: UsageRecord
            do {
                entry = try Self.decoder().decode(UsageRecord.self, from: Data(contentsOf: file))
                try validate(entry)
            } catch { continue }
            let key = try receiptID(entry)
            guard file.deletingPathExtension().lastPathComponent == key else { continue }
            try insert(entry, receipt: key, db: db)
            completed.append(file)
        }
        return completed
    }

    private func insert(_ record: UsageRecord, receipt: String, db: Database) throws {
        try db.run("INSERT OR IGNORE INTO receipts(receipt) VALUES(?)", [.text(receipt)])
        guard db.changes > 0 else { return }
        let day = Int(floor(record.time.timeIntervalSince1970 / 86400))
        let dimensions: [String?] = [String(day), record.sessionID, record.project, record.model, record.provider,
                                     record.providerIdentity?.accountID, record.providerIdentity?.endpointHost]
        let group = Self.digest(try Self.encoder().encode(dimensions))
        let values: [Value] = [.text(group), .integer(day), .text(record.sessionID), .text(record.project), .text(record.model),
                               Value(record.provider), Value(record.providerIdentity?.accountID), Value(record.providerIdentity?.endpointHost),
                               .real(record.time.timeIntervalSince1970), .integer(record.input), .integer(record.output),
                               .integer(record.cacheRead), .integer(record.cacheWrite)]
        try db.run("""
        INSERT INTO totals(group_key,day,session,project,model,provider,account,host,latest,requests,input,output,cache_read,cache_write)
        VALUES(?,?,?,?,?,?,?,?,?,1,?,?,?,?) ON CONFLICT(group_key) DO UPDATE SET
        latest=MAX(latest,excluded.latest),requests=requests+1,input=input+excluded.input,
        output=output+excluded.output,cache_read=cache_read+excluded.cache_read,cache_write=cache_write+excluded.cache_write
        """, values)
        let payload = String(decoding: try Self.encoder().encode(record), as: UTF8.self)
        try db.run("INSERT INTO details(receipt,time,payload) VALUES(?,?,?)", [.text(receipt), .real(record.time.timeIntervalSince1970), .text(payload)])
    }

    private func validate(_ record: UsageRecord) throws {
        let time = record.time.timeIntervalSince1970
        guard time.isFinite, abs(time) < 1e12,
              [record.input, record.output, record.cacheRead, record.cacheWrite].allSatisfy({ $0 >= 0 && $0 <= Int.max / 8 }) else {
            throw LedgerError.invalidData
        }
    }

    private func receiptID(_ entry: UsageRecord) throws -> String {
        if let id = entry.requestID {
            return Self.digest(try Self.encoder().encode([entry.sessionID, id]))
        }
        return Self.digest(try Self.encoder().encode(entry))
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private enum LedgerError: LocalizedError {
        case lock, schema, invalidData, pending, capacity, sqlite(Int32)

        var errorDescription: String? {
            switch self {
            case .lock: "无法锁定用量账本，请稍后重试。"
            case .pending: "待入账用量暂时无法读取，原记录已保留，尚未计入累计。"
            case .capacity: "用量累计超出可精确表示的整数范围，已保留原数据且未提交本次写入。"
            case .schema: "用量账本来自较新版本，已保留原数据。"
            case .invalidData: "用量记录无法读取，原数据已保留。"
            case let .sqlite(code): "用量账本暂不可用（\(code)），原数据已保留。"
            }
        }
    }

    private enum Value {
        case text(String), integer(Int), real(Double), null
        init(_ value: String?) { self = value.map(Self.text) ?? .null }
    }

    private final class Database {
        private var handle: OpaquePointer?
        var changes: Int32 { sqlite3_changes(handle) }

        init(url: URL) throws {
            let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
            guard status == SQLITE_OK else {
                sqlite3_close(handle)
                handle = nil
                throw LedgerError.sqlite(status)
            }
            do {
                guard sqlite3_busy_timeout(handle, 5000) == SQLITE_OK else { throw LedgerError.lock }
                try run("PRAGMA journal_mode=WAL")
                try run("PRAGMA synchronous=FULL")
            } catch {
                sqlite3_close(handle)
                handle = nil
                throw error
            }
        }

        deinit { sqlite3_close(handle) }

        func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
            guard let bytes = sqlite3_column_text(statement, index) else { return nil }
            let count = Int(sqlite3_column_bytes(statement, index))
            return String(decoding: UnsafeBufferPointer(start: bytes, count: count), as: UTF8.self)
        }

        func run(_ sql: String, _ values: [Value] = []) throws {
            try rows(sql, values) { _ in }
        }

        func rows(_ sql: String, _ values: [Value] = [], _ visit: (OpaquePointer) throws -> Void) throws {
            var statement: OpaquePointer?
            let prepared = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
            guard prepared == SQLITE_OK, let statement else { throw LedgerError.sqlite(prepared) }
            defer { sqlite3_finalize(statement) }
            for (index, value) in values.enumerated() {
                let slot = Int32(index + 1)
                let result: Int32
                switch value {
                case let .text(value):
                    // SQLite复制UTF8字节；显式长度允许名称含NUL而不截断，分组键仍可区分。
                    result = value.withCString { sqlite3_bind_text(statement, slot, $0, Int32(value.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
                case let .integer(value): result = sqlite3_bind_int64(statement, slot, Int64(value))
                case let .real(value): result = sqlite3_bind_double(statement, slot, value)
                case .null: result = sqlite3_bind_null(statement, slot)
                }
                guard result == SQLITE_OK else { throw LedgerError.sqlite(result) }
            }
            while true {
                let result = sqlite3_step(statement)
                if result == SQLITE_DONE { return }
                guard result == SQLITE_ROW else { throw LedgerError.sqlite(result) }
                try visit(statement)
            }
        }
    }
}
