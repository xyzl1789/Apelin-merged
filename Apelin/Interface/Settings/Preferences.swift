import ApelinCore
import ApelinProtocol
import Foundation

/// What the reader chose for the app as a whole, kept in the device's
/// defaults beside the composer's own behaviour.
enum Preferences {
    /// A model used by an agent operation that is not the conversation's main turn.
    enum DefaultModelKind: String, CaseIterable {
        case promptRewrite
        case compression
        case title
        case vision
        case imageGeneration
        /// A conversation an agent opens (`apelin_conversation_create`),
        /// listed in the sidebar under Delegated Chats.
        case derivedConversation

        var title: String {
            switch self {
            case .promptRewrite: String(localized: "Prompt Optimization")
            case .compression: String(localized: "Conversation Compression")
            case .title: String(localized: "Title Generation")
            case .vision: String(localized: "Image Understanding")
            case .imageGeneration: String(localized: "Image Generation")
            case .derivedConversation: String(localized: "Delegated Conversations")
            }
        }

        /// What the row says when nothing is chosen: an auxiliary operation
        /// follows the conversation's model, a delegated chat the one of the
        /// conversation that opened it.
        var followingTitle: String {
            switch self {
            case .derivedConversation: String(localized: "Follow the Opening Chat")
            default: String(localized: "Use Conversation Model")
            }
        }
    }

    struct DefaultModelSelection: Equatable {
        let provider: AgentProvider
        let model: String
    }

    /// The model defaults used by agent operations. An unset value means that
    /// operation follows the conversation's selected model.
    enum DefaultModels {
        static let changed = Notification.Name("wiki.qaq.apelin.defaultModelsChanged")

        static func selection(for kind: DefaultModelKind, defaults: UserDefaults = .standard) -> DefaultModelSelection? {
            guard let provider = defaults.string(forKey: providerKey(kind)).flatMap(AgentProvider.init(rawValue:)),
                  let model = defaults.string(forKey: modelKey(kind)),
                  !model.isEmpty
            else { return nil }
            return DefaultModelSelection(provider: provider, model: model)
        }

        static func save(_ selection: DefaultModelSelection, for kind: DefaultModelKind, defaults: UserDefaults = .standard) {
            defaults.set(selection.provider.rawValue, forKey: providerKey(kind))
            defaults.set(selection.model, forKey: modelKey(kind))
            NotificationCenter.default.post(name: changed, object: kind)
        }

        static func remove(for kind: DefaultModelKind, defaults: UserDefaults = .standard) {
            defaults.removeObject(forKey: providerKey(kind))
            defaults.removeObject(forKey: modelKey(kind))
            NotificationCenter.default.post(name: changed, object: kind)
        }

        static func summary(for kind: DefaultModelKind, defaults: UserDefaults = .standard) -> String {
            guard let selection = selection(for: kind, defaults: defaults) else {
                return kind.followingTitle
            }
            return "\(selection.provider.displayName) · \(selection.model)"
        }

        static var summary: String {
            let count = DefaultModelKind.allCases.count { selection(for: $0) != nil }
            guard count > 0 else { return String(localized: "Use Conversation Model") }
            return String(localized: "\(count) configured")
        }

        static var wire: AgentModelDefaults {
            func convert(_ kind: DefaultModelKind) -> AgentModelSelection? {
                guard let value = selection(for: kind) else { return nil }
                return AgentModelSelection(provider: value.provider, model: value.model)
            }
            return AgentModelDefaults(
                promptRewrite: convert(.promptRewrite),
                compression: convert(.compression),
                title: convert(.title),
                vision: convert(.vision),
                imageGeneration: convert(.imageGeneration),
                derivedConversation: convert(.derivedConversation)
            )
        }

        private static func providerKey(_ kind: DefaultModelKind) -> String {
            "agent.defaultModel.\(kind.rawValue).provider"
        }

        private static func modelKey(_ kind: DefaultModelKind) -> String {
            "agent.defaultModel.\(kind.rawValue).model"
        }
    }

    /// The text the reader wants every conversation to start under: what the
    /// agent's system prompt carries before anything else. Now backed by the
    /// persona collection; the single text/switch below is kept only as a
    /// one-time migration source for readers upgrading from the old page.
    enum PromptInjection {
        static let maximumCharacters = PersonaStore.maximumBodyCharacters
        private static let migratedKey = "agent.promptInjection.migratedToPersonas"
        // The store appends `Personas/` to its root itself; passing the folder
        // here would make it `Personas/Personas/personas.json`.
        private static let store = PersonaStore(root: DataFolder.app.root)

