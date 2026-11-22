import ApelinAgent
import ApelinProtocol
import Foundation
import KWWKAI
import os

/// 每日签到的实现：从「模型服务商」已登录的 WorkBuddy / Trae CN / Qoder CN
/// 账号领取当天积分。「自动」指的是 App 每天第一次进入前台时问一次，worker
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
        case .traeCN: "trae"
        case .qoderCN: "qoder-cn"
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

    // MARK: - One platform

    private static func checkOne(_ platform: CheckInPlatform, credentials: OAuthCredentials?) async -> CheckInResult {
        guard let credentials else {
            logger.info("\(platform.rawValue, privacy: .public)：未登录")
            return CheckInResult(platform: platform, outcome: .notSignedIn, reason: .signedOut)
        }
        do {
            switch platform {
            case .workBuddy: return try await workBuddy(credentials)
            case .traeCN: return try await traeCN(credentials)
            case .qoderCN: return try await qoderCN(credentials)
            }
        } catch let problem as CheckInProblem {
            logger.error("\(platform.rawValue, privacy: .public) 签到失败：\(problem.reason.rawValue, privacy: .public) \(problem.detail, privacy: .public)")
            return CheckInResult(platform: platform, outcome: .failed, reason: problem.reason)
        } catch {
            logger.error("\(platform.rawValue, privacy: .public) 签到异常：\(String(describing: error), privacy: .public)")
            return CheckInResult(platform: platform, outcome: .failed, reason: .server)
        }
    }

    // MARK: - WorkBuddy

    private static func workBuddy(_ credentials: OAuthCredentials) async throws -> CheckInResult {
        let token = credentials.access
        guard token.count >= 8 else { throw CheckInProblem(.signedOut, "凭据不完整") }
        var headers = [
            "Authorization": "Bearer \(token)",
            "Content-Type": "application/json",
        ]
        if let uid = extra(credentials, "uid") { headers["X-User-Id"] = uid }
        if let domain = extra(credentials, "domain") { headers["X-Domain"] = domain }
        let base = extra(credentials, "baseUrl") ?? "https://copilot.tencent.com"
        guard let baseURL = URL(string: base) else { throw CheckInProblem(.server, "baseUrl 无效") }
        let emptyObject = Data("{}".utf8)

        let status = try await reply(
            method: "POST",
            url: baseURL.appendingPathComponent("v2/billing/meter/checkin-activity-status"),
            headers: headers,
            body: emptyObject,
        )
        guard status.status == 200, let statusJSON = status.json else {
            throw CheckInProblem(.server, "状态查询 HTTP \(status.status)")
        }
        if let code = number(statusJSON["code"]), code != 0 {
            throw CheckInProblem(code == 401 || code == 403 ? .signedOut : .server, "状态查询 code \(code)")
        }
        let data = statusJSON["data"] as? [String: Any] ?? [:]
        let streak = number(data["streak_days"])
        let total = numberText(data["total_credits"])
        if flag(data["today_checked_in"]) {
            logger.info("workbuddy：今天已签到")
            return CheckInResult(platform: .workBuddy, outcome: .alreadyClaimed,
                                 total: total, streak: streak)
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
        let credit = numberText(claimed?["credit"]) ?? numberText(claimJSON["credit"])
        logger.info("workbuddy：签到成功")
        return CheckInResult(platform: .workBuddy, outcome: .claimed,
                             credit: credit, total: total, streak: streak)
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
        guard let base = URL(string: "https://api.trae.cn/trae/api/v2/ug/checkin_credits") else {
            throw CheckInProblem(.server, "地址无效")
        }
        let body = Data("{\"req_source\":1}".utf8)

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
        if code != 0 { throw CheckInProblem(.server, "状态查询 code \(code)") }
        if flag(statusJSON["checked_in"]) {
            logger.info("trae-cn：今天已签到")
            return CheckInResult(platform: .traeCN, outcome: .alreadyClaimed)
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
                logger.info("trae-cn：签到成功")
                return CheckInResult(platform: .traeCN, outcome: .claimed,
                                     credit: String(credits + extraCredits))
            }
            if claimCode == 9074 { continue }
            if claimCode == 1001 { throw CheckInProblem(.signedOut, "登录态失效") }
            if claimCode == 9004 { throw CheckInProblem(.rejected, "设备标识被拒") }
            throw CheckInProblem(.rejected, "领取 code \(claimCode)")
        }
        throw CheckInProblem(.rateLimited, "连续被限流")
    }

    // MARK: - Qoder CN

    private static func qoderCN(_ credentials: OAuthCredentials) async throws -> CheckInResult {
        let token = credentials.access
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
        guard let base = URL(string: "https://openapi.qoder.com.cn") else {
            throw CheckInProblem(.server, "地址无效")
        }

        let listing = try await reply(
            method: "GET",
            url: base.appendingPathComponent("sash/api/v1/me/campaigns"),
            headers: headers,
            body: nil,
        )
        guard listing.status == 200, let listingJSON = listing.json else {
            throw CheckInProblem(.server, "活动列表 HTTP \(listing.status)")
        }
        let campaigns = (listingJSON["campaigns"] as? [[String: Any]]) ?? []
        var claimable: [String] = []
        var claimedBefore = false
        for campaign in campaigns {
            guard (campaign["actionType"] as? String) == "CLAIM_BENEFIT" else { continue }
            let state = (campaign["claimStatus"] as? String) ?? ""
            if state == "CLAIMABLE", let id = campaign["campaignId"] as? String {
                claimable.append(id)
            } else if state.uppercased().contains("CLAIMED") {
                claimedBefore = true
            }
        }
        if claimable.isEmpty {
            logger.info("qoder-cn：没有可领取的活动")
            return CheckInResult(platform: .qoderCN, outcome: claimedBefore ? .alreadyClaimed : .nothingToDo)
        }
        var claimed = 0
        for id in claimable {
            let path = "sash/api/v1/me/campaigns/\(id)/claim"
            let claim = try await reply(method: "POST", url: base.appendingPathComponent(path),
                                        headers: headers, body: Data())
            if claim.status == 200 { claimed += 1 }
        }
        guard claimed > 0 else { throw CheckInProblem(.rejected, "活动领取全部失败") }
        logger.info("qoder-cn：领取到 \(claimed, privacy: .public) 个活动")
        return CheckInResult(platform: .qoderCN, outcome: .claimed)
    }

    // MARK: - HTTP

    private struct Reply {
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
