import ApelinProtocol
import Foundation
import os.log

extension Notification.Name {
    /// 签到状态变了：设置页的那一行与签到页自己都跟着它重画。
    static let checkInChanged = Notification.Name("wiki.qaq.apelin.checkInChanged")
}

/// 设置 ▸ 自动签到 的状态：每个平台今天的结果。网络、凭据与当天缓存全在
/// worker 里；这个类只留要画的那几行，并保证自动签到每天只触发一次。
@MainActor
final class CheckInStore {
    static let shared = CheckInStore()

    private enum Key {
        static let automatic = "checkin.auto"
        /// 自动签到最近跑过的那一天（本地日历日），同一天不再跑第二次。
        static let automaticDay = "checkin.auto.day"
    }

    /// 打开 App 时是否自动签到一次。
    var automaticEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.automatic) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.automatic)
            NotificationCenter.default.post(name: .checkInChanged, object: nil)
        }
    }

    private(set) var results: [CheckInResult] = []
    private var inFlight: Task<[CheckInResult], Never>?

    /// 正在问服务端（页面据此把按钮换成「签到中…」）。
    var isRunning: Bool { inFlight != nil }

    func result(for platform: CheckInPlatform) -> CheckInResult? {
        results.first { $0.platform == platform }
    }

    /// 今天已经签到的平台数。
    var doneCount: Int {
        results.filter(\.isDone).count
    }

    /// 读一次今天的结果，正在跑的请求直接复用。请求失败时保留上一次的数字，
    /// 不把页面清空。`platforms` 只填部分平台时，只刷新那几个。
    @discardableResult
    func refresh(platforms: [CheckInPlatform] = [], force: Bool = false) async -> [CheckInResult] {
        if let inFlight {
            return await inFlight.value
        }
        let previous = results
        let task = Task<[CheckInResult], Never> {
            do {
                let results = try await ApelinService.app.agentCheckIn(platforms: platforms, force: force).results
                Logger(subsystem: "wiki.qaq.apelin", category: "CheckIn")
                    .info("签到刷新成功：\(results.count, privacy: .public) 个平台 \(force ? "强制" : "自动", privacy: .public)")
                return results
            } catch {
                Logger(subsystem: "wiki.qaq.apelin", category: "CheckIn")
                    .error("签到刷新失败：\(String(describing: error), privacy: .public)")
                return previous
            }
        }
        inFlight = task
        let next = await task.value
        inFlight = nil
        results = next
        NotificationCenter.default.post(name: .checkInChanged, object: nil)
        return next
    }

    /// 进入前台时调用：开着自动签到、且今天还没跑过，就安静地跑一遍。
    /// 今天跑过（无论成功失败）就等明天，失败可以手动点「全部签到」。
    func automaticRunIfNeeded() {
        guard automaticEnabled else { return }
        let today = Self.dayKey()
        guard UserDefaults.standard.string(forKey: Key.automaticDay) != today else { return }
        UserDefaults.standard.set(today, forKey: Key.automaticDay)
        Task { [weak self] in
            await self?.refresh(force: false)
        }
    }

    /// 今天自动签到跑过没有——开关打开时由页面问一次，用来决定是否立刻补跑。
    static var automaticDay: String? {
        UserDefaults.standard.string(forKey: Key.automaticDay)
    }

    static func markAutomaticRunToday() {
        UserDefaults.standard.set(dayKey(), forKey: Key.automaticDay)
    }

    private static func dayKey(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
