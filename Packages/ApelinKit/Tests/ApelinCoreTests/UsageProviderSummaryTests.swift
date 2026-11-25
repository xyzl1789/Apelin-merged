import Foundation
import Testing
@testable import ApelinCore

struct UsageProviderSummaryTests {
    private func record(
        _ id: String? = "openAICompatible",
        host: String? = "api.xingchiapi.com",
        provider: String? = "openai-compatible",
        model: String = "model-a",
        time: TimeInterval = 1,
    ) -> UsageRecord {
        UsageRecord(
            time: Date(timeIntervalSince1970: time), sessionID: "session", project: "project", model: model,
            provider: provider, providerIdentity: id.map { UsageProviderIdentity(accountID: $0, endpointHost: host) },
            input: 10, output: 20, cacheRead: 3, cacheWrite: 4,
        )
    }

    @Test func differentEndpointsAreNotHiddenUnderOneProtocol() {
        let rows = UsageProviderSummary.summarize([
            record(), record("openAICompatible.2", host: "other.example.invalid"),
        ], unknown: "未知供应商")
        #expect(Set(rows.map(\.name)) == ["api.xingchiapi.com", "other.example.invalid"])
        #expect(rows.allSatisfy { $0.count == 1 && $0.input == 10 && $0.output == 20 })
    }

    @Test func sameEndpointUsesStableInstanceNumbers() {
        let records = [record(), record("openAICompatible.2"), record(model: "model-b")]
        let rows = UsageProviderSummary.summarize(records, unknown: "未知供应商")
        #expect(rows.count == 2)
        #expect(rows.first?.name == "api.xingchiapi.com · 1")
        #expect(rows.first?.count == 2)
        #expect(rows.last?.name == "api.xingchiapi.com · 2")
        #expect(rows == UsageProviderSummary.summarize(Array(records.reversed()), unknown: "未知供应商"))
    }

    @Test func notesOverrideHostsButNeverMergeInstances() {
        let records = [record(), record("openAICompatible.2")]
        let rows = UsageProviderSummary.summarize(records, titles: ["openAICompatible": "主账户"], unknown: "未知供应商")
        #expect(Set(rows.map(\.name)) == ["主账户", "api.xingchiapi.com"])
        let renamed = UsageProviderSummary.summarize(records, titles: ["openAICompatible": "备用账户"], unknown: "未知供应商")
        #expect(Set(rows.compactMap(\.identity)) == Set(renamed.compactMap(\.identity)))
        #expect(renamed.contains { $0.name == "备用账户" && $0.count == 1 })
        let duplicate = UsageProviderSummary.summarize(records, titles: [
            "openAICompatible": "相同备注", "openAICompatible.2": "相同备注",
        ], unknown: "未知供应商")
        #expect(Set(duplicate.map(\.name)) == ["相同备注 · 1", "相同备注 · 2"])
        #expect(duplicate.count == 2)
    }

    @Test func changedEndpointInOneSlotDoesNotRewritePreviousEndpoint() {
        let rows = UsageProviderSummary.summarize([
            record(), record(host: "other.example.invalid"),
        ], titles: ["openAICompatible": "同一备注"], unknown: "未知供应商")
        #expect(rows.count == 2)
        #expect(Set(rows.map(\.name)) == ["同一备注 · api.xingchiapi.com · 1", "同一备注 · other.example.invalid · 1"])
    }

    @Test func invalidOrMissingEndpointStillHasAnIdentifiableName() {
        let row = UsageProviderSummary.summarize([
            record("openAICompatible.3", host: nil),
        ], unknown: "未知供应商").first
        #expect(row?.name == "openai-compatible · 3")
        #expect(row?.identity?.accountID == "openAICompatible.3")
    }

    @Test func legacyRecordsKeepTheirOriginalGroupingAndNames() throws {
        let bytes = Data(#"{"time":"2026-11-25T00:00:00Z","sessionID":"s","project":"p","model":"m","provider":"openai-compatible","input":10,"output":20,"cacheRead":3,"cacheWrite":4}"#.utf8)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let old = try decoder.decode(UsageRecord.self, from: bytes)
        #expect(old.providerIdentity == nil)
        let rows = UsageProviderSummary.summarize([old, old, record()], unknown: "未知供应商")
        #expect(rows.count == 2)
        #expect(rows.first { $0.identity == nil }?.name == "openai-compatible")
        #expect(rows.first { $0.identity == nil }?.count == 2)
        let encoded = try JSONEncoder().encode(old)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("providerIdentity"))
        #expect(UsageProviderSummary.summarize([record(nil, provider: nil)], unknown: "未知供应商").first?.name == "未知供应商")
    }

    @Test func legacyAndNewRowsWithTheSameTitleStayDistinct() {
        let rows = UsageProviderSummary.summarize([
            record(nil, provider: "api.xingchiapi.com"), record(),
        ], unknown: "未知供应商")
        #expect(rows.count == 2)
        #expect(rows.first { $0.identity == nil }?.name == "api.xingchiapi.com")
        #expect(rows.first { $0.identity != nil }?.name == "api.xingchiapi.com · 1")
    }

    @Test func aNoteMatchingAGeneratedNameIsAlsoDisambiguated() {
        let rows = UsageProviderSummary.summarize([
            record(), record("openAICompatible.2"), record("openAICompatible.3", host: "other.example.invalid"),
        ], titles: ["openAICompatible.3": "api.xingchiapi.com · 1"], unknown: "未知供应商")
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.name)).count == 3)
    }

    @Test func cacheAccountingKeepsEachScreensExistingConvention() {
        let records = [record(), record("openAICompatible.2")]
        let settings = UsageProviderSummary.summarize(records, unknown: "未知供应商")
        let chat = UsageProviderSummary.summarize(records, unknown: "未知供应商", includingCache: true)
        #expect(settings.map(\.name) == chat.map(\.name))
        #expect(settings.allSatisfy { $0.input == 10 })
        #expect(chat.allSatisfy { $0.input == 17 })
        #expect(chat.map(\.output) == settings.map(\.output))
    }

    @Test func hostExtractionNeverPersistsCredentialsPathsOrQueries() throws {
        let host = UsageProviderIdentity.host(from: "https://user:private-password@API.XINGCHIAPI.COM:443/private-path?key=private-key#private-fragment")
        #expect(host == "api.xingchiapi.com")
        #expect(UsageProviderIdentity.host(from: "file:///private/path") == nil)
        #expect(UsageProviderIdentity.host(from: "not a URL") == nil)
        #expect(UsageProviderIdentity.host(from: "  ") == nil)
        let entry = record(host: host)
        let bytes = try JSONEncoder().encode(entry)
        let decoded = try JSONDecoder().decode(UsageRecord.self, from: bytes)
        #expect(decoded == entry)
        let text = String(decoding: bytes, as: UTF8.self)
        for secret in ["private-password", "private-key", "private-path", "private-fragment"] {
            #expect(!text.contains(secret))
        }
    }
}