        /// The single-switch setting before personas. Never written again once
        /// the migration has run; kept so an upgrade carries the old prompt.
        static var legacyEnabled: Bool {
            get { UserDefaults.standard.bool(forKey: "agent.promptInjection.enabled") }
            set { UserDefaults.standard.set(newValue, forKey: "agent.promptInjection.enabled") }
        }

        static var legacyText: String {
            get { UserDefaults.standard.string(forKey: "agent.promptInjection.text") ?? "" }
            set {
                UserDefaults.standard.set(
                    String(newValue.prefix(maximumCharacters)),
                    forKey: "agent.promptInjection.text",
                )
            }
        }

        /// The persona collection, read straight from disk at each use: a
        /// change in Settings must reach a chat that is already open. The
        /// first read migrates the old single prompt into one manual persona.
        static var snapshot: PersonaSnapshot {
            get {
                migrateLegacyIfNeeded()
                return (try? store.read()) ?? PersonaSnapshot()
            }
            set {
                migrateLegacyIfNeeded()
                try? store.save(newValue)
            }
        }

        static var enabled: Bool {
            get { snapshot.enabled }
            set {
                var next = snapshot
                next.enabled = newValue
                snapshot = next
            }
        }

        /// Compatible surface for the settings summary and any code that only
        /// asks whether an injection is in force.
        static var wire: String? { wire(for: nil) }

        /// The body for the given model, nil when no persona is in force.
        static func wire(for model: String?) -> String? {
            let text = forPrompt(model: model)
            return text.isEmpty ? nil : text
        }

        /// Saves the collection, surfacing a failure (a corrupt file, a full
        /// disk, an unsafe path) to the caller rather than losing the edit.
        static func save(_ snapshot: PersonaSnapshot) throws {
            migrateLegacyIfNeeded()
            try store.createRootIfNeeded(folder: DataFolder.app)
            try store.save(snapshot)
        }

        static func forPrompt: String { forPrompt(model: nil) }

        /// The body for the persona in force at the given model, or "".
        static func forPrompt(model: String?) -> String {
            PersonaResolver.text(snapshot, model: model)
        }

        private static func migrateLegacyIfNeeded() {
            guard !UserDefaults.standard.bool(forKey: migratedKey) else { return }
            let text = legacyText
            if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let persona = Persona(name: "Default", body: text, matchMode: .manual)
                let migrated = PersonaSnapshot(enabled: legacyEnabled, activeID: persona.id, personas: [persona])
                do {
                    try store.createRootIfNeeded(folder: DataFolder.app)
                    try store.save(migrated)
                } catch {
                    // Keep the old text and retry on the next read: marking the
                    // migration done here would lose the reader's only prompt.
                    return
                }
            }
            UserDefaults.standard.set(true, forKey: migratedKey)
        }
    }

    /// What the next launch opens.
    enum Launch: String, CaseIterable {
        case lastConversation
        case newChat

        var title: String {
            switch self {
            case .lastConversation: String(localized: "Last Conversation")
            case .newChat: String(localized: "New Chat")
            }
        }
    }

    /// The share of a conversation's context that compacts it by itself.
    ///
    /// The agent compacts a conversation when what it holds reaches this
    /// share of the window the model reports, so a long one carries on
    /// without the reader asking.
    static var compressionThreshold: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: "chat.compressionThreshold") as? Double
            return (stored ?? 0.75).clamped(to: 0.5 ... 0.95)
        }
        set { UserDefaults.standard.set(newValue.clamped(to: 0.5 ... 0.95), forKey: "chat.compressionThreshold") }
    }

    /// The shares the threshold may be set to.
    static let compressionChoices: [Double] = [0.5, 0.6, 0.75, 0.85, 0.9, 0.95]

    /// `0.75` as "75%", in the reader's locale.
    static func percentText(_ value: Double) -> String {
        value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Whether the diff wraps its lines or scrolls them sideways.
    static var diffWraps: Bool {
        get { UserDefaults.standard.object(forKey: "git.diffWraps") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "git.diffWraps") }
    }

    static var launch: Launch {
        get {
            UserDefaults.standard.string(forKey: "chat.launch")
                .flatMap(Launch.init(rawValue:)) ?? .lastConversation
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "chat.launch") }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
