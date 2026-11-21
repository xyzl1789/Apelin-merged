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
}
