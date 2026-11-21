import Foundation
import Testing
@testable import ApelinAgentWorker
@testable import ApelinKit

/// 中转站余额探测的纯逻辑回归：三类公开响应结构、金额与比例、baseURL
/// 路径规则，以及官方域名必须保持原样。网络请求本身不在此测。
@Suite struct ProviderBalanceRelayTests {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    @Test func `sub2api quota mode exposes remaining and fraction`() {
        let adapter = ProviderBalanceService.relayAdapter(.sub2api)
        let body = data(#"{"isValid":true,"mode":"quota_limited","quota":{"limit":100,"remaining":25.5,"used":74.5}}"#)
        #expect(adapter.recognize(body))
        let figure = try #require(adapter.parse(body))
        #expect(figure.amount == "25.5")
        #expect(figure.unit == "USD")
        #expect(figure.fraction == 0.255)
    }

    @Test func `sub2api unlimited balance has no fraction`() {
        let adapter = ProviderBalanceService.relayAdapter(.sub2api)
        let body = data(#"{"isValid":true,"remaining":-1}"#)
        #expect(adapter.recognize(body))
        let figure = try #require(adapter.parse(body))
        #expect(figure.amount == "-1")
        #expect(figure.fraction == nil)
    }

    @Test func `new api parses granted and available`() {
        let adapter = ProviderBalanceService.relayAdapter(.newAPI)
        let body = data(#"{"data":{"total_granted":50,"total_used":12.5,"total_available":37.5,"unlimited_quota":false}}"#)
        #expect(adapter.recognize(body))
        let figure = try #require(adapter.parse(body))
        #expect(figure.amount == "37.5")
        #expect(figure.unit == "quota")
        #expect(figure.fraction == 0.75)
    }

    @Test func `new api unlimited quota has no fraction`() {
        let adapter = ProviderBalanceService.relayAdapter(.newAPI)
        let body = data(#"{"data":{"unlimited_quota":true,"total_available":999}}"#)
        let figure = try #require(adapter.parse(body))
        #expect(figure.fraction == nil)
    }

    @Test func `openai billing parses hard limit and balance`() {
        let adapter = ProviderBalanceService.relayAdapter(.openAIBilling)
        let body = data(#"{"object":"billing_subscription","hard_limit_usd":120,"balance":30}"#)
        #expect(adapter.recognize(body))
        let figure = try #require(adapter.parse(body))
        #expect(figure.amount == "30")
        #expect(figure.unit == "USD")
        #expect(figure.fraction == 0.25)
    }

    @Test func `unfamiliar response is not recognized by any family`() {
        let body = data(#"{"hello":"world"}"#)
        #expect(!ProviderBalanceService.relayAdapter(.sub2api).recognize(body))
        #expect(!ProviderBalanceService.relayAdapter(.newAPI).recognize(body))
        #expect(!ProviderBalanceService.relayAdapter(.openAIBilling).recognize(body))
    }

    @Test func `relay base strips trailing v1 but keeps path prefix`() {
        let credentials = OAuthCredentials(access: "k", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://relay.example/gw/v1/"),
        ])
        let base = try #require(ProviderBalanceService.baseURL(provider: .openAICompatible, credentials: credentials))
        #expect(base.host == "relay.example")
        #expect(base.isRelay == true)
        #expect(base.root.absoluteString == "https://relay.example/gw")
        let rootPath = base.root.path
        #expect(rootPath + ProviderBalanceService.RelayFamily.sub2api.path == "/gw/v1/usage")
    }

    @Test func `official host keeps its path and is not a relay`() {
        let credentials = OAuthCredentials(access: "k", refresh: "", expires: .max, extras: [
            "baseUrl": .string("https://api.deepseek.com/v1"),
        ])
        let base = try #require(ProviderBalanceService.baseURL(provider: .deepSeek, credentials: credentials))
        #expect(base.isRelay == false)
        #expect(base.root.absoluteString == "https://api.deepseek.com/v1")
    }

    @Test func `relay family display names a family and its path`() {
        #expect(ProviderBalanceService.RelayFamily.sub2api.display.contains("/v1/usage"))
        #expect(ProviderBalanceService.RelayFamily.newAPI.display.contains("New API"))
        #expect(ProviderBalanceService.RelayFamily.openAIBilling.display.contains("billing"))
        #expect(ProviderBalanceService.RelayFamily.tokenQuota.display == "今日 token 配额")
    }

    @Test func `token quota headers give remaining tokens and fraction`() {
        let figure = try #require(ProviderBalanceService.parseTokenQuota([
            "x-quota-limit": "100000000",
            "x-quota-remaining": "80852458",
            "x-quota-used": "19147542",
        ]))
        #expect(figure.amount == "80852458")
        #expect(figure.unit == "tokens")
        #expect(abs((figure.fraction ?? -1) - 0.80852458) < 1e-9)
        #expect(figure.relayKind == "今日 token 配额：100000000")
    }

    @Test func `token quota clamp and malformed headers`() {
        let clamped = try #require(ProviderBalanceService.parseTokenQuota([
            "x-quota-limit": "100", "x-quota-remaining": "-5",
        ]))
        #expect(clamped.amount == "0")
        #expect(clamped.fraction == 0)
        #expect(ProviderBalanceService.parseTokenQuota([
            "x-quota-limit": "100",
        ]) == nil)
        #expect(ProviderBalanceService.parseTokenQuota([
            "x-quota-limit": "oops", "x-quota-remaining": "50",
        ]) == nil)
        #expect(ProviderBalanceService.parseTokenQuota([
            "x-quota-limit": "0", "x-quota-remaining": "50",
        ]) == nil)
    }

    @Test func `token quota family probes models and is last`() {
        #expect(ProviderBalanceService.RelayFamily.tokenQuota.path == "/v1/models")
        #expect(ProviderBalanceService.RelayFamily.allCases.last == .tokenQuota)
    }
}
