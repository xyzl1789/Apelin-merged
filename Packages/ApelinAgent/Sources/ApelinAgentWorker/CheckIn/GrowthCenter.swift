import ApelinProtocol
import Foundation
import os

/// WorkBuddy 成长中心：签到之后把能自动做的都做一遍——任务接单与领奖、
/// 断登补登、连登兑换、盲盒抽奖、旅行礼物与能量开 Buddy。
///
/// 这里说的「完成」是服务端接口真的回了成功；任务要求「桌面端对话」这类
/// 真实行为的，服务端会回 `in_progress`，那是**没完成**，写清原因进日志，
/// 等以后在桌面端登录并把任务做完，下一次自动签到时再来领。
///
/// 接口是从官方客户端逆向来的私有接口，凭据与响应正文都只留在 worker 内，
/// 只有一句句中文结论（CheckInDetail）穿过协议线给界面。
enum GrowthCenter {
    private static let logger = Logger(subsystem: "wiki.qaq.apelin", category: "CheckIn")
    private static let base = "/v2/activity/growth"

    /// 一次成长中心的结果：明细 + 新增积分。
    struct Outcome {
        var details: [CheckInDetail] = []
        var credit: Int = 0
    }

    static func run(baseURL: URL, headers: [String: String],
                    reply: (String, String, [String: Any]?, Data?) async throws -> CheckReply) async -> Outcome {
        var out = Outcome()
        let tasks = await tasksStep(baseURL: baseURL, headers: headers, reply: reply)
        out.details.append(contentsOf: tasks.details)
        out.credit += tasks.credit

        let streak = await streakStep(baseURL: baseURL, headers: headers, reply: reply)
        out.details.append(contentsOf: streak.details)
        out.credit += streak.credit

        let redeem = await redeemStep(baseURL: baseURL, headers: headers, reply: reply)
        out.details.append(contentsOf: redeem.details)
        out.credit += redeem.credit

        let lottery = await lotteryStep(baseURL: baseURL, headers: headers, reply: reply)
        out.details.append(contentsOf: lottery.details)

        let travel = await travelStep(baseURL: baseURL, headers: headers, reply: reply)
        out.details.append(contentsOf: travel.details)

        let energy = await energyStep(baseURL: baseURL, headers: headers, reply: reply)
        out.details.append(contentsOf: energy.details)
        return out
    }

    // MARK: - 任务

    private static func tasksStep(baseURL: URL, headers: [String: String],
                                  reply: (String, String, [String: Any]?, Data?) async throws -> CheckReply) async -> Outcome {
        var out = Outcome()
        guard let response = try? await reply("GET", "\(base)/tasks", headers, nil),
              response.status == 200, let json = response.json else {
            out.details.append(.init(title: "成长任务", succeeded: false, note: "任务列表读取失败，稍后重试"))
            return out
        }
        let tasks = (json["data"] as? [String: Any])?["tasks"] as? [[String: Any]] ?? []
        var titles: [String: String] = [:]
        var pending: [String] = []
        var completed: [[String: Any]] = []
        for task in tasks {
            guard let code = task["task_code"] as? String, !code.isEmpty else { continue }
            titles[code] = (task["title"] as? String) ?? code
            let state = (task["accept_status"] as? String) ?? ""
            let locked = flag(task["locked"])
            if !locked, state == "not_accepted" {
                pending.append(code)
            }
            if !locked, state == "completed" {
                completed.append(task)
            }
            if !locked, state == "accepted" || state == "in_progress" {
                out.details.append(.init(title: titles[code] ?? code, succeeded: false,
                                         note: "已接单但还没完成：需要到对应平台做一次真实操作，完成后下次自动签到会来领奖"))
            }
        }

        // 接单：请求体必须是复数 task_codes，单数会被服务端 400 拒绝。
        if !pending.isEmpty {
            let body = bodyJSON(["task_codes": pending])
            if let accepted = try? await reply("POST", "\(base)/tasks/accept", headers, body),
               accepted.status == 200, let json = accepted.json {
                let results = (json["data"] as? [String: Any])?["results"] as? [[String: Any]] ?? []
                for item in results {
                    let code = (item["task_code"] as? String) ?? ""
                    let title = titles[code] ?? code
                    if (item["status"] as? String) == "error" {
                        let message = (item["message"] as? String) ?? ""
                        let note = message.isEmpty ? "接单被服务端拒绝" : "接单失败：\(message)"
                        out.details.append(.init(title: title, succeeded: false, note: note))
                        logger.error("成长任务接单失败：\(code, privacy: .public) \(message, privacy: .public)")
                    } else {
                        out.details.append(.init(title: title, succeeded: false,
                                                 note: "已接单，还需到对应平台完成一次真实操作，完成后下次自动签到会来领奖"))
                    }
                }
            } else {
                out.details.append(.init(title: "成长任务接单", succeeded: false, note: "接单请求失败，下次自动签到再试"))
            }
        }

        // 领奖：只有 completed 的任务能领，路径里带 task_code。
        for task in completed {
            guard let code = task["task_code"] as? String else { continue }
            let title = titles[code] ?? code
            guard let claimed = try? await reply("POST", "\(base)/tasks/\(code)/claim", headers, Data()),
                  claimed.status == 200 else {
                out.details.append(.init(title: title, succeeded: false, note: "任务已完成但领奖失败，下次自动签到再试"))
                continue
            }
            let credit = firstInt(claimed.json, keys: ["credit"]) ?? int(task["reward_credit"])
            let energy = firstInt(claimed.json, keys: ["energy"]) ?? int(task["reward_energy"])
            out.credit += credit
            out.details.append(.init(title: title, succeeded: true,
                                     note: "任务奖励已领取：+\(credit) 积分，+\(energy) 能量"))
        }
        return out
    }

