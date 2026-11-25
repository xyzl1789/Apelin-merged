import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import os

/// 每日签到的实现：从「模型服务商」已登录的 WorkBuddy / WorkBuddy AI /
/// Trae CN / Qoder / Qoder CN 账号领取当天积分。「自动」指的是 App 每天第一次进入前台时问一次，worker
/// 复用当天的缓存，所以同一天再打开不会重复打服务端。
///
/// 接口是逆向得来的私有接口，随时可能变；凭据与响应正文都不进缓存、不进
/// 日志、不回给 App——穿过协议线的只有结果行，失败原因是一枚枚举，由 App
/// 翻成用户的语言。
public enum CheckInService {
    private static let logger = Logger(subsystem: "wiki.qaq.apelin", category: "CheckIn")
    private static let timeoutSeconds = 20
    /// 一段应答的上限，越界即当作「服务端异常」。
    private static let maximumBodyBytes = 1 << 20
    /// Trae CN 领取被限流（9074）时等多久再试。探针里的 30/60/120 秒会把
    /// 设置页拖到几分钟，这里只等两口气就不等了：明天还会再来。
    private static let rateLimitWaits = [0, 5, 15]

    /// 一个平台在这个 keychain 里的 store id，和「模型服务商」用的同一个。
    static func storeID(_ platform: CheckInPlatform) -> String {
        switch platform {
        case .workBuddy: "workbuddy"
        case .workBuddyAI: "workbuddy-ai"
        case .traeCN: "trae"
        case .qoderCN: "qoder-cn"
        case .qoder: "qoder"
        }
    }

    /// 跑一遍：今天问过的平台直接用缓存（`force` 为真时全部重新问）。
    public static func run(
        platforms: [CheckInPlatform],
        force: Bool,
        accounts: [(String, OAuthCredentials)],
        home: URL,
    ) async -> AgentCheckInResponse {
        let folder = ApelinDataRoot(home: home).url.appendingPathComponent("checkin", isDirectory: true)
        let wanted = platforms.isEmpty
            ? CheckInPlatform.allCases
            : CheckInPlatform.allCases.filter(platforms.contains)

        var credentials: [CheckInPlatform: OAuthCredentials] = [:]
        for (id, saved) in accounts {
            for platform in CheckInPlatform.allCases where Self.storeID(platform) == id {
                credentials[platform] = saved
            }
        }

        let today = dayKey()
        let cached = readCache(folder)
        var known: [CheckInPlatform: CheckInResult] = [:]
        if !force, let cached, cached.day == today {
            for result in cached.results { known[result.platform] = result }
        }

        let pending = wanted.filter { known[$0] == nil }
        var fresh: [CheckInResult] = []
        if !pending.isEmpty {
            await withTaskGroup(of: CheckInResult.self) { group in
                for platform in pending {
                    let saved = credentials[platform]
                    group.addTask { await checkOne(platform, credentials: saved) }
                }
                for await result in group { fresh.append(result) }
            }
        }
        for result in fresh { known[result.platform] = result }

        // 只写回被问到的那几个平台，别的平台今天的结果留着。
        var merged: [CheckInResult]
        if var cached, cached.day == today {
            for result in known.values {
                if let index = cached.results.firstIndex(where: { $0.platform == result.platform }) {
                    cached.results[index] = result
                } else {
                    cached.results.append(result)
                }
            }
            merged = cached.results
        } else {
            merged = Array(known.values)
        }
        merged.sort { order($0.platform) < order($1.platform) }
        if !fresh.isEmpty || cached?.day != today {
            writeCache(CacheFile(day: today, results: merged), into: folder)
        }
        logger.info("签到完成：\(merged.map { "\($0.platform.rawValue)=\($0.outcome.rawValue)" }.joined(separator: ","), privacy: .public)")
        return AgentCheckInResponse(results: merged.filter { wanted.contains($0.platform) })
    }

    private static func order(_ platform: CheckInPlatform) -> Int {
        CheckInPlatform.allCases.firstIndex(of: platform) ?? 0
    }

    // MARK: - 单个平台

