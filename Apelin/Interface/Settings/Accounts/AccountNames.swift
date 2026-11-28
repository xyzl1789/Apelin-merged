import ApelinProtocol
import Foundation

extension Notification.Name {
    static let accountNamesChanged = Notification.Name("wiki.qaq.apelin.accountNamesChanged")
}

/// 偏好键保留首账号的旧 wire 名称，额外账号使用自己的凭据标识。
/// 备注与账号命名只用于显示，绝不参与请求路由。
enum AccountPreferences {
    static func storeID(of provider: AgentProvider) -> String {
        switch provider {
        case .githubCopilot: "github-copilot"
        case .anthropic: "anthropic-api-key"
        case .anthropicOAuth: "anthropic"
        case .openAICompatible: "openai-compatible"
        case let .openAICompatibleEndpoint(number): "openai-compatible.\(number)"
        case .openAICodex: "openai-codex"
        case .cursor: "cursor"
        case .devin: "devin"
        case .kiro: "kiro"
        case .qoder: "qoder"
        case .qoderCN: "qoder-cn"
        case .workBuddy: "workbuddy"
        case .workBuddyAI: "workbuddy-ai"
        case .trae: "trae"
        case .traeIntl: "trae-intl"
        case .raccoon: "raccoon"
        case .kimiCoding: "kimi-coding"
        case .kimiCodingGlobal: "kimi-coding-ai"
        case .xai: "xai"
        case .zai: "zai"
        case .zaiCodingCN: "zai-coding-cn"
        case .openRouter: "openrouter"
        case .openAI: "openai-api-key"
        case .google: "google-api-key"
        case .deepSeek: "deepseek-api-key"
        case .openCodeGo: "opencode-go"
        case .openCodeZen: "opencode"
        }
    }

    static func storageKey(provider: AgentProvider, storeID: String?) -> String {
        guard let storeID, AgentAccountID.number(of: storeID) != nil,
              AgentAccountID.base(of: storeID) == Self.storeID(of: provider)
        else { return provider.rawValue }
        return storeID
    }

    static func provider(for storeID: String) -> AgentProvider? {
        let base = AgentAccountID.base(of: storeID)
        if let provider = AgentProvider.allCases.first(where: { Self.storeID(of: $0) == base }) {
            return provider
        }
        let prefix = "openai-compatible."
        guard base.hasPrefix(prefix), let number = Int(base.dropFirst(prefix.count)),
              AgentProvider.endpointNumbers.contains(number), base == "\(prefix)\(number)"
        else { return nil }
        return .openAICompatibleEndpoint(number)
    }

    static func matching(_ account: AgentAccount, provider: AgentProvider, storeID: String?) -> Bool {
        account.provider == provider
            && storageKey(provider: provider, storeID: account.storeID) == storageKey(provider: provider, storeID: storeID)
    }
}

/// 仅为没有现有备注入口的供应商提供账号命名；兼容端点继续使用我们的备注。
enum AccountNames {
    static func customName(for provider: AgentProvider, storeID: String?, defaults: UserDefaults = .standard) -> String? {
        guard provider.kind != .openAICompatible else { return nil }
        let raw = defaults.string(forKey: key(provider, storeID: storeID))?.trimmingCharacters(in: .whitespacesAndNewlines)
        return raw.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func save(_ name: String, for provider: AgentProvider, storeID: String?, defaults: UserDefaults = .standard) {
        guard provider.kind != .openAICompatible else { return }
        let text = name.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        if text.isEmpty { defaults.removeObject(forKey: key(provider, storeID: storeID)) }
        else { defaults.set(String(text.prefix(64)), forKey: key(provider, storeID: storeID)) }
        NotificationCenter.default.post(name: .accountNamesChanged, object: nil)
    }

    static func remove(for provider: AgentProvider, storeID: String?, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(provider, storeID: storeID))
        NotificationCenter.default.post(name: .accountNamesChanged, object: nil)
    }

    static func title(for account: AgentAccount) -> String {
        if let name = customName(for: account.provider, storeID: account.storeID) { return name }
        if let number = account.storeID.flatMap(AgentAccountID.number(of:)) {
            return "\(account.provider.displayName) #\(number)"
        }
        return account.provider.displayName
    }

    static func groupTitle(for account: AgentAccount) -> String {
        if let name = customName(for: account.provider, storeID: account.storeID) {
            return "\(name) · \(account.provider.displayName)"
        }
        if let label = account.account, !label.isEmpty {
            return account.provider.kind == .openAICompatible ? label : "\(title(for: account)) · \(label)"
        }
        return title(for: account)
    }

    private static func key(_ provider: AgentProvider, storeID: String?) -> String {
        "accountName.\(AccountPreferences.storageKey(provider: provider, storeID: storeID))"
    }
}
