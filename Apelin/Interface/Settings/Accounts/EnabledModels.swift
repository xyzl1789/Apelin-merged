import ApelinProtocol
import Foundation

extension Notification.Name {
    static let enabledModelsChanged = Notification.Name("wiki.qaq.apelin.enabledModelsChanged")
}

/// 模型偏好按实际账号保存；首账号沿用旧键，不复制到额外账号。
enum EnabledModels {
    private static func suffix(_ provider: AgentProvider, storeID: String?) -> String {
        AccountPreferences.storageKey(provider: provider, storeID: storeID)
    }

    static func ids(for provider: AgentProvider, storeID: String? = nil, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: "enabledModels.\(suffix(provider, storeID: storeID))") ?? [])
    }

    static func save(_ models: Set<String>, custom: Set<String>, hidden: Set<String>, for provider: AgentProvider,
                     storeID: String? = nil, defaults: UserDefaults = .standard) {
        let id = suffix(provider, storeID: storeID)
        defaults.set(models.sorted(), forKey: "enabledModels.\(id)")
        defaults.set(custom.sorted(), forKey: "customModels.\(id)")
        defaults.set(hidden.sorted(), forKey: "hiddenModels.\(id)")
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    static func remove(for provider: AgentProvider, storeID: String? = nil, defaults: UserDefaults = .standard) {
        forget(suffix(provider, storeID: storeID), in: defaults)
        NotificationCenter.default.post(name: .enabledModelsChanged, object: nil)
    }

    private static func forget(_ name: String, in defaults: UserDefaults) {
        for prefix in ["enabledModels.", "customModels.", "hiddenModels."] {
            defaults.removeObject(forKey: prefix + name)
        }
        ModelLimitsStore.remove(forName: name, in: defaults)
        ModelParameters.removeAll(forName: name, defaults: defaults)
    }

    /// 保留退役清理；连同额外账号的偏好清理，不影响仍可用的服务商。
    static func forgetRetiredProviders(in defaults: UserDefaults = .standard) {
        let retired = Set(AgentProvider.retired.flatMap { [$0.name, $0.storeID] })
        for name in retired { forget(name, in: defaults) }
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in ["enabledModels.", "customModels.", "hiddenModels.", "modelLimits.", "modelParameters.", "accountName."] where key.hasPrefix(prefix) {
                let name = String(key.dropFirst(prefix.count)).split(separator: ".").first.map(String.init) ?? ""
                if retired.contains(AgentAccountID.base(of: name)) { defaults.removeObject(forKey: key) }
            }
        }
        ComposerModelSelection.forgetRetiredProvider(in: defaults)
    }

    static func customIDs(for provider: AgentProvider, storeID: String? = nil, defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: "customModels.\(suffix(provider, storeID: storeID))") ?? []
    }

    static func hiddenIDs(for provider: AgentProvider, storeID: String? = nil, defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: "hiddenModels.\(suffix(provider, storeID: storeID))") ?? [])
    }

    static var providers: [AgentProvider] { configuredProviders(in: .standard) }

    private static func configuredProviders(in defaults: UserDefaults) -> [AgentProvider] {
        var result = AgentProvider.allCases
        for key in defaults.dictionaryRepresentation().keys.sorted() {
            for prefix in ["enabledModels.", "customModels."] where key.hasPrefix(prefix) {
                let raw = String(key.dropFirst(prefix.count))
                guard !raw.contains(AgentAccountID.separator), let provider = AgentProvider(rawValue: raw),
                      case .openAICompatibleEndpoint = provider, !result.contains(provider)
                else { continue }
                result.append(provider)
            }
        }
        return result
    }

    static var configuredAccounts: [(key: String, provider: AgentProvider, storeID: String?)] {
        configuredAccounts(in: .standard)
    }

    static func configuredAccounts(in defaults: UserDefaults) -> [(key: String, provider: AgentProvider, storeID: String?)] {
        var entries = configuredProviders(in: defaults).map { (key: $0.rawValue, provider: $0, storeID: Optional<String>.none) }
        var seen = Set(entries.map(\.key))
        for key in defaults.dictionaryRepresentation().keys.sorted() {
            for prefix in ["enabledModels.", "customModels."] where key.hasPrefix(prefix) {
                let raw = String(key.dropFirst(prefix.count))
                guard AgentAccountID.number(of: raw) != nil,
                      let provider = AccountPreferences.provider(for: raw), seen.insert(raw).inserted
                else { continue }
                entries.append((key: raw, provider: provider, storeID: raw))
            }
        }
        return entries
    }

    /// 主账号用旧 wire 键，额外账号用各自 storeID，worker 不会把两者混合。
    static func knownModelIDs(defaults: UserDefaults = .standard) -> [String: [String]] {
        var known: [String: [String]] = [:]
        for entry in configuredAccounts(in: defaults) {
            let models = ids(for: entry.provider, storeID: entry.storeID, defaults: defaults)
                .union(customIDs(for: entry.provider, storeID: entry.storeID, defaults: defaults))
                .subtracting(hiddenIDs(for: entry.provider, storeID: entry.storeID, defaults: defaults))
            if !models.isEmpty { known[entry.key] = models.sorted() }
        }
        return known
    }

    static func selectedModelIDs(defaults: UserDefaults = .standard) -> [String: [String]] {
        var selected: [String: [String]] = [:]
        for entry in configuredAccounts(in: defaults) {
            let models = ids(for: entry.provider, storeID: entry.storeID, defaults: defaults)
                .subtracting(hiddenIDs(for: entry.provider, storeID: entry.storeID, defaults: defaults))
            if !models.isEmpty { selected[entry.key] = models.sorted() }
        }
        return selected
    }

    static func accounts(from accounts: [AgentAccount]) -> [AgentAccount] {
        accounts.compactMap { account in
            guard account.signedIn else { return nil }
            var enabled = account
            let ids = ids(for: account.provider, storeID: account.storeID)
                .subtracting(hiddenIDs(for: account.provider, storeID: account.storeID))
            enabled.models = account.isAPIKeyAccount ? ids.sorted() : (account.models ?? []).filter { ids.contains($0) }
            return enabled.models?.isEmpty == false ? enabled : nil
        }
    }
}
