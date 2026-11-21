@testable import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

@Suite("图像生成端点设置")
struct ImageEndpointOptionsTests {
    private func credentials(_ extras: [String: JSONValue]) -> OAuthCredentials {
        OAuthCredentials(access: "sk-test", refresh: "", expires: .max, extras: extras)
    }

    @Test
    func `没有凭据时用默认 auto 与默认 UA`() {
        let options = NativeImageGeneration.ImageOptions.from(credentials: nil)
        #expect(options.mode == .auto)
        #expect(options.customUserAgent == nil)
        #expect(options.azure == false)
        #expect(options.appendV1 == true)
    }

    @Test
    func `从 extras 读取三档模式与开关`() {
        let c = credentials([
            AgentSignInField.imageEndpointMode.rawValue: .string("chat_completions"),
            AgentSignInField.customUserAgent.rawValue: .string("Codex/1.0"),
            AgentSignInField.azure.rawValue: .string("true"),
            AgentSignInField.appendV1.rawValue: .string("false"),
        ])
        let options = NativeImageGeneration.ImageOptions.from(credentials: c)
        #expect(options.mode == .chatCompletions)
        #expect(options.customUserAgent == "Codex/1.0")
        #expect(options.azure == true)
        #expect(options.appendV1 == false)
    }

    @Test
    func `无效模式回退到 auto`() {
        let c = credentials([AgentSignInField.imageEndpointMode.rawValue: .string("bogus")])
        #expect(NativeImageGeneration.ImageOptions.from(credentials: c).mode == .auto)
    }
}
