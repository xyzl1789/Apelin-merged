import ApelinProtocol
import Foundation
import KWWKAI

/// 账号的凭据存储标识：首账号沿用原标识，额外账号使用规范的 #2 到 #9 后缀。
/// 原有登录无需迁移；不同账号的刷新与请求始终读取自己的凭据。
public enum AccountIDs {
    public static let maximum = AgentAccountID.maximum

    public static func extra(_ provider: AgentProvider, _ number: Int) -> String {
        AgentAccountID.extra(provider.storeID, number)
    }

    public static func resolved(_ accountID: String?, for provider: AgentProvider) -> String {
        guard let accountID, !accountID.isEmpty else { return provider.storeID }
        return accountID
    }

    public static func number(of accountID: String) -> Int? {
        AgentAccountID.number(of: accountID)
    }

    public static func base(of accountID: String) -> String {
        AgentAccountID.base(of: accountID)
    }

    /// 只接受本服务商的首账号或规范后缀，拒绝前导零、嵌套后缀与跨服务商访问。
    public static func belongs(_ accountID: String, to provider: AgentProvider) -> Bool {
        if accountID == provider.storeID { return true }
        guard let number = number(of: accountID) else { return false }
        return accountID == extra(provider, number)
    }

    public static func provider(of accountID: String, among providers: [AgentProvider]) -> AgentProvider? {
        providers.first { belongs(accountID, to: $0) }
    }

    public static func next(for provider: AgentProvider, taken: Set<String>) -> String? {
        AgentAccountID.next(base: provider.storeID, taken: taken)
    }
}

/// 复用服务商的刷新流程，但将结果绑定在额外账号自己的存储标识上。
public struct AccountRefresher: OAuthProvider {
    public let base: any OAuthProvider
    public let id: String
    public var name: String { base.name }

    public init(base: any OAuthProvider, id: String) {
        self.base = base
        self.id = id
    }

    public func refresh(_ credentials: OAuthCredentials, using client: HTTPClient) async throws -> OAuthCredentials {
        try await base.refresh(credentials, using: client)
    }

    public func apiKey(from credentials: OAuthCredentials, using client: HTTPClient) async throws -> String {
        try await base.apiKey(from: credentials, using: client)
    }
}