    private static func checkOne(_ platform: CheckInPlatform, credentials: OAuthCredentials?) async -> CheckInResult {
        guard let credentials else {
            logger.info("\(platform.rawValue, privacy: .public)：未登录")
            return CheckInResult(platform: platform, outcome: .notSignedIn, reason: .signedOut)
        }
        do {
            switch platform {
            case .workBuddy: return try await workBuddy(credentials, platform: .workBuddy)
            case .workBuddyAI: return try await workBuddy(credentials, platform: .workBuddyAI)
            case .traeCN: return try await traeCN(credentials)
            case .qoderCN: return try await qoderCN(credentials, platform: .qoderCN)
            case .qoder: return try await qoderCN(credentials, platform: .qoder)
            }
        } catch let problem as CheckInProblem {
            logger.error("\(platform.rawValue, privacy: .public) 签到失败：\(problem.reason.rawValue, privacy: .public) \(problem.detail, privacy: .public)")
            return CheckInResult(platform: platform, outcome: .failed, reason: problem.reason,
                                 message: String(problem.detail.prefix(160)))
        } catch {
            logger.error("\(platform.rawValue, privacy: .public) 签到异常：\(String(describing: error), privacy: .public)")
            return CheckInResult(platform: platform, outcome: .failed, reason: .server,
                                 message: "网络请求异常")
        }
    }

    // MARK: - WorkBuddy（国内版与国际版同一套接口）

    private static func workBuddy(_ credentials: OAuthCredentials, platform: CheckInPlatform) async throws -> CheckInResult {
        let token = credentials.access
        guard token.count >= 8 else { throw CheckInProblem(.signedOut, "凭据不完整") }
        var headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
        ]
        if let uid = extra(credentials, "uid") { headers["X-User-Id"] = uid }
        if let domain = extra(credentials, "domain") { headers["X-Domain"] = domain }
        // 国内版优先用凭据里的 baseUrl（没有则是默认域名）；国际版用凭据里的
        // domain 拼 https:// ，例如 www.workbuddy.ai。
        let base: String
        if platform == .workBuddyAI {
            if let domain = extra(credentials, "domain"), !domain.isEmpty {
                base = "https://\(domain)"
            } else {
                base = "https://www.workbuddy.ai"
            }
        } else {
            base = extra(credentials, "billingBase")
                ?? extra(credentials, "baseUrl")
                ?? "https://www.codebuddy.cn"
        }
        guard let baseURL = URL(string: base) else { throw CheckInProblem(.server, "base 地址无效") }
        let emptyObject = Data("{}".utf8)

        let status = try await reply(
            method: "POST",
            url: baseURL.appendingPathComponent("v2/billing/meter/checkin-activity-status"),
            headers: headers,
            body: emptyObject,
        )
        guard status.status == 200, let statusJSON = status.json else {
            // 401/403 是登录态失效，提示用户重新登录。
            if status.status == 401 || status.status == 403 {
                throw CheckInProblem(.signedOut, "状态查询 HTTP \(status.status)")
            }
            throw CheckInProblem(.server, "状态查询 HTTP \(status.status)")
        }
        if let code = number(statusJSON["code"]), code != 0 {
            throw CheckInProblem(code == 401 || code == 403 ? .signedOut : .server, "状态查询 code \(code)")
        }
        let data = statusJSON["data"] as? [String: Any] ?? [:]
        let streak = number(data["streak_days"])
        let total = numberText(data["total_credits"])
        let balance = await workBuddyBalance(baseURL: baseURL, headers: headers)
        let todayCredit = numberText(data["today_credit"]) ?? numberText(data["daily_credit"])
        var available = balance?.available
        var used = balance?.used
        // active 为 false 表示当前没有签到活动（国际版常见），不是失败。
        if let active = data["active"] as? Bool, !active {
            logger.info("\(platform.rawValue, privacy: .public)：当前没有签到活动")
            return CheckInResult(platform: platform, outcome: .nothingToDo,
                                 available: available, used: used, total: total, streak: streak,
                                 message: platform == .workBuddyAI ? "WorkBuddy AI 当前没有开放签到活动" : nil)
        }
        if flag(data["today_checked_in"]) {
            logger.info("\(platform.rawValue, privacy: .public)：今天已签到")
            let details = await runGrowthIfNeeded(platform: platform, baseURL: baseURL, headers: headers)
            return CheckInResult(platform: platform, outcome: .alreadyClaimed,
                                 credit: todayCredit, available: available, used: used,
                                 total: total, streak: streak, details: details)
        }

