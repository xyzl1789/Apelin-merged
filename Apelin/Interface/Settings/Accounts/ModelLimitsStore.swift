import ApelinProtocol
import Foundation

/// 每个账号自己的模型限额；首账号沿用旧键，坏条目原样保留。
enum ModelLimitsStore {
    private static let contextWindowKey = "contextWindow"
    private static let maxOutputKey = "maxOutputTokens"

    private static func key(_ provider: AgentProvider, storeID: String?) -> String {
        "modelLimits.\(AccountPreferences.storageKey(provider: provider, storeID: storeID))"
    }

    static func limits(for provider: AgentProvider, storeID: String? = nil, model: String,
                       defaults: UserDefaults = .standard) -> AgentModelLimits? {
        guard let entry = defaults.dictionary(forKey: key(provider, storeID: storeID))?[model] as? [String: Any] else {
            return nil
        }
        let limits = AgentModelLimits(
            contextWindow: entry[contextWindowKey] as? Int,
            maxOutputTokens: entry[maxOutputKey] as? Int,
        )
        return limits.isAutomatic ? nil : limits
    }

    static func save(_ limits: AgentModelLimits?, for provider: AgentProvider, storeID: String? = nil,
                     model: String, defaults: UserDefaults = .standard) {
        let storageKey = key(provider, storeID: storeID)
        if let unreadable = defaults.object(forKey: storageKey), !(unreadable is [String: Any]) {
            // 保存前先保留无法读取的整份偏好，不用空字典覆盖掉唯一原件。
            defaults.set(unreadable, forKey: storageKey + ".unreadable")
        }
        var entries = defaults.dictionary(forKey: storageKey) ?? [:]
        if let limits, !limits.isAutomatic {
            var entry: [String: Int] = [:]
            entry[contextWindowKey] = limits.contextWindow
            entry[maxOutputKey] = limits.maxOutputTokens
            entries[model] = entry
        } else {
            entries[model] = nil
        }
        defaults.set(entries.isEmpty ? nil : entries, forKey: storageKey)
    }

    static func remove(for provider: AgentProvider, storeID: String? = nil, defaults: UserDefaults = .standard) {
        remove(forName: AccountPreferences.storageKey(provider: provider, storeID: storeID), in: defaults)
    }

    /// 退出账号及退役清理只删除对应账号的限额。
    static func remove(forName name: String, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: "modelLimits.\(name)")
        defaults.removeObject(forKey: "modelLimits.\(name).unreadable")
    }
}
