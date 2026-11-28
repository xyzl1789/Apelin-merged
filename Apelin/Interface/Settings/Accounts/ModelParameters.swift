import ApelinProtocol
import Foundation

extension Notification.Name {
    /// A model's figures were saved; an open conversation reads them with
    /// its next message.
    static let modelParametersChanged = Notification.Name("wiki.qaq.apelin.modelParametersChanged")
}

/// What one model is read as, as the user set it in Settings ▸ Models: a
/// device preference, separate from the provider's credentials and its
/// catalog, kept per provider and model.
///
/// Absent is never the same as `false` here: a figure left alone is what the
/// catalog entry says, and one set is the user's answer in its place.
enum ModelParameters {
    /// One model's figures: nil is what its catalog entry, or its own record,
    /// says.
    struct Values: Equatable {
        var contextWindow: Int?
        var maxTokens: Int?
        /// Whether the model takes images; `false` is a relay that serves it
        /// as text only, `true` one whose record does not say so.
        var acceptsImages: Bool?
        /// Whether it thinks before it answers.
        var reasoning: Bool?
        /// Whether the catalog's figures apply at all: an endpoint that
        /// refuses a figure it does not honour. Absent is on.
        var followsCatalog: Bool?

        var isEmpty: Bool {
            contextWindow == nil && maxTokens == nil && acceptsImages == nil
                && reasoning == nil && followsCatalog == nil
        }

        var wire: AgentModelParameters? {
            isEmpty ? nil : AgentModelParameters(
                contextWindow: contextWindow,
                maxTokens: maxTokens,
                acceptsImages: acceptsImages,
                reasoning: reasoning,
                followsCatalog: followsCatalog,
            )
        }
    }

    private static func key(_ provider: AgentProvider, storeID: String?, model: String) -> String {
        "modelParameters.\(AccountPreferences.storageKey(provider: provider, storeID: storeID)).\(model)"
    }

    static func values(for provider: AgentProvider?, storeID: String? = nil, model: String?, defaults: UserDefaults = .standard) -> Values {
        guard let provider, let model, !model.isEmpty,
              let stored = defaults.dictionary(forKey: key(provider, storeID: storeID, model: model))
        else { return Values() }
        return Values(
            contextWindow: stored["contextWindow"] as? Int,
            maxTokens: stored["maxTokens"] as? Int,
            acceptsImages: stored["acceptsImages"] as? Bool,
            reasoning: stored["reasoning"] as? Bool,
            followsCatalog: stored["followsCatalog"] as? Bool,
        )
    }

    static func save(_ values: Values, for provider: AgentProvider, storeID: String? = nil,
                     model: String, defaults: UserDefaults = .standard) {
        let storageKey = key(provider, storeID: storeID, model: model)
        if values.isEmpty {
            defaults.removeObject(forKey: storageKey)
        } else {
            // Only what the user set is stored: a plist cannot hold an
            // optional, and an absent key is what the catalog or the record
            // says.
            var stored: [String: Any] = [:]
            if let contextWindow = values.contextWindow { stored["contextWindow"] = contextWindow }
            if let maxTokens = values.maxTokens { stored["maxTokens"] = maxTokens }
            if let acceptsImages = values.acceptsImages { stored["acceptsImages"] = acceptsImages }
            if let reasoning = values.reasoning { stored["reasoning"] = reasoning }
            if let followsCatalog = values.followsCatalog { stored["followsCatalog"] = followsCatalog }
            defaults.set(stored, forKey: storageKey)
        }
        NotificationCenter.default.post(name: .modelParametersChanged, object: nil)
    }

    static func removeAll(for provider: AgentProvider, storeID: String? = nil, defaults: UserDefaults = .standard) {
        removeAll(forName: AccountPreferences.storageKey(provider: provider, storeID: storeID), defaults: defaults)
    }

    static func removeAll(forName name: String, defaults: UserDefaults = .standard) {
        let prefix = "modelParameters.\(name)."
        // 首兼容端点的旧键是其他端点键的前缀，退出首端点不得顺带删除其他端点。
        let protected = name == AgentProvider.openAICompatible.rawValue
            ? AgentProvider.endpointNumbers.map { "modelParameters.\(AgentProvider.openAICompatibleEndpoint($0).rawValue)." }
            : []
        for key in defaults.dictionaryRepresentation().keys
            where key.hasPrefix(prefix) && !protected.contains(where: { key.hasPrefix($0) })
        {
            defaults.removeObject(forKey: key)
        }
        NotificationCenter.default.post(name: .modelParametersChanged, object: nil)
    }
}
