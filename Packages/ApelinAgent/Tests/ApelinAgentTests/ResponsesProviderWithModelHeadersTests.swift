@testable import ApelinAgent
import Foundation
import KWWKAI
import Testing

@Suite("Responses 传输的模型请求头", .serialized)
struct ResponsesProviderWithModelHeadersTests {
    private func model(headers: [String: String]?) -> Model {
        var model = Model(id: "m", api: "openai-responses", provider: "openai-compatible")
        model.headers = headers
        return model
    }

    @Test
    func `模型头在没有调用方请求头时进入 StreamOptions`() {
        let options = ResponsesProviderWithModelHeaders.options(
            model: model(headers: ["User-Agent": "Minis/1.0 (iOS 16.3.1; iPhone)"]),
            adding: nil,
        )
        #expect(options?.headers?["User-Agent"] == "Minis/1.0 (iOS 16.3.1; iPhone)")
    }

    @Test
    func `调用方请求头优先，模型的头只补缺且大小写不敏感`() {
        let caller = StreamOptions(headers: ["user-agent": "Caller/9", "x-trace": "t"])
        let options = ResponsesProviderWithModelHeaders.options(
            model: model(headers: ["User-Agent": "Minis/1.0", "api-key": "k"]),
            adding: caller,
        )
        #expect(options?.headers?["user-agent"] == "Caller/9")
        #expect(options?.headers?["User-Agent"] == nil)
        #expect(options?.headers?["x-trace"] == "t")
        #expect(options?.headers?["api-key"] == "k")
    }

    @Test
    func `模型没有请求头时原样返回调用方的 options`() {
        #expect(ResponsesProviderWithModelHeaders.options(model: model(headers: nil), adding: nil) == nil)
        let caller = StreamOptions(maxTokens: 32)
        let kept = ResponsesProviderWithModelHeaders.options(model: model(headers: [:]), adding: caller)
        #expect(kept?.maxTokens == 32)
        #expect(kept?.headers == nil)
    }
}