    // MARK: - 断登补登

    private static func streakStep(baseURL: URL, headers: [String: String],
                                   reply: (String, String, [String: Any]?, Data?) async throws -> CheckReply) async -> Outcome {
        var out = Outcome()
        guard let streakResponse = try? await reply("GET", "\(base)/streak", headers, nil),
              streakResponse.status == 200, let streakJSON = streakResponse.json else {
            out.details.append(.init(title: "连签补登", succeeded: false, note: "连签状态读取失败，补登跳过"))
            return out
        }
        let streakData = (streakJSON["data"] as? [String: Any]) ?? [:]
        let cards = int((streakData["makeup_cards"] as? [String: Any])?["balance"])
        guard cards > 0 else {
            out.details.append(.init(title: "连签补登", succeeded: true, note: "没有补登卡，跳过（不影响签到）"))
            return out
        }
        guard let heatResponse = try? await reply("GET", "\(base)/heatmap", headers, nil),
              heatResponse.status == 200, let heatJSON = heatResponse.json,
              let heatData = heatJSON["data"] as? [String: Any] else {
            out.details.append(.init(title: "连签补登", succeeded: false, note: "活跃日历读取失败，没用补登卡"))
            return out
        }
        guard let gaps = makeupCandidates(streakData: streakData, heatData: heatData), !gaps.isEmpty else {
            out.details.append(.init(title: "连签补登", succeeded: true, note: "当月没有断登，补登卡留着"))
            return out
        }
        let target = gaps[0]
        guard let used = try? await reply("POST", "\(base)/makeup-cards/use", headers, bodyJSON(["target_date": target])),
              used.status == 200 || used.status == 400 else {
            out.details.append(.init(title: "连签补登", succeeded: false, note: "补登 \(target) 请求失败，下次再试"))
            return out
        }
        let message = (used.json?["msg"] as? String) ?? ""
        if used.status == 200, message.lowercased() != "date is not broken, no makeup needed" {
            out.details.append(.init(title: "连签补登", succeeded: true, note: "已补登 \(target)，连签天数已恢复"))
        } else {
            // 服务端已经补上或日期不再是断点，属于正常竞争，不算失败。
            out.details.append(.init(title: "连签补登", succeeded: true, note: "\(target) 无需补登或已经补过"))
        }
        return out
    }

    /// 从活跃日历选出当月、今天之前、上线之后的断登日（score 为 0 且没补过）。
    /// 服务端日期优先，免得本机时区跨月时算错；任何结构异常都返回 nil，不花补登卡。
    private static func makeupCandidates(streakData: [String: Any], heatData: [String: Any]) -> [String]? {
        guard let todayText = (heatData["today"] as? [String: Any])?["date"] as? String,
              let launchText = streakData["launch_date"] as? String,
              let today = date(of: todayText), let launch = date(of: launchText),
              let madeUp = (streakData["streak"] as? [String: Any])?["makeup_dates"] as? [String],
              let cells = heatData["cells"] as? [[String: Any]] else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        let start = max(firstOfMonth, launch)
        var scores: [String: Int] = [:]
        var done = Set(madeUp)
        for cell in cells {
            guard let day = cell["date"] as? String, date(of: day) != nil,
                  let score = int(cell["score"]) else { return nil }
            if let old = scores[day], old != score { return nil }
            scores[day] = score
        }
        let candidates = scores.filter { day, score in
            guard let when = date(of: day) else { return false }
            return score == 0 && when >= start && when < today && !done.contains(day)
        }.keys.sorted()
        return Array(candidates.reversed())
    }

