import Foundation

/// Chooses the one persona in force for a conversation, from the collection
/// on disk. Pure logic — no files, no UI — so it can be tested on the host.
///
/// When injection is off, nothing is in force. Otherwise automatic personas
/// whose `modelPatterns` match the model compete by descending `priority`,
/// then name, then id; a match wins over a manual selection. With no automatic
/// match, the manually active persona is in force. A persona whose body is
/// only whitespace is never chosen: there is nothing to inject.
public enum PersonaResolver {
    public static func resolve(_ snapshot: PersonaSnapshot, model: String?) -> Persona? {
        guard snapshot.enabled else { return nil }

        let usable = snapshot.personas.filter { !$0.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let candidates = model.map { modelID in
            usable.filter { $0.matchMode == .automatic && matches($0, model: modelID) }
        } ?? []

        if let automatic = candidates.max(by: precedes) {
            return automatic
        }
        guard let activeID = snapshot.activeID else { return nil }
        return usable.first { $0.id == activeID && $0.matchMode == .manual }
    }

    /// The text a prompt carries: the resolved body, trimmed, or "" when none.
    public static func text(_ snapshot: PersonaSnapshot, model: String?) -> String {
        guard let persona = resolve(snapshot, model: model) else { return "" }
        return persona.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ persona: Persona, model: String) -> Bool {
        for pattern in persona.modelPatterns where !pattern.isEmpty {
            if let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(model.startIndex..., in: model)
                if expression.firstMatch(in: model, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// `true` when `lhs` sorts before `rhs` in priority order: lower priority,
    /// then later name, then later id.
    private static func precedes(_ lhs: Persona, _ rhs: Persona) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.name != rhs.name { return lhs.name > rhs.name }
        return lhs.id > rhs.id
    }
}