        let claim = try await reply(
            method: "POST",
            url: baseURL.appendingPathComponent("v2/billing/meter/daily-checkin"),
            headers: headers,
            body: emptyObject,
        )
        guard claim.status == 200, let claimJSON = claim.json else {
            throw CheckInProblem(.server, "领取 HTTP \(claim.status)")
        }
        if let code = number(claimJSON["code"]), code != 0 {
            throw CheckInProblem(.rejected, "领取 code \(code)")
        }
        let claimed = claimJSON["data"] as? [String: Any]
        let credit = numberText(claimed?["credit"]) ?? numberText(claimJSON["credit"]) ?? todayCredit
        logger.info("\(platform.rawValue, privacy: .public)：签到成功")

        // 签到之后再跑一遍成长中心：能自动领的都领，做不了的写清原因进明细。
        let details = await runGrowthIfNeeded(platform: platform, baseURL: baseURL, headers: headers)
        let refreshed = await workBuddyBalance(baseURL: baseURL, headers: headers)
        available = refreshed?.available ?? available
        used = refreshed?.used ?? used
        return CheckInResult(platform: platform, outcome: .claimed,
                             credit: credit, available: available, used: used,
                             total: total, streak: streak, details: details)
    }

    /// 只有国内 WorkBuddy 有成长中心；国际版没有这套活动接口。
    private static func runGrowthIfNeeded(platform: CheckInPlatform, baseURL: URL,
                                          headers: [String: String]) async -> [CheckInDetail]? {
        guard platform == .workBuddy else { return nil }
        let growth = await GrowthCenter.run(baseURL: baseURL, headers: headers) { method, path, requestHeaders, body in
            guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
                return Reply(status: 0, json: nil)
            }
            return try await reply(method: method, url: url, headers: requestHeaders ?? [:], body: body)
        }
        for item in growth.details where !item.succeeded {
            logger.info("成长中心待办：\(item.title, privacy: .public) — \(item.note, privacy: .public)")
        }
        return growth.details
    }

    // MARK: - Trae CN

    private static func traeCN(_ credentials: OAuthCredentials) async throws -> CheckInResult {
        let token = credentials.access
        guard token.count >= 8 else { throw CheckInProblem(.signedOut, "凭据不完整") }
        var headers = [
            "Authorization": "Cloud-IDE-JWT \(token)",
            "X-User-Region": "cn",
            "User-Agent": "Trae/2.0.0",
            "Content-Type": "application/json",
        ]
        if let device = digits(extra(credentials, "checkinDeviceId")) ?? digits(extra(credentials, "deviceId")) {
            headers["x-device-id"] = device
        }
        headers["x-device-type"] = extra(credentials, "deviceType") ?? "ios"
        headers["x-os-version"] = extra(credentials, "osVersion") ?? ProcessInfo.processInfo.operatingSystemVersionString
        headers["x-app-version"] = extra(credentials, "appVersion") ?? "2.0.0"
        headers["x-device-brand"] = extra(credentials, "deviceBrand") ?? "iPhone"
        headers["Origin"] = "https://work.trae.cn"
        headers["Referer"] = "https://work.trae.cn/"
        guard let base = URL(string: "https://api.trae.cn/trae/api/v2/ug/checkin_credits") else {
            throw CheckInProblem(.server, "地址无效")
        }
        let body = Data("{\"req_source\":1}".utf8)
        var usage = await traeUsage(token: token, headers: headers)

        let status = try await reply(
            method: "POST",
            url: base.appendingPathComponent("status"),
            headers: headers,
            body: body,
        )
        guard status.status == 200, let statusJSON = status.json else {
            throw CheckInProblem(.server, "状态查询 HTTP \(status.status)")
        }
        let code = number(statusJSON["code"]) ?? 0
        if code == 1001 { throw CheckInProblem(.signedOut, "登录态失效") }
        if code == 9004 || code == 9095 {
            return CheckInResult(platform: .traeCN, outcome: .alreadyClaimed,
                                 available: usage?.available, used: usage?.used,
                                 message: "Trae 今天已签到（业务码 \(code)）")
        }
        if code == 9074 {
            throw CheckInProblem(.rejected, "Trae 风控拒绝：9074，设备号或设备请求头未通过；请使用与账号绑定的真实设备号，并稍后再试")
        }
        if code != 0 { throw CheckInProblem(.server, "Trae 状态查询 code \(code)") }
        if flag(statusJSON["checked_in"]) {
            logger.info("trae-cn：今天已签到")
            return CheckInResult(platform: .traeCN, outcome: .alreadyClaimed,
                                 available: usage?.available, used: usage?.used)
        }

        for wait in rateLimitWaits {
            if wait > 0 {
                if Task.isCancelled { break }
                logger.info("trae-cn：被限流，\(wait, privacy: .public) 秒后重试")
                try? await Task.sleep(nanoseconds: UInt64(wait) * 1_000_000_000)
                if Task.isCancelled { break }
            }
            let claim = try await reply(
                method: "POST",
                url: base.appendingPathComponent("claim"),
                headers: headers,
                body: body,
            )
            guard claim.status == 200, let claimJSON = claim.json else {
                throw CheckInProblem(.server, "领取 HTTP \(claim.status)")
            }
            let claimCode = number(claimJSON["code"]) ?? 0
            if claimCode == 0 {
                let credits = number(claimJSON["credits"]) ?? 0
                let extraCredits = number(claimJSON["extra_credits"]) ?? 0
                let gained = credits + extraCredits
                usage = await traeUsage(token: token, headers: headers)
                logger.info("trae-cn：签到成功")
                return CheckInResult(platform: .traeCN, outcome: .claimed,
                                     credit: gained > 0 ? String(gained) : nil,
                                     available: usage?.available, used: usage?.used)
            }
            if claimCode == 9074 { throw CheckInProblem(.rejected, "Trae 风控拒绝：9074，设备号或设备请求头未通过；请使用与账号绑定的真实设备号，并稍后再试") }
            if claimCode == 1001 { throw CheckInProblem(.signedOut, "登录态失效") }
            if claimCode == 9004 { throw CheckInProblem(.rejected, "设备标识被拒") }
            throw CheckInProblem(.rejected, "领取 code \(claimCode)")
        }
        throw CheckInProblem(.rateLimited, "连续被限流")
    }

    private struct Usage {
        var available: String?
        var used: String?
    }

    private static func workBuddyBalance(baseURL: URL, headers: [String: String]) async -> Usage? {
        guard let reply = try? await reply(method: "POST", url: baseURL.appendingPathComponent("v2/billing/meter/get-user-resource"), headers: headers, body: Data("{}".utf8)),
              reply.status == 200, let root = reply.json else { return nil }
        let accounts = (((root["data"] as? [String: Any])?["Response"] as? [String: Any])?["Data"] as? [String: Any])?["Accounts"] as? [[String: Any]]
            ?? (root["data"] as? [String: Any])?["Accounts"] as? [[String: Any]] ?? []
        guard !accounts.isEmpty else { return nil }
        let values = accounts.reduce(into: (remaining: 0.0, used: 0.0)) { result, account in
            let remain = Double(numberText(account["CapacityRemainPrecise"]) ?? "0") ?? 0
            let cycle = Double(numberText(account["CycleCapacityRemainPrecise"]) ?? "0") ?? 0
            let cycleSize = Double(numberText(account["CycleCapacitySizePrecise"]) ?? "0") ?? 0
            result.remaining += cycleSize > 0 ? min(remain, cycle) : remain
            result.used += Double(numberText(account["CapacityUsedPrecise"]) ?? "0") ?? 0
        }
        return Usage(available: String(Int(values.remaining)), used: String(Int(values.used)))
    }

    private static func traeUsage(token: String, headers: [String: String]) async -> Usage? {
        var requestHeaders = headers
        requestHeaders["User-Agent"] = "Mozilla/5.0"
        requestHeaders["Origin"] = "https://work.trae.cn"
        requestHeaders["Referer"] = "https://work.trae.cn/"
        let body = Data("{\"require_usage\":true,\"req_source\":2}".utf8)
        guard let reply = try? await reply(method: "POST", url: URL(string: "https://api.trae.cn/trae/api/v2/pay/ide_user_ent_usage")!, headers: requestHeaders, body: body),
              reply.status == 200, let root = reply.json,
              let packs = root["user_entitlement_pack_list"] as? [[String: Any]] else { return nil }
        var remaining = 0.0
        var used = 0.0
        var found = false
        for pack in packs {
            let base = pack["entitlement_base_info"] as? [String: Any] ?? [:]
            let quota = base["quota"] as? [String: Any] ?? [:]
            let limit = Double(numberText(quota["credits_limit"]) ?? "0") ?? 0
            guard limit > 0 else { continue }
            let consumed = Double(numberText((pack["usage"] as? [String: Any])?["credits_amount"]) ?? "0") ?? 0
            remaining += max(limit - consumed, 0)
            used += consumed
            found = true
        }
        return found ? Usage(available: String(Int(remaining)), used: String(Int(used))) : nil
    }

    // MARK: - Qoder（国内版与国际版同一套接口）

    private static func qoderCN(_ credentials: OAuthCredentials, platform: CheckInPlatform) async throws -> CheckInResult {
        var token = credentials.access
        guard token.count >= 8 else { throw CheckInProblem(.signedOut, "凭据不完整") }
        var headers = [
            "Accept": "application/json",
            "User-Agent": "Qoder/claim",
            "Cosy-ClientType": "10",
            "Authorization": "Bearer \(token)",
            "Cosy-MachineOS": "arm64_darwin",
            "Cosy-MachineHostname": "iPhone",
        ]
        if let machine = extra(credentials, "machineId") { headers["Cosy-MachineId"] = machine }
        // 国际版的设备风控身份由服务端校验。以前在这里凭 machineToken 做本地拦截，
        // 请求根本没发出就被报成「服务器拒绝」，既挡掉了本可成功的签到，也看不到真实应答。
        // 现在照常请求，被拒时按服务端状态如实报告。
        let baseString = platform == .qoder ? "https://openapi.qoder.sh" : "https://openapi.qoder.com.cn"
        guard let base = URL(string: baseString) else { throw CheckInProblem(.server, "地址无效") }

        guard let campaignsURL = URL(string: base.absoluteString + "/sash/api/v1/me/campaigns?clientType=10") else {
            throw CheckInProblem(.server, "Qoder 活动地址无效")
        }
        var listing = try await reply(
            method: "GET",
            url: campaignsURL,
            headers: headers,
            body: nil,
        )
        if (listing.status == 401 || listing.status == 403), let refreshed = extra(credentials, "refreshToken") {
            if let newToken = try await qoderRefreshToken(base: base, refreshToken: refreshed) {
                token = newToken
                headers["Authorization"] = "Bearer \(newToken)"
                listing = try await reply(method: "GET", url: campaignsURL, headers: headers, body: nil)
            }
        }
        if listing.status == 401 || listing.status == 403 {
            throw CheckInProblem(.signedOut, "活动列表 HTTP \(listing.status)")
        }
        guard listing.status == 200, let listingJSON = listing.json else {
            throw CheckInProblem(.server, "活动列表 HTTP \(listing.status)")
        }
        if let code = listingJSON["code"] as? String,
           code == "TOKEN_EXPIRE" || code == "UNAUTHORIZED" {
            throw CheckInProblem(.signedOut, "登录态失效")
        }
        let campaigns = (listingJSON["campaigns"] as? [[String: Any]]) ?? []
        var usage = await qoderUsage(base: base, headers: headers)
        var claimable: [String] = []
        var claimableBenefits: [String: Int] = [:]
        var claimedBefore = false
        for campaign in campaigns {
            guard (campaign["actionType"] as? String) == "CLAIM_BENEFIT" else { continue }
            let state = (campaign["claimStatus"] as? String) ?? ""
            if state == "CLAIMABLE", let id = campaign["campaignId"] as? String {
                claimable.append(id)
                claimableBenefits[id] = number((campaign["benefit"] as? [String: Any])?["amount"]) ?? 0
            } else if state.uppercased().contains("CLAIMED") {
                claimedBefore = true
            }
        }
        if claimable.isEmpty {
            logger.info("\(platform.rawValue, privacy: .public)：没有可领取的活动")
            return CheckInResult(platform: platform, outcome: claimedBefore ? .alreadyClaimed : .nothingToDo,
                                 available: usage?.available, used: usage?.used)
        }
        var claimed = 0
        var claimedCredit = 0
        var claimFailure: String?
        for id in claimable {
            let path = "sash/api/v1/me/campaigns/\(id)/claim"
            var claimHeaders = headers
            claimHeaders["Content-Type"] = "application/json"
            let claim = try await reply(method: "POST", url: base.appendingPathComponent(path),
                                        headers: claimHeaders, body: Data("{}".utf8))
            if claim.status == 200, let json = claim.json {
                let code = number(json["code"])
                if code == nil || code == 0 {
                    claimed += 1
                    claimedCredit += number(json["amount"]) ?? number((json["benefit"] as? [String: Any])?["amount"]) ?? 0
                } else {
                    claimFailure = "Qoder 领取业务失败：code=\(code!)"
                }
            } else if claim.status != 200 {
                claimFailure = "Qoder 领取 HTTP \(claim.status)"
            }
        }
        guard claimed > 0 else { throw CheckInProblem(.rejected, claimFailure ?? "Qoder 活动领取全部失败") }
        usage = await qoderUsage(base: base, headers: headers)
        logger.info("\(platform.rawValue, privacy: .public)：领取到 \(claimed, privacy: .public) 个活动")
        let claimedAmount = claimedCredit > 0
            ? claimedCredit
            : claimable.reduce(0) { $0 + (claimableBenefits[$1] ?? 0) }
        return CheckInResult(platform: platform, outcome: .claimed,
                             credit: claimedAmount > 0 ? String(claimedAmount) : nil,
                             available: usage?.available, used: usage?.used)
    }

    private static func qoderRefreshToken(base: URL, refreshToken: String) async throws -> String? {
        var request = URLRequest(url: base.appendingPathComponent("api/v1/deviceToken/refresh"), timeoutInterval: TimeInterval(timeoutSeconds))
        request.httpMethod = "POST"
        request.httpBody = Data("{\"refresh_token\":\"\(refreshToken)\"}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let configuration = URLSessionConfiguration.ephemeral
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return (root["device_token"] as? String) ?? (root["token"] as? String)
    }

    private static func qoderUsage(base: URL, headers: [String: String]) async -> Usage? {
        guard let reply = try? await reply(method: "GET", url: base.appendingPathComponent("api/v1/me/usage"), headers: headers, body: nil),
              reply.status == 200, let root = reply.json else { return nil }
        func value(_ key: String) -> String? {
            numberText(root[key]) ?? numberText((root["data"] as? [String: Any])?[key])
        }
        let user = root["user_quota"] as? [String: Any] ?? [:]
        let addon = root["add_on_quota"] as? [String: Any] ?? [:]

        // 只统计真正读到的额度字段；缺字段时按 0 相加会显示假的「余额 0 / 已用 0」。
        func summed(_ key: String) -> (value: Double, found: Bool) {
            var total = 0.0
            var found = false
            for quota in [user, addon] {
                guard let text = numberText(quota[key]), let number = Double(text) else { continue }
                total += number
                found = true
            }
            return (total, found)
        }
        let remaining = summed("remaining")
        let consumed = summed("used")
        var available = remaining.found ? String(Int(remaining.value)) : nil
        var usedText = consumed.found ? String(Int(consumed.value)) : nil

        // 老接口在顶层或 data 里直接给 total/used 时的兜底。
        if available == nil { available = value("total") }
        if usedText == nil { usedText = value("used") }

        guard available != nil || usedText != nil else { return nil }
        return Usage(available: available, used: usedText)
    }

    // MARK: - 网络请求

    /// 成长中心只关心 HTTP 状态和 JSON；这里是 worker 内部的应答形状。
    struct Reply {
        var status: Int
        var json: [String: Any]?
    }

    private static func reply(method: String, url: URL, headers: [String: String], body: Data?) async throws -> Reply {
        var request = URLRequest(url: url, timeoutInterval: TimeInterval(timeoutSeconds))
        request.httpMethod = method
        if let body { request.httpBody = body }
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = TimeInterval(timeoutSeconds)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            throw transportProblem(error)
        }
        defer { bytes.task.cancel() }
        guard let http = response as? HTTPURLResponse else {
            throw CheckInProblem(.server, "响应不可识别")
        }
        var payload = Data()
        do {
            for try await byte in bytes {
                guard payload.count < maximumBodyBytes else {
                    throw CheckInProblem(.server, "响应过大")
                }
                payload.append(byte)
            }
        } catch let problem as CheckInProblem {
            throw problem
        } catch {
            throw transportProblem(error)
        }
        let json = (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
        return Reply(status: http.statusCode, json: json)
    }

    private static func transportProblem(_ error: Error) -> CheckInProblem {
        switch (error as? URLError)?.code {
        case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
             .cannotConnectToHost, .dataNotAllowed, .secureConnectionFailed:
            CheckInProblem(.network, "网络不可用")
        default:
            CheckInProblem(.network, String(describing: error))
        }
    }

    // MARK: - 小工具

    private static func extra(_ credentials: OAuthCredentials, _ key: String) -> String? {
        if case let .string(value)? = credentials.extras[key], !value.isEmpty { return value }
        return nil
    }

    /// 只保留数字并把长度收在 8...20：Trae 的设备标识两头都必须满足。
    private static func digits(_ value: String?) -> String? {
        guard let value else { return nil }
        let digits = value.filter { $0.isASCII && $0.isNumber }
        guard (8 ... 20).contains(digits.count) else { return nil }
        return digits
    }

    private static func number(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: number.intValue
        case let text as String: Int(text)
        default: nil
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let number as NSNumber: number.boolValue
        case let text as String: ["1", "true", "yes"].contains(text.lowercased())
        default: false
        }
    }

    /// 积分可能是数字也可能是字符串，统一成最多 32 字符的文本。
    private static func numberText(_ value: Any?) -> String? {
        let text: String?
        switch value {
        case let number as NSNumber: text = number.stringValue
        case let string as String: text = string
        default: text = nil
        }
        guard let text, !text.isEmpty else { return nil }
        return String(text.prefix(32))
    }

    // MARK: - 缓存

    private struct CacheFile: Codable {
        var day: String
        var results: [CheckInResult]
    }

    private static func cacheURL(_ folder: URL) -> URL {
        folder.appendingPathComponent("cache.json")
    }

    private static func readCache(_ folder: URL) -> CacheFile? {
        guard let data = try? Data(contentsOf: cacheURL(folder)) else { return nil }
        return try? JSONDecoder().decode(CacheFile.self, from: data)
    }

    private static func writeCache(_ cache: CacheFile, into folder: URL) {
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(cache).write(to: cacheURL(folder), options: .atomic)
        } catch {
            logger.error("签到缓存写入失败：\(String(describing: error), privacy: .public)")
        }
    }

    private static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

/// 只在 worker 内部用的失败原因：`reason` 回给 App，`detail` 只进日志。
struct CheckInProblem: Error, Sendable {
    var reason: CheckInReason
    var detail: String

    init(_ reason: CheckInReason, _ detail: String) {
        self.reason = reason
        self.detail = detail
    }
}
