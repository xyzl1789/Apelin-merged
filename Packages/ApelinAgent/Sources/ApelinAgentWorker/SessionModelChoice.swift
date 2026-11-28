import ApelinProtocol

/// 会话当前的模型及账号选择；派生会话继承相同的凭据身份，不携带任何密钥。
public actor SessionModelChoice {
    public struct Choice: Sendable, Equatable {
        public var provider: AgentProvider?
        public var model: String?
        public var reasoningEffort: AgentReasoningEffort?
        public var serviceTier: AgentServiceTier?
        public var modelParameters: AgentModelParameters?
        public var modelLimits: AgentModelLimits?
        public var accountID: String?
    }

    public private(set) var current = Choice()
    public private(set) var defaults: AgentModelDefaults?

    public func setDefaults(_ defaults: AgentModelDefaults?) {
        self.defaults = defaults
    }

    public init(
        provider: AgentProvider? = nil,
        model: String? = nil,
        reasoningEffort: AgentReasoningEffort? = nil,
        serviceTier: AgentServiceTier? = nil,
        modelParameters: AgentModelParameters? = nil,
        modelLimits: AgentModelLimits? = nil,
        accountID: String? = nil,
    ) {
        current = Choice(
            provider: provider, model: model,
            reasoningEffort: reasoningEffort, serviceTier: serviceTier,
            modelParameters: modelParameters, modelLimits: modelLimits,
            accountID: accountID,
        )
    }

    public func set(
        provider: AgentProvider?,
        model: String?,
        reasoningEffort: AgentReasoningEffort?,
        serviceTier: AgentServiceTier?,
        modelParameters: AgentModelParameters? = nil,
        modelLimits: AgentModelLimits? = nil,
        accountID: String? = nil,
    ) {
        current = Choice(
            provider: provider, model: model,
            reasoningEffort: reasoningEffort, serviceTier: serviceTier,
            modelParameters: modelParameters, modelLimits: modelLimits,
            accountID: accountID,
        )
    }
}
