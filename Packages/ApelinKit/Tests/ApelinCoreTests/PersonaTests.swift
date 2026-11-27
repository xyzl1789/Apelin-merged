import ApelinCore
import Foundation
import XCTest

final class PersonaTests: XCTestCase {
    func testManualNeedsEnabledAndActivePersona() {
        let manual = Persona(id: "m", name: "Manual", body: "  keep this  ", matchMode: .manual)
        let snapshot = PersonaSnapshot(enabled: true, activeID: manual.id, personas: [manual])
        XCTAssertEqual(PersonaResolver.text(snapshot, model: "gpt-4"), "keep this")
        XCTAssertEqual(PersonaResolver.text(snapshot, model: nil), "keep this")
        XCTAssertNil(PersonaResolver.resolve(PersonaSnapshot(enabled: false, activeID: manual.id, personas: [manual]), model: nil))
        XCTAssertNil(PersonaResolver.resolve(PersonaSnapshot(enabled: true, activeID: nil, personas: [manual]), model: nil))
        XCTAssertNil(PersonaResolver.resolve(PersonaSnapshot(enabled: true, activeID: "missing", personas: [manual]), model: nil))
    }

    func testAutomaticMatchWinsOverManualAndPriorityBreaksTies() {
        let manual = Persona(id: "m", name: "Manual", body: "manual", matchMode: .manual)
        let low = Persona(id: "l", name: "Low", body: "low", matchMode: .automatic, modelPatterns: ["gpt.*"], priority: 1)
        let high = Persona(id: "h", name: "High", body: " high ", matchMode: .automatic, modelPatterns: ["^GPT"], priority: 9)
        let snapshot = PersonaSnapshot(enabled: true, activeID: manual.id, personas: [manual, low, high])
        XCTAssertEqual(PersonaResolver.text(snapshot, model: "gpt-4o"), "high")
        XCTAssertEqual(PersonaResolver.text(snapshot, model: "claude-3"), "manual")
        XCTAssertEqual(PersonaResolver.text(snapshot, model: nil), "manual")
        let onlyLow = PersonaSnapshot(enabled: true, activeID: manual.id, personas: [manual, low])
        XCTAssertEqual(PersonaResolver.text(onlyLow, model: "GPT-4"), "low")
        XCTAssertEqual(PersonaResolver.text(onlyLow, model: "Gemini"), "manual")
    }

    func testBlankBodiesAndInvalidPatternsNeverResolve() {
        let blank = Persona(id: "b", name: "Blank", body: "  \n ", matchMode: .automatic, modelPatterns: ["gpt"])
        let snapshot = PersonaSnapshot(enabled: true, activeID: blank.id, personas: [blank])
        XCTAssertNil(PersonaResolver.resolve(snapshot, model: "gpt-4"))
        XCTAssertEqual(PersonaResolver.text(snapshot, model: "gpt-4"), "")
    }

    func testStorePersistsAndRejectsBadContent() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Personas"), withIntermediateDirectories: true)
        let store = PersonaStore(root: root)
        XCTAssertTrue(store.file.path.hasSuffix("Personas/personas.json"))
        let persona = Persona(name: "测试", body: "始终用中文", matchMode: .automatic, modelPatterns: ["gpt.*"], priority: 3)
        let snapshot = PersonaSnapshot(enabled: true, activeID: nil, personas: [persona])
        try store.save(snapshot)
        XCTAssertEqual(try PersonaStore(root: root).read(), snapshot)
        let bad = Persona(id: persona.id, name: "x", body: "y", modelPatterns: ["["])
        XCTAssertThrowsError(try store.save(PersonaSnapshot(personas: [bad]))) {
            XCTAssertEqual($0 as? PersonaStoreError, .invalidContent)
        }
        XCTAssertEqual(try store.read(), snapshot)
    }

    func testStoreRejectsStaleEditAndStaleClear() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonaStore(root: root)
        let persona = Persona(id: "manual", name: "配置", body: "旧正文")
        let original = PersonaSnapshot(enabled: true, activeID: persona.id, personas: [persona])
        try store.save(original, replacing: PersonaSnapshot())
        var latest = original
        latest.personas[0].body = "其他窗口保存的新正文"
        try PersonaStore(root: root).save(latest, replacing: original)

        var staleEdit = original
        staleEdit.personas[0].name = "旧窗口草稿"
        XCTAssertThrowsError(try store.save(staleEdit, replacing: original)) {
            XCTAssertEqual($0 as? PersonaStoreError, .changed)
        }
        XCTAssertThrowsError(try store.save(PersonaSnapshot(), replacing: original)) {
            XCTAssertEqual($0 as? PersonaStoreError, .changed)
        }
        XCTAssertEqual(try store.read(), latest)
        XCTAssertEqual(staleEdit.personas[0].name, "旧窗口草稿")
    }

    func testStoreDoesNotResurrectDeletedPersona() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonaStore(root: root)
        let persona = Persona(id: "deleted", name: "待删除配置", body: "正文")
        let original = PersonaSnapshot(enabled: true, activeID: persona.id, personas: [persona])
        try store.save(original)
        try PersonaStore(root: root).save(PersonaSnapshot(), replacing: original)
        XCTAssertThrowsError(try store.save(original, replacing: original)) {
            XCTAssertEqual($0 as? PersonaStoreError, .changed)
        }
        XCTAssertEqual(try store.read(), PersonaSnapshot())
    }

    func testStoreAcceptsUpdatedBaselineAndKeepsLongPrompts() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PersonaStore(root: root)
        XCTAssertEqual(PersonaStore.maximumBodyCharacters, 16 * 1024)
        let persona = Persona(id: "long", name: "长提示词", body: String(repeating: "中", count: 16 * 1024))
        let original = PersonaSnapshot(personas: [persona])
        try store.save(original, replacing: PersonaSnapshot())
        var next = original
        next.enabled = true
        next.activeID = persona.id
        try store.save(next, replacing: original)
        next.personas[0].pinned = true
        let baseline = try store.read()
        try store.save(next, replacing: baseline)
        XCTAssertEqual(try store.read(), next)
        XCTAssertEqual(try store.read().personas[0].body, persona.body)
    }
}
