import ApelinProtocol
import Foundation

/// 直接使用生产偏好存储与独立 suite，首账号兼容旧键但额外账号不继承。
func checkAccountPreferences() {
    let suite = "wiki.qaq.apelin.test.account-preferences-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let provider = AgentProvider.openAI
    let second = "openai-api-key#2"
    let third = "openai-api-key#3"
    let model = "same-model"

    precondition(AccountPreferences.storageKey(provider: provider, storeID: nil) == provider.rawValue)
    precondition(AccountPreferences.storageKey(provider: provider, storeID: "openai-api-key") == provider.rawValue)
    precondition(AccountPreferences.storageKey(provider: provider, storeID: second) == second)
    precondition(AccountPreferences.storageKey(provider: provider, storeID: "anthropic#2") == provider.rawValue)
    precondition(AccountPreferences.provider(for: second) == provider)
    precondition(AccountPreferences.provider(for: "trae#2") == .trae)
    precondition(AccountPreferences.provider(for: "workbuddy#2") == .workBuddy)
    let mainAccount = AgentAccount(provider: provider, method: .apiKey, signedIn: true, storeID: "openai-api-key")
    let extraAccount = AgentAccount(provider: provider, method: .apiKey, signedIn: true, storeID: second)
    precondition(AccountPreferences.matching(mainAccount, provider: provider, storeID: nil))
    precondition(!AccountPreferences.matching(extraAccount, provider: provider, storeID: nil))
    precondition(AccountPreferences.matching(extraAccount, provider: provider, storeID: second))
    precondition(!AccountPreferences.matching(extraAccount, provider: .anthropic, storeID: second))

    EnabledModels.save([model], custom: ["main-custom"], hidden: ["main-hidden"], for: provider, defaults: defaults)
    precondition(defaults.stringArray(forKey: "enabledModels.\(provider.rawValue)") == [model])
    precondition(EnabledModels.ids(for: provider, storeID: "openai-api-key", defaults: defaults) == [model])
    precondition(EnabledModels.ids(for: provider, storeID: second, defaults: defaults).isEmpty)
    precondition(EnabledModels.customIDs(for: provider, storeID: second, defaults: defaults).isEmpty)
    precondition(EnabledModels.hiddenIDs(for: provider, storeID: second, defaults: defaults).isEmpty)
    EnabledModels.save([model, "second-hidden"], custom: ["second-custom"], hidden: ["second-hidden"],
                       for: provider, storeID: second, defaults: defaults)
    EnabledModels.save(["third-model"], custom: [], hidden: [], for: provider, storeID: third, defaults: defaults)
    let known = EnabledModels.knownModelIDs(defaults: defaults)
    precondition(known[provider.rawValue] == ["main-custom", model].sorted())
    precondition(known[second] == [model, "second-custom"].sorted())
    precondition(known[third] == ["third-model"])
    let selected = EnabledModels.selectedModelIDs(defaults: defaults)
    precondition(selected[provider.rawValue] == [model])
    precondition(selected[second] == [model])

    ModelParameters.save(.init(contextWindow: 10_000, acceptsImages: false), for: provider,
                         model: model, defaults: defaults)
    precondition(ModelParameters.values(for: provider, storeID: second, model: model, defaults: defaults).isEmpty)
    ModelParameters.save(.init(contextWindow: 20_000, acceptsImages: true), for: provider,
                         storeID: second, model: model, defaults: defaults)
    precondition(ModelParameters.values(for: provider, model: model, defaults: defaults).contextWindow == 10_000)
    precondition(ModelParameters.values(for: provider, storeID: second, model: model, defaults: defaults).contextWindow == 20_000)
    precondition(ModelParameters.values(for: provider, model: model, defaults: defaults).acceptsImages == false)

    ModelLimitsStore.save(.init(contextWindow: 30_000, maxOutputTokens: 1000), for: provider,
                          model: model, defaults: defaults)
    precondition(ModelLimitsStore.limits(for: provider, storeID: second, model: model, defaults: defaults) == nil)
    ModelLimitsStore.save(.init(contextWindow: 40_000, maxOutputTokens: 2000), for: provider,
                          storeID: second, model: model, defaults: defaults)
    precondition(ModelLimitsStore.limits(for: provider, model: model, defaults: defaults)?.contextWindow == 30_000)
    precondition(ModelLimitsStore.limits(for: provider, storeID: second, model: model, defaults: defaults)?.contextWindow == 40_000)
    defaults.set("broken-original", forKey: "modelLimits.\(third)")
    ModelLimitsStore.save(.init(contextWindow: 50_000), for: provider, storeID: third, model: model, defaults: defaults)
    precondition(defaults.string(forKey: "modelLimits.\(third).unreadable") == "broken-original")

    AccountNames.save(" 主账号 ", for: provider, storeID: nil, defaults: defaults)
    AccountNames.save(" 工作\n  账号 ", for: provider, storeID: second, defaults: defaults)
    precondition(AccountNames.customName(for: provider, storeID: nil, defaults: defaults) == "主账号")
    precondition(AccountNames.customName(for: provider, storeID: second, defaults: defaults) == "工作 账号")
    AccountNames.save("不应保存", for: .openAICompatible, storeID: nil, defaults: defaults)
    precondition(AccountNames.customName(for: .openAICompatible, storeID: nil, defaults: defaults) == nil)

    EnabledModels.remove(for: provider, storeID: second, defaults: defaults)
    AccountNames.remove(for: provider, storeID: second, defaults: defaults)
    precondition(EnabledModels.ids(for: provider, storeID: second, defaults: defaults).isEmpty)
    precondition(ModelParameters.values(for: provider, storeID: second, model: model, defaults: defaults).isEmpty)
    precondition(ModelLimitsStore.limits(for: provider, storeID: second, model: model, defaults: defaults) == nil)
    precondition(AccountNames.customName(for: provider, storeID: second, defaults: defaults) == nil)
    precondition(EnabledModels.ids(for: provider, defaults: defaults) == [model])
    precondition(EnabledModels.ids(for: provider, storeID: third, defaults: defaults) == ["third-model"])
    precondition(AccountNames.customName(for: provider, storeID: nil, defaults: defaults) == "主账号")
    precondition(ModelParameters.values(for: provider, model: model, defaults: defaults).contextWindow == 10_000)

    // 首兼容端点的旧前缀不能吞掉其他兼容端点的参数。
    let endpoint = AgentProvider.openAICompatibleEndpoint(2)
    ModelParameters.save(.init(maxTokens: 123), for: .openAICompatible, model: model, defaults: defaults)
    ModelParameters.save(.init(maxTokens: 456), for: endpoint, model: model, defaults: defaults)
    EnabledModels.remove(for: .openAICompatible, defaults: defaults)
    precondition(ModelParameters.values(for: .openAICompatible, model: model, defaults: defaults).isEmpty)
    precondition(ModelParameters.values(for: endpoint, model: model, defaults: defaults).maxTokens == 456)

    // 退役账号的额外偏好一并清除，不影响活动账号。
    for key in ["enabledModels.agy#2", "customModels.agy#2", "hiddenModels.agy#2"] {
        defaults.set(["retired"], forKey: key)
    }
    defaults.set([model: ["contextWindow": 1000]], forKey: "modelLimits.agy#2")
    defaults.set(["maxTokens": 100], forKey: "modelParameters.agy#2.\(model)")
    defaults.set("旧账号", forKey: "accountName.agy#2")
    EnabledModels.forgetRetiredProviders(in: defaults)
    for key in ["enabledModels.agy#2", "customModels.agy#2", "hiddenModels.agy#2", "modelLimits.agy#2",
                "modelParameters.agy#2.\(model)", "accountName.agy#2"] {
        precondition(defaults.object(forKey: key) == nil, "未清理退役额外账号：\(key)")
    }
    precondition(EnabledModels.ids(for: provider, defaults: defaults) == [model])
    precondition(ModelParameters.values(for: endpoint, model: model, defaults: defaults).maxTokens == 456)
    print("通过：首账号兼容旧键，额外账号模型、参数、限额、名称及退出清理互不串用")
}
