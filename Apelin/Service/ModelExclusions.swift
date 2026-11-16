import ApelinProtocol
import Foundation

extension Notification.Name {
    /// Posted whenever an exclusion rule or an automatic-assistant switch
    /// changes, so the settings rows and the composer can refresh together.
    static let modelExclusionsChanged = Notification.Name("wiki.qaq.apelin.modelExclusionsChanged")
}

/// The reader's rules for which models the automatic assistant may use.
///
/// Two explicit rules are kept: whole providers and individual models
/// (named together with their provider, since the same id exists at more than
/// one). Free/paid is decided by the reader choosing which models to exclude;
/// no price catalog guesses on their behalf. A model is excluded when either
/// rule matches it. Everything is stored in `UserDefaults` under one key.
enum ModelExclusions {
    /// A model is identified by its exact provider and model ID.
    struct ModelKey: Codable, Hashable, Sendable {
        var provider: String
        var model: String

        init(provider: AgentProvider, model: String) {
            self.provider = provider.rawValue
            self.model = model
        }
    }

    struct Stored: Codable, Sendable {
        var providers: [String] = []
        var models: [ModelKey] = []
    }

    private static let storageKey = "modelExclusions.rules"

    static var stored: Stored {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey),
                  let decoded = try? JSONDecoder().decode(Stored.self, from: data)
            else { return Stored() }
            return decoded
        }
        set {
            let data = try? JSONEncoder().encode(newValue)
            UserDefaults.standard.set(data, forKey: storageKey)
            NotificationCenter.default.post(name: .modelExclusionsChanged, object: nil)
        }
    }

    // MARK: - Rules

    static func isProviderExcluded(_ provider: AgentProvider) -> Bool {
        stored.providers.contains(provider.rawValue)
    }

    static func isModelExcluded(_ provider: AgentProvider, model: String) -> Bool {
        let rules = stored
        if rules.providers.contains(provider.rawValue) { return true }
        return rules.models.contains { $0.provider == provider.rawValue && $0.model == model }
    }

    static func setProvider(_ provider: AgentProvider, excluded: Bool) {
        var rules = stored
        let raw = provider.rawValue
        if excluded {
            if !rules.providers.contains(raw) { rules.providers.append(raw) }
        } else {
            rules.providers.removeAll { $0 == raw }
        }
        stored = rules
    }

    static func setModel(_ provider: AgentProvider, model: String, excluded: Bool) {
        var rules = stored
        if excluded {
            let key = ModelKey(provider: provider, model: model)
            if !rules.models.contains(key) { rules.models.append(key) }
        } else {
            rules.models.removeAll { $0.provider == provider.rawValue && $0.model == model }
        }
        stored = rules
    }
}
