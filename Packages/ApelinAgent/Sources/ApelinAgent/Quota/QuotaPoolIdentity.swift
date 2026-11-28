import CryptoKit
import Foundation
import KWWKAI
import ApelinProtocol

/// 账号额度池的确定性去重标识与官方账单入口。
public enum QuotaPoolIdentity {
    /// 密钥 SHA-256 的前 16 位小写十六进制摘要，不保留或暴露原始密钥。
    public static func keyDigestPrefix16(for secret: String) -> String {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(trimmed.utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    public static func isOAuthSubscription(_ provider: AgentProvider) -> Bool {
        switch provider {
        case .anthropicOAuth, .openAICodex, .githubCopilot, .cursor, .devin, .kiro,
             .qoder, .qoderCN, .workBuddy, .workBuddyAI, .trae, .traeIntl,
             .raccoon, .kimiCoding, .kimiCodingGlobal, .xai:
            true
        case .anthropic, .openAI, .google, .deepSeek, .openRouter,
             .openAICompatible, .openAICompatibleEndpoint, .openCodeGo, .openCodeZen,
             .zai, .zaiCodingCN:
            false
        }
    }

    /// API 密钥按摘要共享额度池；OAuth 订阅按存储实例标识。
    public static func poolID(provider: AgentProvider, storeID: String, credentials: OAuthCredentials, usesAPIKey: Bool) -> String {
        if usesAPIKey || !isOAuthSubscription(provider) {
            return "key:\(keyDigestPrefix16(for: credentials.access))"
        }
        return "oauth:\(storeID)"
    }

    /// 规范化端点，用于 24 小时探测缓存和熔断；不含用户信息、查询参数或密钥。
    public static func normalizedEndpointKey(baseURL: String) -> String? {
        guard let components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty
        else { return nil }
        let port = components.port.map { ":\($0)" } ?? ""
        return "\(scheme)://\(host)\(port)\(stripTrailingSlashAndV1(components.path))"
    }

    /// 去掉末尾斜杠和 `/v1`，得到中转探测根路径。
    public static func stripTrailingSlashAndV1(_ path: String) -> String {
        var result = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while result.hasSuffix("/") { result.removeLast() }
        if result.lowercased().hasSuffix("/v1") {
            result.removeLast(3)
            while result.hasSuffix("/") { result.removeLast() }
        }
        return result
    }

    public static func normalizedRelayRootURL(from baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "https" || scheme == "http",
              let host = components.host, !host.isEmpty
        else { return nil }
        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        components.path = stripTrailingSlashAndV1(components.path)
        return components.url
    }

    /// 提供商固定的官方账单或用量控制台。
    public static func billingURL(for provider: AgentProvider, baseURL: String? = nil) -> URL? {
        if let baseURL, let host = URLComponents(string: baseURL)?.host?.lowercased() {
            switch host {
            case "api.deepseek.com": return URL(string: "https://platform.deepseek.com/usage")
            case "api.moonshot.cn": return URL(string: "https://platform.moonshot.cn/console/account")
            case "api.moonshot.ai": return URL(string: "https://platform.moonshot.ai/console/account")
            case "api.siliconflow.cn": return URL(string: "https://cloud.siliconflow.cn/account/ak")
            case "api.siliconflow.com": return URL(string: "https://cloud.siliconflow.com/account/ak")
            case "openrouter.ai": return URL(string: "https://openrouter.ai/settings/credits")
            default: break
            }
        }
        switch provider {
        case .openAI: return URL(string: "https://platform.openai.com/settings/organization/billing/overview")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/billing")
        case .anthropicOAuth: return URL(string: "https://claude.ai/settings/usage")
        case .openAICodex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .google: return URL(string: "https://aistudio.google.com/spend")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/usage")
        case .openRouter: return URL(string: "https://openrouter.ai/settings/credits")
        case .githubCopilot: return URL(string: "https://github.com/settings/copilot")
        case .cursor: return URL(string: "https://cursor.com/dashboard?tab=billing")
        case .devin: return URL(string: "https://app.devin.ai/settings/billing")
        case .kiro: return URL(string: "https://app.kiro.dev/account")
        case .qoder: return URL(string: "https://qoder.com/account")
        case .qoderCN: return URL(string: "https://qoder.cn/account")
        case .workBuddy: return URL(string: "https://copilot.tencent.com")
        case .workBuddyAI: return URL(string: "https://www.codebuddy.ai")
        case .trae: return URL(string: "https://www.trae.com.cn/account")
        case .traeIntl: return URL(string: "https://www.trae.ai/account")
        case .raccoon: return URL(string: "https://xiaohuanxiong.com")
        case .kimiCoding: return URL(string: "https://www.kimi.com/code/console")
        case .kimiCodingGlobal: return URL(string: "https://www.kimi.ai/code/console")
        case .xai: return URL(string: "https://console.x.ai")
        case .zai: return URL(string: "https://z.ai/manage-apikey/subscription")
        case .zaiCodingCN: return URL(string: "https://bigmodel.cn/usercenter/proj-mgmt/rate-limits")
        case .openCodeGo, .openCodeZen: return URL(string: "https://opencode.ai/auth")
        case .openAICompatible, .openAICompatibleEndpoint: return nil
        }
    }
}
