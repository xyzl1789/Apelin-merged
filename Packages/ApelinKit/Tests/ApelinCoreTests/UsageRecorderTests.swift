import Foundation
import Testing
@testable import ApelinCore

struct UsageRecorderTests {
    /// 空数据根上首次 record() 也要能落盘：usage.jsonl 不存在时先建再追加。
    /// 曾因 FileHandle(forWritingTo:) 要求文件已存在而永远写不进第一条。
    @Test func firstRecordCreatesFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = UsageRecorder(dataRoot: root)
        let record = UsageRecord(
            time: Date(timeIntervalSince1970: 1_000),
            sessionID: "s1",
            project: "p",
            model: "m",
            input: 10,
            output: 20,
            cacheRead: 0,
            cacheWrite: 0,
        )
        recorder.record(record)
        let read = UsageRecorder.readAll(from: UsageRecorder.file(in: root))
        #expect(read == [record])
    }

    /// 已有记录的文件继续追加，不覆盖旧行。
    @Test func appendsToExistingFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("usage-recorder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let recorder = UsageRecorder(dataRoot: root)
        let first = UsageRecord(time: Date(timeIntervalSince1970: 1), sessionID: "s", project: "p",
                                model: "m", input: 1, output: 1, cacheRead: 0, cacheWrite: 0)
        let second = UsageRecord(time: Date(timeIntervalSince1970: 2), sessionID: "s", project: "p",
                                 model: "m", input: 2, output: 2, cacheRead: 0, cacheWrite: 0)
        recorder.record(first)
        recorder.record(second)
        let read = UsageRecorder.readAll(from: UsageRecorder.file(in: root))
        #expect(read.count == 2)
        #expect(read.first?.time == second.time)
    }
}
