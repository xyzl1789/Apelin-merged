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
}
