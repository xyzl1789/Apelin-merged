import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI

extension UsageProviderIdentity {
    /// 读取实际解析出的配置，不使用模型的通用 openai-compatible 名称推测账户。
    static func resolved(
        from configuration: ProviderConfiguration,
        credentials: OAuthCredentials?,
        model: Model,
    ) -> Self? {
        guard let storeID = configuration.storeID else { return nil }
        let provider: AgentProvider?
        let baseStoreID = AccountIDs.base(of: storeID)
        if let number = CredentialProviderID.endpointNumber(baseStoreID) {
            provider = .openAICompatibleEndpoint(number)
        } else {
            // 统计仍按服务商汇总，但额外账号须能识别其所属服务商。
            provider = AccountIDs.provider(of: storeID, among: AgentProvider.allCases)
        }
        guard let provider else { return nil }
        let base: String
        if case let .string(address)? = credentials?.extras["baseUrl"] {
            base = address
        } else {
            base = model.baseURL
        }
        return Self(accountID: provider.rawValue, endpointHost: host(from: base))
    }
}
