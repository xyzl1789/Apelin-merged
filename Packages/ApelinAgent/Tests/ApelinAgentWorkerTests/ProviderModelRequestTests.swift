@testable import ApelinAgentWorker
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite("兼容端点的模型列表请求")
struct ProviderModelRequestTests {
    private func credentials(baseURL: String, appendV1: String?) -> OAuthCredentials {
        var extras: [String: JSONValue] = [
            AgentSignInField.baseURL.rawValue: .string(baseURL),
            AgentSignInField.defaultModel.rawValue: .string("m"),
        ]
        if let appendV1 { extras[AgentSignInField.appendV1.rawValue] = .string(appendV1) }
        return OAuthCredentials(access: "sk-test", refresh: "", expires: .max, extras: extras)
    }

    @Test
    func `默认自动附加 v1 且只拼一次 models`() {
        let request = ProviderModels.modelRequest(
            .openAICompatible,
            credentials: credentials(baseURL: "https://llm.example.invalid", appendV1: nil),
        )
        #expect(request?.url?.path == "/v1/models")
    }

    @Test
    func `地址已含 v1 时不重复追加`() {
        let request = ProviderModels.modelRequest(
            .openAICompatible,
            credentials: credentials(baseURL: "https://llm.example.invalid/v1", appendV1: "true"),
        )
        #expect(request?.url?.path == "/v1/models")
    }

    @Test
    func `关闭自动附加时按填写的路径访问`() {
        let request = ProviderModels.modelRequest(
            .openAICompatible,
            credentials: credentials(baseURL: "https://llm.example.invalid/custom", appendV1: "false"),
        )
        #expect(request?.url?.path == "/custom/models")
    }
}
