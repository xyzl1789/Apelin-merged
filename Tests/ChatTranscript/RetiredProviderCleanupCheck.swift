import ApelinProtocol
import Foundation

/// 轻量测试替身：此检查只需解析默认模型的返回形状，不调用默认模型存储。
enum Preferences {
    enum DefaultModelKind {
        case derivedConversation
    }

    enum DefaultModels {
        struct Selection {
            var provider: AgentProvider
            var model: String
        }

        static func selection(for _: DefaultModelKind, defaults _: UserDefaults) -> Selection? {
            nil
        }
    }
}

/// 验证退役服务商清理只影响旧服务商的数据，并优先保留旧格式中的通用 composer 偏好。
func checkRetiredProviderCleanup() {
    let suite = "wiki.qaq.apelin.test.retired-provider-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }

    let retiredConversationKey = "composer.modelSelection.conversation.11111111-1111-1111-1111-111111111111"
    let activeConversationKey = "composer.modelSelection.conversation.22222222-2222-2222-2222-222222222222"

    defaults.set(["gemini-4-neon-high"], forKey: "enabledModels.antigravity")
    defaults.set(["custom-agy"], forKey: "customModels.antigravity")
    defaults.set(["hidden-agy"], forKey: "hiddenModels.antigravity")
    defaults.set(["gemini-4-neon-high": ["contextWindow": 200_000]], forKey: "modelLimits.antigravity")
    defaults.set("corrupt", forKey: "modelLimits.antigravity.unreadable")

    defaults.set(["gpt-5"], forKey: "enabledModels.openAI")
    defaults.set(["custom-openai"], forKey: "customModels.openAI")
    defaults.set(["hidden-openai"], forKey: "hiddenModels.openAI")
    defaults.set(["gpt-5": ["contextWindow": 400_000]], forKey: "modelLimits.openAI")
    defaults.set("keep-aside", forKey: "modelLimits.openAI.unreadable")

    defaults.set(
        Data(#"{"provider":"antigravity","model":"gemini-4-neon-high","supportedEfforts":["low","high"],"effort":"high","tier":"priority"}"#.utf8),
        forKey: "composer.modelSelection",
    )
    defaults.set(
        Data(#"{"provider":"antigravity","model":"gemini-4-neon-high","supportedEfforts":["high"]}"#.utf8),
        forKey: retiredConversationKey,
    )
    let activeSelection = Data(#"{"provider":"openAI","model":"gpt-5","supportedEfforts":["high"]}"#.utf8)
    defaults.set(activeSelection, forKey: activeConversationKey)

    EnabledModels.forgetRetiredProviders(in: defaults)

    for key in [
        "enabledModels.antigravity",
        "customModels.antigravity",
        "hiddenModels.antigravity",
        "modelLimits.antigravity",
        "modelLimits.antigravity.unreadable",
        "composer.modelSelection",
        retiredConversationKey,
    ] {
        precondition(defaults.object(forKey: key) == nil, "未清理退役偏好：\(key)")
    }

    precondition(defaults.string(forKey: "composer.reasoningEffort") == AgentReasoningEffort.high.rawValue)
    precondition(defaults.string(forKey: "composer.serviceTier") == AgentServiceTier.priority.rawValue)
    precondition(defaults.stringArray(forKey: "enabledModels.openAI") == ["gpt-5"])
    precondition(defaults.stringArray(forKey: "customModels.openAI") == ["custom-openai"])
    precondition(defaults.stringArray(forKey: "hiddenModels.openAI") == ["hidden-openai"])
    precondition(defaults.dictionary(forKey: "modelLimits.openAI") != nil)
    precondition(defaults.string(forKey: "modelLimits.openAI.unreadable") == "keep-aside")
    precondition(defaults.data(forKey: activeConversationKey) == activeSelection)

    let activeGlobalSelection = Data(#"{"provider":"openAI","model":"gpt-5","supportedEfforts":["high"]}"#.utf8)
    defaults.set(activeGlobalSelection, forKey: "composer.modelSelection")
    EnabledModels.forgetRetiredProviders(in: defaults)
    precondition(defaults.data(forKey: "composer.modelSelection") == activeGlobalSelection)

    let corrupt = Data("not-json".utf8)
    defaults.set(corrupt, forKey: "composer.modelSelection")
    EnabledModels.forgetRetiredProviders(in: defaults)
    precondition(defaults.data(forKey: "composer.modelSelection") == corrupt)

    defaults.removeObject(forKey: "composer.modelSelection")
    EnabledModels.forgetRetiredProviders(in: defaults)
    precondition(defaults.object(forKey: "composer.modelSelection") == nil)
    print("通过：退役服务商偏好已清理，当前服务商数据与 composer 偏好保持不变")
}
