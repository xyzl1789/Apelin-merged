import Foundation

/// 自动切换开启后，隔多久自动测一次速。间隔由用户在自动助手面板里选；
/// 测速在应用回到前台、距离上次测量够久时触发，不需要用户手动点测速按钮。
enum MeasurementSchedule {
    enum Interval: String, CaseIterable, Sendable {
        case off
        case sixHours
        case daily
        case everyThreeDays

        var title: String {
            switch self {
            case .off: String(localized: "Auto Measure Off")
            case .sixHours: String(localized: "Auto Measure Every 6 Hours")
            case .daily: String(localized: "Auto Measure Every Day")
            case .everyThreeDays: String(localized: "Auto Measure Every 3 Days")
            }
        }

        var duration: TimeInterval? {
            switch self {
            case .off: nil
            case .sixHours: 6 * 60 * 60
            case .daily: 24 * 60 * 60
            case .everyThreeDays: 72 * 60 * 60
            }
        }
    }

    private static let intervalKey = "autoAssistant.autoMeasureInterval"

    static var interval: Interval {
        get {
            guard let raw = UserDefaults.standard.string(forKey: intervalKey),
                  let value = Interval(rawValue: raw) else { return .off }
            return value
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: intervalKey) }
    }

    /// 上次测量距今够久、且没关掉自动测速，就算到期。从没测过算到期，
    /// 这样开启自动切换后第一次回前台就会测一轮。
    static func isDue(now: Date = .now) -> Bool {
        guard let duration = interval.duration else { return false }
        guard let measuredAt = MeasurementStore.load().measuredAt else { return true }
        return now.timeIntervalSince(measuredAt) >= duration
    }
}
