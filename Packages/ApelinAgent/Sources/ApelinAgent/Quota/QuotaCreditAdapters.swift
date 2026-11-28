import ApelinProtocol
import Foundation
import KWWKAI

extension QuotaAdapters {
    /// 计费地址与签到保持一致；账号头由依赖按个人/企业身份生成。
    public static func workBuddyBillingBase(provider: AgentProvider, credentials: OAuthCredentials) -> URL? {
        func text(_ key: String) -> String? {
            guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
            return value
        }
        let defaultBase = provider == .workBuddyAI ? "https://www.workbuddy.ai" : "https://www.codebuddy.cn"
        let base = text("billingBase") ?? (provider == .workBuddyAI
            ? text("domain").map { "https://" + $0 } : text("baseUrl")) ?? defaultBase
        guard var components = URLComponents(string: base), components.scheme == "https",
              components.host?.isEmpty == false, components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else { return nil }
        if components.path == "/v2" || components.path == "/v2/" { components.path = "" }
        return components.url
    }

    static func queryWorkBuddy(poolID: String, provider: AgentProvider, accountLabel: String?, credentials: OAuthCredentials, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        guard let base = workBuddyBillingBase(provider: provider, credentials: credentials) else { throw QuotaAdapterError.invalidResponse }
        let site: WorkBuddySite = provider == .workBuddyAI ? .international : .china
        var headers = WorkBuddyOAuth.accountHeaders(credentials, site: site)
        headers["Authorization"] = "Bearer \(credentials.access)"
        headers["User-Agent"] = WorkBuddyOAuth.userAgent
        headers["X-Product"] = "SaaS"
        headers["X-IDE-Type"] = "WorkBuddy"
        headers["X-Requested-With"] = "XMLHttpRequest"
        headers["Origin"] = base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        headers["Referer"] = base.absoluteString
        // 积分包明细在网页计费站点，不在聊天网关；仅不支持旧资源接口时才用摘要。
        var packages: [AgentQuotaBalance] = []
        do {
            for page in 1...20 {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                let body: [String: Any] = ["PageNumber": page, "PageSize": 100, "ProductCode": "p_tcaca", "Status": [0, 3],
                    "PackageEndTimeRangeBegin": formatter.string(from: now),
                    "PackageEndTimeRangeEnd": formatter.string(from: now.addingTimeInterval(3_185_136_000))]
                var request = creditRequest(url: base.appendingPathComponent("v2/billing/meter/get-user-resource"), headers: headers, body: "{}")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
                let data = try await sendChecked(request, transport: transport)
                let rows = try workBuddyAccounts(data)
                let parsed = try parseWorkBuddyCredits(data, now: now)
                packages += parsed.enumerated().map { index, value in
                    var value = value
                    value.id = "workbuddy-package:\(page):\(index)"
                    return value
                }
                if rows.count < 100 {
                    return creditSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, packages: packages, now: now)
                }
            }
            // 页数越界也不能把部分包伪装成完整余额。
            throw QuotaAdapterError.undecodable
        } catch let error as QuotaAdapterError {
            guard packages.isEmpty else { throw error }
            switch error {
            case .endpointUnsupported, .undecodable: break
            default: throw error
            }
        }
        let summaryURL = URL(string: site.endpoint)!.appendingPathComponent("billing/meter/get-user-resource-summary")
        let data = try await sendChecked(creditRequest(url: summaryURL, headers: headers, body: "{}"), transport: transport)
        let summaryPackages = try parseWorkBuddyCredits(data, now: now)
        return creditSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, packages: summaryPackages, now: now)
    }

    /// 只解析明确的积分计数。任一明细不可读就拒绝合计，避免把部分包当成总余额。
    static func parseWorkBuddyCredits(_ data: Data, now: Date) throws -> [AgentQuotaBalance] {
        let root = try creditEnvelope(data)
        let payload = (root["data"] as? [String: Any]) ?? root
        let response = (payload["Response"] as? [String: Any]) ?? payload
        if response["Error"] as? [String: Any] != nil { throw QuotaAdapterError.undecodable }
        let content = (response["Data"] as? [String: Any]) ?? response
        if let packages = content["Packages"] as? [[String: Any]] {
            return try packages.enumerated().compactMap { index, package in
                let expires = creditExpiry(package, keys: ["ExpireTime", "ExpireAt", "ExpirationTime", "EndTime"])
                if let expires, expires <= now { return nil }
                let total = try creditNumber(package["CycleTotalCapacity"])
                let used = try creditNumber(package["CycleUsedCapacity"])
                let remaining = try creditNumber(package["CycleRemainCapacity"])
                let counts = try creditCounts(total: total, used: used, remaining: remaining)
                return AgentQuotaBalance(id: "workbuddy-package:\(index)", unitLabel: "积分", isAvailable: counts.remaining > 0,
                    total: counts.total, used: counts.used, remaining: counts.remaining,
                    label: creditLabel(package, keys: ["PackageName", "Name", "ResourceName"]), expiresAt: expires)
            }
        }
        let accounts = try workBuddyAccounts(data)
        return try accounts.enumerated().compactMap { index, account in
            let expires = creditExpiry(account, keys: ["PackageEndTime", "EndTime", "ExpireTime", "expireAt", "ExpiredTime", "InvalidTime"])
            if let expires, expires <= now { return nil }
            let cycleSize = try workBuddyCount(account, "CycleCapacitySize")
            let isCycle = (cycleSize ?? 0) > 0
            let total: Decimal?
            if isCycle { total = cycleSize }
            else { total = try workBuddyCount(account, "CapacitySize") }
            let used = try workBuddyCount(account, isCycle ? "CycleCapacityUsed" : "CapacityUsed")
            let remain = try workBuddyCount(account, isCycle ? "CycleCapacityRemain" : "CapacityRemain")
            let counts = try creditCounts(total: total, used: used, remaining: remain)
            var remaining = counts.remaining
            if isCycle, let overall = try workBuddyCount(account, "CapacityRemain") {
                remaining = min(remaining, overall)
            }
            return AgentQuotaBalance(id: "workbuddy-package:\(index)", unitLabel: "积分", isAvailable: remaining > 0,
                total: counts.total, used: counts.used, remaining: remaining,
                label: creditLabel(account, keys: ["PackageName", "Name", "ResourceName"]), expiresAt: expires)
        }
    }

    private static func workBuddyAccounts(_ data: Data) throws -> [[String: Any]] {
        let root = try creditEnvelope(data)
        let payload = (root["data"] as? [String: Any]) ?? root
        let response = (payload["Response"] as? [String: Any]) ?? payload
        if response["Error"] != nil { throw QuotaAdapterError.undecodable }
        let content = (response["Data"] as? [String: Any]) ?? response
        guard let accounts = content["Accounts"] as? [[String: Any]] else { throw QuotaAdapterError.undecodable }
        return accounts
    }

    static func queryTraeCN(poolID: String, provider: AgentProvider, accountLabel: String?, credentials: OAuthCredentials, transport: any QuotaHTTPTransport, now: Date) async throws -> AgentQuotaSnapshot {
        let headers = [
            "Authorization": "Cloud-IDE-JWT \(credentials.access)", "X-User-Region": "cn",
            "User-Agent": "Mozilla/5.0", "Origin": "https://work.trae.cn", "Referer": "https://work.trae.cn/",
        ]
        let request = creditRequest(url: URL(string: "https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage")!,
            headers: headers, body: "{\"require_usage\":true,\"req_source\":2}")
        let data = try await sendChecked(request, transport: transport)
        let root = try creditEnvelope(data)
        guard let packs = root["user_entitlement_pack_list"] as? [[String: Any]] else { throw QuotaAdapterError.undecodable }
        let packages = try packs.enumerated().compactMap { index, pack -> AgentQuotaBalance? in
            guard let base = pack["entitlement_base_info"] as? [String: Any],
                  let quota = base["quota"] as? [String: Any] else { throw QuotaAdapterError.undecodable }
            let expires = creditExpiry(base, keys: ["expire_time", "expire_at", "end_time"])
            if let expires, expires <= now { return nil }
            // 非积分权益不纳入积分总量；积分权益缺少用量时不能假定它尚未消耗。
            guard let total = try creditNumber(quota["credits_limit"]) else { return nil }
            guard let used = try creditNumber((pack["usage"] as? [String: Any])?["credits_amount"]) else { throw QuotaAdapterError.undecodable }
            return AgentQuotaBalance(id: "trae-package:\(index)", unitLabel: "积分", isAvailable: total > used,
                total: total, used: used, remaining: max(0, total - used),
                label: creditLabel(base, keys: ["name", "entitlement_name"]), expiresAt: expires)
        }
        return creditSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, packages: packages, now: now)
    }

    private static func creditRequest(url: URL, headers: [String: String], body: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.allHTTPHeaderFields = headers
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        return request
    }

    private static func creditEnvelope(_ data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw QuotaAdapterError.undecodable }
        if let raw = root["code"] {
            guard let code = intValue(raw) else { throw QuotaAdapterError.undecodable }
            if code == 401 || code == 403 || code == 1001 { throw QuotaAdapterError.unauthorized }
            if code != 0 { throw QuotaAdapterError.httpStatus(200, summary: "积分查询被服务端拒绝（业务码 \(code)）。") }
        }
        return root
    }

    private static func creditNumber(_ value: Any?) throws -> Decimal? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
        guard let decimal = decimalValue(value), decimal >= 0 else { throw QuotaAdapterError.undecodable }
        return decimal
    }

    private static func workBuddyCount(_ account: [String: Any], _ field: String) throws -> Decimal? {
        if let precise = try creditNumber(account[field + "Precise"]) { return precise }
        return try creditNumber(account[field])
    }

    private static func creditCounts(total: Decimal?, used: Decimal?, remaining: Decimal?) throws -> (total: Decimal, used: Decimal, remaining: Decimal) {
        guard let total = total ?? used.flatMap({ used in remaining.map { used + $0 } }),
              let used = used ?? remaining.map({ total - $0 }), used >= 0
        else { throw QuotaAdapterError.undecodable }
        let remaining = remaining ?? max(0, total - used)
        guard remaining >= 0, remaining <= total else { throw QuotaAdapterError.undecodable }
        return (total, used, remaining)
    }

    private static func creditExpiry(_ object: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let date = parseTimestamp(object[key]) { return date }
            if let text = object[key] as? String {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                if let date = formatter.date(from: text) { return date }
            }
        }
        return nil
    }

    private static func creditLabel(_ object: [String: Any], keys: [String]) -> String? {
        keys.lazy.compactMap { (object[$0] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
    }

    private static func creditSnapshot(poolID: String, provider: AgentProvider, accountLabel: String?, packages: [AgentQuotaBalance], now: Date) -> AgentQuotaSnapshot {
        let total = packages.reduce(Decimal(0)) { $0 + ($1.total ?? 0) }
        let used = packages.reduce(Decimal(0)) { $0 + ($1.used ?? 0) }
        let remaining = packages.reduce(Decimal(0)) { $0 + ($1.remaining ?? 0) }
        let balance = AgentQuotaBalance(id: "credits", unitLabel: "积分", isAvailable: remaining > 0, total: total, used: used, remaining: remaining)
        return AgentQuotaSnapshot(poolID: poolID, provider: provider, accountLabel: accountLabel, kind: .balance,
            source: .activeAPI, status: remaining > 0 ? .available : .exhausted, balances: [balance], creditPackages: packages,
            billingURL: QuotaPoolIdentity.billingURL(for: provider), updatedAt: now)
    }
}
