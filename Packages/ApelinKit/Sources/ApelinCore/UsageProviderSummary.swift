import Foundation

/// 只保存配置实例标识与域名；不保存 API Key、URL 路径、查询参数或登录信息。
public struct UsageProviderIdentity: Codable, Sendable, Equatable, Hashable {
    /// 与模型服务商备注使用同一个实例标识（AgentProvider.rawValue）。
    public var accountID: String
    public var endpointHost: String?

    public init(accountID: String, endpointHost: String? = nil) {
        self.accountID = accountID
        self.endpointHost = endpointHost
    }

    public static func host(from address: String) -> String? {
        guard let url = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return host.lowercased()
    }

    /// 自定义端点的槽位号不因列表排序、备注或记录数量变化而改变。
    fileprivate var marker: String {
        if accountID == "openAICompatible" { return "1" }
        let prefix = "openAICompatible."
        if accountID.hasPrefix(prefix),
           let number = Int(accountID.dropFirst(prefix.count)), (2 ... 99).contains(number),
           accountID == prefix + String(number) { return String(number) }
        return accountID
    }
}

/// 设置和会话统计使用同一套分组、命名与重名消歧规则。
public struct UsageProviderSummary: Sendable, Equatable {
    public var identity: UsageProviderIdentity?
    public var name: String
    public var count: Int
    public var input: Int
    public var output: Int

    private enum Key: Hashable {
        case legacy(String?)
        case account(UsageProviderIdentity)
    }

    /// titles 只包含本机备注或内置服务商名称，绝不参与分组。
    /// 不带 identity 的旧记录仍按原 provider 汇总，不迁移、不推测归属。
    public static func summarize(
        _ records: [UsageRecord],
        titles: [String: String] = [:],
        unknown: String,
        includingCache: Bool = false,
    ) -> [Self] {
        summarize(records.map { UsageRollup(record: $0) }, titles: titles, unknown: unknown, includingCache: includingCache)
    }

    /// 累计行已经合并 token，只对请求次数使用 count，不能再将 token 乘次数。
    public static func summarize(
        _ rollups: [UsageRollup],
        titles: [String: String] = [:],
        unknown: String,
        includingCache: Bool = false,
    ) -> [Self] {
        var groups: [Key: Self] = [:]
        var latest: [Key: Date] = [:]
        for rollup in rollups {
            let record = rollup.record
            let identity = record.providerIdentity
            let key = identity.map(Key.account) ?? .legacy(record.provider)
            let fallback = nonempty(record.provider) ?? unknown
            let name: String
            if let identity {
                name = nonempty(titles[identity.accountID]) ?? nonempty(identity.endpointHost) ?? fallback
            } else {
                name = record.provider ?? unknown
            }
            var entry = groups[key] ?? Self(identity: identity, name: name, count: 0, input: 0, output: 0)
            if latest[key].map({ record.time >= $0 }) ?? true {
                entry.name = name
                latest[key] = record.time
            }
            entry.count += rollup.count
            entry.input += record.input + (includingCache ? record.cacheRead + record.cacheWrite : 0)
            entry.output += record.output
            groups[key] = entry
        }

        let duplicateNames = Dictionary(grouping: groups.values, by: \.name)
        let duplicateAccounts = Dictionary(grouping: groups.values.compactMap(\.identity), by: \.accountID)
        for (key, value) in groups {
            var entry = value
            guard let identity = entry.identity else { continue }
            if (duplicateNames[entry.name]?.count ?? 0) > 1 {
                // 一个槽位换过域名时也不合并到旧端点；备注重名则保留域名帮助辨认。
                if (duplicateAccounts[identity.accountID]?.count ?? 0) > 1,
                   let host = nonempty(identity.endpointHost) {
                    entry.name += " · " + host
                }
                entry.name += " · " + identity.marker
            } else if nonempty(identity.endpointHost) == nil, nonempty(titles[identity.accountID]) == nil {
                // 无备注且域名无效时，也不能只留一个无法辨认的通用名称。
                entry.name += " · " + identity.marker
            }
            groups[key] = entry
        }
        // 即使备注恰好等于任何生成的名称，也不会重复；先保留旧记录名称。
        var usedNames = Set(groups.values.filter { $0.identity == nil }.map(\.name))
        let accounts = groups.filter { $0.value.identity != nil }.sorted {
            let left = $0.value.identity!
            let right = $1.value.identity!
            if left.accountID != right.accountID { return left.accountID < right.accountID }
            return (left.endpointHost ?? "") < (right.endpointHost ?? "")
        }
        for (key, value) in accounts {
            var entry = value
            guard let identity = entry.identity else { continue }
            let suffix = " [" + identity.accountID + (identity.endpointHost.map { "@" + $0 } ?? "") + "]"
            while !usedNames.insert(entry.name).inserted { entry.name += suffix }
            groups[key] = entry
        }
        return groups.values.sorted {
            let left = $0.input + $0.output
            let right = $1.input + $1.output
            if left != right { return left > right }
            if $0.name != $1.name { return $0.name < $1.name }
            return ($0.identity?.accountID ?? "") < ($1.identity?.accountID ?? "")
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
