import Darwin
import notify
import Dog
import UIKit

/// App 只发布用户的选择；场景修改由独立 SpringBoard 模块执行，不再申请后台断言。
@MainActor
enum ForegroundBackground {
    static let changed = Notification.Name("com.xyzl.apelin.foreground.changed")
    static let becameVisible = Notification.Name("com.xyzl.apelin.foreground.visible")
    private static let requestName = "com.xyzl.apelin.foreground.request"
    private static let statusName = "com.xyzl.apelin.foreground.status"
    private static var requestToken: Int32 = -1
    private static var statusToken: Int32 = -1
    private static var timer: Timer?
    private static var stopped = false
    private static var receivedAt: TimeInterval = 0
    private static var status: UInt64 = 0

    static var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: "foregroundBackground.enabled") }
        set {
            UserDefaults.standard.set(newValue, forKey: "foregroundBackground.enabled")
            publish()
        }
    }

    /// 默认保留前台通知；保活会让 UIKit 的 active 不再等于读者正在看应用。
    static var foregroundNotifications: Bool {
        get { UserDefaults.standard.object(forKey: "foregroundBackground.notifications") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "foregroundBackground.notifications")
            publish()
        }
    }

    static var locked: Bool {
        get { UserDefaults.standard.bool(forKey: "foregroundBackground.locked") }
        set {
            UserDefaults.standard.set(newValue, forKey: "foregroundBackground.locked")
            publish()
        }
    }

    static var indicators: Bool {
        get { UserDefaults.standard.bool(forKey: "foregroundBackground.indicators") }
        set {
            UserDefaults.standard.set(newValue, forKey: "foregroundBackground.indicators")
            publish()
        }
    }

    static var lockIndicator: Bool {
        get { UserDefaults.standard.bool(forKey: "foregroundBackground.lockIndicator") }
        set {
            UserDefaults.standard.set(newValue, forKey: "foregroundBackground.lockIndicator")
            publish()
        }
    }

    static var protectionSummary: String {
        guard hasFreshStatus else { return "模块未连接，无法确认锁定或标记" }
        let protection = status & 8 != 0
            ? (status & 32 != 0 ? "卡片锁定已启用" : "卡片锁定已关闭")
            : "锁定接口不兼容，未拦截划掉"
        let marks = status & 16 != 0 ? "图标标记接口已连接" : "图标标记接口不兼容"
        return protection + "；" + marks
    }

    private static var hasFreshStatus: Bool {
        status >> 32 == UInt64(UInt32(ProcessInfo.processInfo.processIdentifier)) &&
            ProcessInfo.processInfo.systemUptime - receivedAt < 12
    }

    private static var isBridgeConnected: Bool {
        hasFreshStatus && status & 1 != 0
    }

    static var isActuallyVisible: Bool {
        if isBridgeConnected { return status & 4 != 0 }
        // 保活时不再用被保持的 active 状态冒充“读者正在看”；未知就不自动清通知。
        return !enabled && UIApplication.shared.applicationState == .active
    }

    static var summary: String {
        guard hasFreshStatus else { return "模块未连接，请确认安装后已重新加载 SpringBoard" }
        guard status & 1 != 0 else { return "系统接口不兼容，保活未启用" }
        if !enabled { return "后台保活已关闭" }
        return status & 2 != 0 ? "场景保持已应用，持续运行仍需实测" : "等待本应用场景更新"
    }

    static func start() {
        guard requestToken < 0 else { return }
        stopped = false
        guard notify_register_check(requestName, &requestToken) == NOTIFY_STATUS_OK else {
            Dog.shared.join("Foreground", "无法注册后台设置通道", level: .error)
            return
        }
        let registration = notify_register_dispatch(statusName, &statusToken, .main) { token in
            var value: UInt64 = 0
            guard notify_get_state(token, &value) == NOTIFY_STATUS_OK else { return }
            MainActor.assumeIsolated {
                guard value >> 32 == UInt64(UInt32(ProcessInfo.processInfo.processIdentifier)) else { return }
                let wasVisible = isActuallyVisible
                let previous = status
                status = value
                receivedAt = ProcessInfo.processInfo.systemUptime
                if previous != value {
                    Dog.shared.join("Foreground", summary, level: .info)
                }
                if !wasVisible, isActuallyVisible {
                    NotificationCenter.default.post(name: becameVisible, object: nil)
                }
                NotificationCenter.default.post(name: changed, object: nil)
            }
        }
        if registration != NOTIFY_STATUS_OK {
            Dog.shared.join("Foreground", "无法注册后台状态通道", level: .error)
        }
        let heartbeat = Timer(timeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { publish() }
        }
        timer = heartbeat
        RunLoop.main.add(heartbeat, forMode: .common)
        publish()
    }

    private static func publish() {
        guard requestToken >= 0, !stopped else { return }
        let pid = UInt64(UInt32(ProcessInfo.processInfo.processIdentifier)) << 32
        let flags: UInt64 = (enabled ? 1 : 0) | (foregroundNotifications ? 2 : 0) |
            (locked ? 4 : 0) | (indicators ? 8 : 0) | (lockIndicator ? 16 : 0)
        guard notify_set_state(requestToken, pid | flags) == NOTIFY_STATUS_OK else {
            Dog.shared.join("Foreground", "后台设置发送失败", level: .error)
            return
        }
        notify_post(requestName)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    static func stop() {
        stopped = true
        timer?.invalidate()
        timer = nil
        if requestToken >= 0 {
            notify_set_state(requestToken, 0)
            notify_post(requestName)
        }
    }
}
