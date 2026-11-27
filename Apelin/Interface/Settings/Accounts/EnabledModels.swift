import ApelinProtocol
import Foundation

extension Notification.Name {
    static let enabledModelsChanged = Notification.Name("wiki.qaq.apelin.enabledModelsChanged")
}

/// A device preference, separate from the provider's credentials and catalog.
enum EnabledModels {
    private static func key(_ provider: AgentProvider) -> String {
        "enabledModels.\(provider.rawValue)"
    }

    static func ids(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: key(provider)) ?? [])
    }

    static func save(_ models: Set<String>, custom: Set<String>, hidden: Set<String>, for provider: AgentProvider) {
        UserDefaults.standard.set(models.sorted(), forKey: key(provider))
        UserDefaults.standard.set(custom.sorted(), forKey: "customModels.\(provider.rawValue)")
        UserDefaults.standard.set(hidden.sorted(), forKey: "hiddenModels.\(provider.rawValue)")
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func remove(for provider: AgentProvider) {
        forget(provider.rawValue)
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    /// 按协议名称清理服务商的启用、自定义、隐藏模型和限额偏好。
    private static func forget(_ name: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "enabledModels.\(name)")
        defaults.removeObject(forKey: "customModels.\(name)")
        defaults.removeObject(forKey: "hiddenModels.\(name)")
        ModelLimitsStore.remove(forName: name, in: defaults)
    }

    /// 启动时删除已退役服务商留下的模型偏好与失效的 composer 选择。
    static func forgetRetiredProviders(in defaults: UserDefaults = .standard) {
        for name in Set(AgentProvider.retired.map(\.name)) {
            forget(name, in: defaults)
        }
        ComposerModelSelection.forgetRetiredProvider(in: defaults)
    }

    static func customIDs(for provider: AgentProvider) -> [String] {
        UserDefaults.standard.stringArray(forKey: "customModels.\(provider.rawValue)") ?? []
    }

    static func hiddenIDs(for provider: AgentProvider) -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "hiddenModels.\(provider.rawValue)") ?? [])
    }

    /// 附加的兼容端点不在内置供应商枚举中，从已保存的模型偏好补齐。
    static var providers: [AgentProvider] {
        let builtIn = AgentProvider.allCases
        let prefix = "enabledModels."
        let endpoints = UserDefaults.standard.dictionaryRepresentation().keys.compactMap { key -> AgentProvider? in
            guard key.hasPrefix(prefix),
                  let provider = AgentProvider(rawValue: String(key.dropFirst(prefix.count))),
                  case .openAICompatibleEndpoint = provider else { return nil }
            return provider
        }
        return builtIn + endpoints.filter { !builtIn.contains($0) }.sorted { $0.rawValue < $1.rawValue }
    }

    /// The model ids this device keeps for each provider, keyed by the
    /// provider's own id: handed to the account listing so the catalogs are
    /// read over the models the app shows — a custom endpoint's own — and not
    /// only the ones the agent can list for itself.
    static func knownModelIDs() -> [String: [String]] {
        var known: [String: [String]] = [:]
        for provider in providers {
            let models = ids(for: provider)
                .union(customIDs(for: provider))
                .subtracting(hiddenIDs(for: provider))
            if !models.isEmpty {
                known[provider.rawValue] = models.sorted()
            }
        }
        return known
    }

    /// Only the choices the composer can show, not disabled custom IDs. Kept
    /// separate from knownModelIDs(), which settings needs in full.
    static func selectedModelIDs() -> [String: [String]] {
        var selected: [String: [String]] = [:]
        for provider in providers {
            let models = ids(for: provider).subtracting(hiddenIDs(for: provider))
            if !models.isEmpty { selected[provider.rawValue] = models.sorted() }
        }
        return selected
    }

    static func accounts(from accounts: [AgentAccount]) -> [AgentAccount] {
        accounts.compactMap { account in
            guard account.signedIn else { return nil }
            var enabled = account
            let ids = ids(for: account.provider).subtracting(hiddenIDs(for: account.provider))
            enabled.models = account.isAPIKeyAccount ? ids.sorted() : (account.models ?? []).filter { ids.contains($0) }
            return enabled.models?.isEmpty == false ? enabled : nil
        }
    }
}