    // MARK: - 连登兑换

    private static func redeemStep(baseURL: URL, headers: [String: String],
                                   reply: (String, String, [String: Any]?, Data?) async throws -> CheckReply) async -> Outcome {
        var out = Outcome()
        guard let response = try? await reply("GET", "\(base)/redeem/summary", headers, nil),
              response.status == 200, let json = response.json else {
            out.details.append(.init(title: "连签兑换", succeeded: false, note: "兑换状态读取失败，跳过"))
            return out
        }
        let data = (json["data"] as? [String: Any]) ?? [:]
        let tiers = [
            ("7d", "starter", "入门", 7),
            ("14d", "advanced", "进阶", 14),
            ("28d", "legendary", "巅峰", 28),
        ]
        for (tier, key, label, days) in tiers {
            let state = (data["\(key)_status"] as? String) ?? ""
            if state.isEmpty || state == "claimed" || state == "locked" { continue }
            var body = bodyJSON(["tier": tier, "client_token": clientToken()])
            guard var done = try? await reply("POST", "\(base)/redeem", headers, body) else {
                out.details.append(.init(title: "连签兑换「\(label)」", succeeded: false, note: "兑换请求失败，下次再试"))
                continue
            }
            // 服务端不认档位标识时退回天数写一次；参数校验阶段不会重复发奖。
            if isUnknownTier(done) {
                body = bodyJSON(["tier": days, "client_token": clientToken()])
                done = (try? await reply("POST", "\(base)/redeem", headers, body)) ?? done
            }
            if done.status == 403 {
                out.details.append(.init(title: "连签兑换「\(label)」", succeeded: false,
                                         note: "连签天数还不够，未解锁"))
            } else if done.status == 200 {
                let credit = firstInt(done.json, keys: ["credit_granted"])
                out.credit += credit
                out.details.append(.init(title: "连签兑换「\(label)」", succeeded: true,
                                         note: "兑换成功：+\(credit) 积分及附赠奖励"))
            } else {
                out.details.append(.init(title: "连签兑换「\(label)」", succeeded: false, note: "兑换被服务端拒绝，下次再试"))
            }
        }
        return out
    }

    // MARK: - 盲盒

    private static func lotteryStep(baseURL: URL, headers: [String: String],
                                    reply: (String, String, [String: Any]?, Data?) async throws -> CheckReply) async -> Outcome {
        var out = Outcome()
        guard let response = try? await reply("GET", "\(base)/lottery/chances", headers, nil),
              response.status == 200, let json = response.json,
              let chances = int((json["data"] as? [String: Any])?["balance"]), chances > 0 else {
            return out
        }
        let body = bodyJSON(["client_token": clientToken()])
        guard let drawn = try? await reply("POST", "\(base)/lottery/draw", headers, body) else {
            out.details.append(.init(title: "开盲盒", succeeded: false, note: "抽奖请求失败，机会留着下次再抽"))
            return out
        }
        if drawn.status == 200 {
            let prize = (drawn.json?["prize_name"] as? String)
                ?? (drawn.json?["prize"] as? String) ?? "未知奖品"
            let needsAddress = flag(drawn.json?["need_address"]) || flag(drawn.json?["require_address"])
            let note = needsAddress ? "抽到 \(prize)，实物奖需要到成长中心填收件信息" : "抽到 \(prize)"
            out.details.append(.init(title: "开盲盒", succeeded: true, note: note))
        } else if drawn.status == 400 {
            out.details.append(.init(title: "开盲盒", succeeded: true, note: "暂时没有可抽的机会，跳过"))
        } else {
            out.details.append(.init(title: "开盲盒", succeeded: false, note: "抽奖失败，机会留着下次再抽"))
        }
        return out
    }

    // MARK: - 旅行礼物

