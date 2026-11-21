@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("自建/中转端点的客户端标识", .serialized)
struct CompatibleEndpointUserAgentTests {
    @Test
    func `缺少标识时补上 Minis UA，已有的 User-Agent 原样保留且不重复添加`() {
        let model = Model(id: "m", api: "openai-completions", provider: "openai-compatible")
        let injected = CompatibleEndpointUserAgent.applying(to: model)
        #expect(injected.headers?["User-Agent"]?.hasPrefix("Minis/") == true)
        #expect(injected.headers?["User-Agent"]?.contains("iOS") == true)
        #expect(injected.id == model.id)
        #expect(injected.api == model.api)
        #expect(injected.baseURL == model.baseURL)

        var custom = model
        custom.headers = ["user-agent": "Custom/2.0"]
        let kept = CompatibleEndpointUserAgent.applying(to: custom)
        #expect(kept.headers?["user-agent"] == "Custom/2.0")
        #expect(kept.headers?["User-Agent"] == nil)
    }

    @Test
    func `自定义 User-Agent 非空时替代默认标识，空白时沿用默认`() {
        let model = Model(id: "m", api: "openai-completions", provider: "openai-compatible")
        let custom = CompatibleEndpointUserAgent.applying(to: model, customUserAgent: "claude-cli/1.0 (iOS)")
        #expect(custom.headers?["User-Agent"] == "claude-cli/1.0 (iOS)")

        let blank = CompatibleEndpointUserAgent.applying(to: model, customUserAgent: "   ")
        #expect(blank.headers?["User-Agent"]?.hasPrefix("Minis/") == true)
    }

    @Test
    func `appendV1 去尾部斜杠与重复 v1 并保留查询串`() {
        #expect(ProviderRegistration.appendingV1("https://x.com", enabled: true) == "https://x.com/v1")
        #expect(ProviderRegistration.appendingV1("https://x.com/", enabled: true) == "https://x.com/v1")
        #expect(ProviderRegistration.appendingV1("https://x.com/v1", enabled: true) == "https://x.com/v1")
        #expect(ProviderRegistration.appendingV1("https://x.com/v1/", enabled: true) == "https://x.com/v1")
        #expect(ProviderRegistration.appendingV1("https://x.com/v1", enabled: false) == "https://x.com/v1")
        #expect(
            ProviderRegistration.appendingV1("https://x.openai.azure.com/openai?api-version=2024-10-21", enabled: true)
                == "https://x.openai.azure.com/openai/v1?api-version=2024-10-21"
        )
        #expect(ProviderRegistration.appendingV1("not a url", enabled: true) == nil)
    }
}
