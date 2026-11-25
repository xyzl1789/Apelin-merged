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
        if let number = CredentialProviderID.endpointNumber(storeID) {
            provider = .openAICompatibleEndpoint(number)
        } else {
            // 复用已有的协议→凭据映射，避免统计单独维护另一份服务商列表。
            provider = AgentProvider.allCases.first {
                ProviderConfiguration.auxiliary(provider: $0, model: model.id).storeID == storeID
            }
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
