@testable import ApelinAgent
import ApelinCore
import ApelinProtocol
import Foundation
import KWWKAI
import Testing

struct UsageProviderResolutionTests {
    private let model = Model(id: "model", api: "openai-completions", provider: "openai-compatible", baseURL: "https://model.example.invalid/v1")

    @Test func compatibleAccountsKeepTheirOwnIdentifiersDespiteTheSameProtocolAndHost() {
        let credentials = OAuthCredentials(access: "private-key", refresh: "", expires: 0,
                                           extras: ["baseUrl": .string("https://api.xingchiapi.com/v1?token=private-query")])
        let first = UsageProviderIdentity.resolved(from: .openAICompatible(model: "model"), credentials: credentials, model: model)
        let second = UsageProviderIdentity.resolved(from: .stored(storeID: "openai-compatible.2", model: "model"), credentials: credentials, model: model)
        #expect(first == UsageProviderIdentity(accountID: "openAICompatible", endpointHost: "api.xingchiapi.com"))
        #expect(second == UsageProviderIdentity(accountID: "openAICompatible.2", endpointHost: "api.xingchiapi.com"))
        #expect(first != second)
    }

    @Test func nativeAccountsUseTheSameIdentityAsTheirProviderNotes() {
        for provider in AgentProvider.allCases {
            let configuration = ProviderConfiguration.auxiliary(provider: provider, model: "model")
            let identity = UsageProviderIdentity.resolved(from: configuration, credentials: nil, model: model)
            #expect(identity?.accountID == provider.rawValue)
        }
    }

    @Test func allCompatibleSlotsHaveIndependentIdentities() {
        for number in AgentProvider.endpointNumbers {
            let identity = UsageProviderIdentity.resolved(
                from: .stored(storeID: CredentialProviderID.openAICompatibleEndpoint(number), model: "model"),
                credentials: nil, model: model,
            )
            #expect(identity?.accountID == AgentProvider.openAICompatibleEndpoint(number).rawValue)
        }
    }

    @Test func resolvedModelIsTheFallbackForAnAccountWithoutABaseURLExtra() {
        let identity = UsageProviderIdentity.resolved(from: .openAICompatible(model: "model"), credentials: nil, model: model)
        #expect(identity?.endpointHost == "model.example.invalid")
    }

    @Test func invalidEndpointDoesNotWriteAnUnsafeAddress() throws {
        let credentials = OAuthCredentials(access: "private-key", refresh: "private-refresh", expires: 0,
                                           extras: ["baseUrl": .string("not a URL private-data")])
        let identity = try #require(UsageProviderIdentity.resolved(from: .openAICompatible(model: "model"), credentials: credentials, model: model))
        #expect(identity.endpointHost == nil)
        let text = String(decoding: try JSONEncoder().encode(identity), as: UTF8.self)
        #expect(!text.contains("private"))
        #expect(!text.contains("not a URL"))
    }

    @Test func unregisteredTestModelsDoNotGuessAnAccount() {
        #expect(UsageProviderIdentity.resolved(from: .registered(model), credentials: nil, model: model) == nil)
    }
}
