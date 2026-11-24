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

    private var storedResults: [CheckInResult] = []
    var results: [CheckInResult] {
        storedResults.filter { Calendar.current.isDateInToday($0.updatedAt) }
    }

    /// 签到日志：最近若干条，持久化，供「签到日志」展示。
    private(set) var logEntries: [CheckInResult] = []
    private(set) var runningPlatforms: Set<CheckInPlatform> = []
    private(set) var lastRequestFailed = false

    private init() {
        logEntries = loadLog() ?? []
        for entry in logEntries where !storedResults.contains(where: { $0.platform == entry.platform }) {
            storedResults.append(entry)
        }
    }

    /// 日志持久化的键与上限。
    private static let logKey = "checkin.log"
    private static let maxLog = 50

    /// 正在问服务端（页面据此把按钮换成「签到中…」）。
    var isRunning: Bool { !runningPlatforms.isEmpty }

    func result(for platform: CheckInPlatform) -> CheckInResult? {
        results.first { $0.platform == platform }
    }

    func clearSignInFailure(for platform: CheckInPlatform) {
        guard let result = result(for: platform), result.outcome == .notSignedIn || result.reason == .signedOut else { return }
        storedResults.removeAll { $0.platform == platform }
        NotificationCenter.default.post(name: .checkInChanged, object: nil)
    }

    /// 今天已经签到的平台数。
    var doneCount: Int {
        results.filter(\.isDone).count
    }

    /// 该平台最近一次签到日志。
    func logEntry(for platform: CheckInPlatform) -> CheckInResult? {
        logEntries.first { $0.platform == platform }
    }

    /// 把本次刷新得到的结果追加进签到日志，持久化，只留最近 `maxLog` 条。
    private func appendLog(results: [CheckInResult]) {
        guard var log = loadLog() else { return }
        for result in results {
            if log.contains(where: { $0.platform == result.platform && $0.updatedAt == result.updatedAt }) {
                continue
            }
            log.append(result)
        }
        log.sort { $0.updatedAt > $1.updatedAt }
        if log.count > Self.maxLog { log = Array(log.prefix(Self.maxLog)) }
        logEntries = log
        saveLog(log)
    }

    private func loadLog() -> [CheckInResult]? {
        guard let data = UserDefaults.standard.data(forKey: Self.logKey) else { return logEntries }
        // 不能读的旧记录留在原处，不在下一次签到时覆盖。
        do { return try JSONDecoder().decode([CheckInResult].self, from: data) }
        catch { return nil }
    }

    private func saveLog(_ log: [CheckInResult]) {
        guard let data = try? JSONEncoder().encode(log) else { return }
        UserDefaults.standard.set(data, forKey: Self.logKey)
    }

    /// 同一时间只跑一次请求。请求失败时保留上一次的结果，
    /// 不把页面清空。`platforms` 只填部分平台时，只刷新那几个。
    @discardableResult
    func refresh(platforms: [CheckInPlatform] = [], force: Bool = false) async -> [CheckInResult] {
        guard !isRunning else { return [] }
        runningPlatforms = Set(platforms.isEmpty ? CheckInPlatform.allCases : platforms)
        lastRequestFailed = false
        NotificationCenter.default.post(name: .checkInChanged, object: nil)
        defer {
            runningPlatforms.removeAll()
            NotificationCenter.default.post(name: .checkInChanged, object: nil)
        }
        do {
            let fresh = try await ApelinService.app.agentCheckIn(platforms: platforms, force: force).results
            for result in fresh {
                if let index = storedResults.firstIndex(where: { $0.platform == result.platform }) {
                    storedResults[index] = result
                } else {
                    storedResults.append(result)
                }
            }
            appendLog(results: fresh)
            return fresh
        } catch {
            lastRequestFailed = true
            Logger(subsystem: "wiki.qaq.apelin", category: "CheckIn").error("签到请求未能完成")
            return []
        }
    }

    /// 进入前台时调用：开着自动签到、且今天还没跑过，就安静地跑一遍。
    /// 今天跑过（无论成功失败）就等明天，失败可以手动点「全部签到」。
    func automaticRunIfNeeded() {
        Task { [weak self] in
            guard let self, automaticEnabled, !isRunning else { return }
            let today = Self.dayKey()
            guard UserDefaults.standard.string(forKey: Key.automaticDay) != today else { return }
            UserDefaults.standard.set(today, forKey: Key.automaticDay)
            await refresh(force: false)
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