    private static func travelStep(baseURL: URL, headers: [String: String],
                                   reply: (String, String, [String: Any]?, Data?) async throws -> CheckReply) async -> Outcome {
        var out = Outcome()
        guard let response = try? await reply("GET", "\(base)/buddy/travel/status", headers, nil),
              response.status == 200, let json = response.json else { return out }
        let data = (json["data"] as? [String: Any]) ?? [:]
        let state = (data["state"] as? String) ?? ""
        let limit = flag(data["daily_limit_reached"])
        if state == "arrived", let record = data["record_id"] {
            if let claimed = try? await reply("POST", "\(base)/buddy/travel/claim", headers,
                                              bodyJSON(["record_id": record])), claimed.status == 200 {
                let credit = firstInt(claimed.json, keys: ["reward_credit"])
                out.credit += credit
                out.details.append(.init(title: "旅行礼物", succeeded: true, note: "已领取旅行礼物：+\(credit) 积分"))
            } else {
                out.details.append(.init(title: "旅行礼物", succeeded: false, note: "礼物已到但领取失败，下次再试"))
            }
        } else if state == "idle" && !limit {
            if let config = try? await reply("GET", "\(base)/buddy/travel/config", headers, nil),
               config.status == 200,
               let location = ((config.json?["data"] as? [String: Any])?["locations"] as? [[String: Any]])?.first,
               let id = location["id"] {
                if let departed = try? await reply("POST", "\(base)/buddy/travel/depart", headers,
                                                   bodyJSON(["location_id": id])),
                   departed.status == 200 || departed.status == 201 {
                    let name = (location["name"] as? String) ?? "目的地"
                    out.details.append(.init(title: "派 Buddy 旅行", succeeded: true, note: "已派往 \(name)，回来后自动领礼物"))
                } else {
                    out.details.append(.init(title: "派 Buddy 旅行", succeeded: false, note: "派遣失败，下次再试"))
                }
            }
        } else if state == "traveling" {
            let name = ((data["location"] as? [String: Any])?["name"] as? String) ?? "目的地"
            out.details.append(.init(title: "Buddy 旅行", succeeded: true, note: "Buddy 正在 \(name)，回来后自动领礼物"))
        }
        return out
    }

    // MARK: - 能量

    /// 能量只用来在 Buddy 能量够时开一个（官方成长中心的最后一个动作）。
    private static func energyStep(baseURL: URL, headers: [String: String],
                                   reply: (String, String, [String: Any]?, Data?) async throws -> CheckReply) async -> Outcome {
        var out = Outcome()
        guard let response = try? await reply("GET", "\(base)/energy", headers, nil),
              response.status == 200,
              let balance = firstInt(response.json, keys: ["balance"]), balance > 0 else { return out }
        let body = bodyJSON(["client_token": clientToken()])
        guard let opened = try? await reply("POST", "\(base)/buddy/energy", headers, body) else {
            out.details.append(.init(title: "能量开 Buddy", succeeded: false, note: "开 Buddy 请求失败，能量留着下次再用"))
            return out
        }
        if opened.status == 200 {
            out.details.append(.init(title: "能量开 Buddy", succeeded: true, note: "消耗能量开出一只 Buddy"))
        } else {
            out.details.append(.init(title: "能量开 Buddy", succeeded: false, note: "能量不足或接口拒绝，下次再试"))
        }
        return out
    }

    // MARK: - 小工具

    private static func clientToken() -> String {
        let bytes = (0 ..< 16).map { _ in UInt8.random(in: 0 ... 255) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        func piece(_ from: Int, _ length: Int) -> String { String(hex.dropFirst(from).prefix(length)) }
        return "u-\(piece(0, 8))-\(piece(8, 4))-\(piece(12, 4))-\(piece(16, 4))-\(piece(20, 12))"
    }

    private static func bodyJSON(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
    }

    private static func int(_ value: Any?) -> Int? {
        switch value {
        case let n as NSNumber: n.intValue
        case let s as String: Int(s)
        default: nil
        }
    }

    private static func firstInt(_ json: [String: Any]?, keys: [String]) -> Int? {
        guard let json else { return nil }
        for key in keys {
            if let value = int(json[key]) { return value }
            if let data = json["data"] as? [String: Any], let value = int(data[key]) { return value }
        }
        return nil
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let n as NSNumber: n.boolValue
        case let s as String: ["1", "true", "yes"].contains(s.lowercased())
        default: false
        }
    }

    private static func date(of text: String) -> Date? {
        guard text.count == 10 else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? .current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text)
    }

    private static func isUnknownTier(_ reply: CheckReply) -> Bool {
        let msg = (reply.json?["msg"] as? String) ?? ""
        return reply.status == 400 && msg.lowercased().contains("unknown tier")
    }
}

/// 成长中心只关心 HTTP 状态和 JSON；这里复用签到服务的 Reply 形状。
typealias CheckReply = CheckInService.Reply
