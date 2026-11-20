import UIKit

/// 把读者选的深浅色外观应用到界面。
///
/// 跟随系统时把 window 的 `overrideUserInterfaceStyle` 清回 `.unspecified`，
/// 让系统随日夜切换；选定浅色或深色时写到每一个 window 上，包括运行中新
/// 连接的场景。外观是全局偏好，改完立刻生效，不必重启。
enum AppAppearance {
    static let changeNotification = Notification.Name("app.appearanceChanged")

    /// 应用到单个 window，供场景刚创建、还没进入 `windowScene.windows` 时用。
    static func apply(to window: UIWindow) {
        let style = Preferences.appearance.interfaceStyle ?? .unspecified
        if window.overrideUserInterfaceStyle != style {
            window.overrideUserInterfaceStyle = style
        }
    }

    /// 应用当前选择到所有已连接的 window。场景连接时和偏好改动时各调一次。
    static func apply() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                apply(to: window)
            }
        }
    }

    /// 偏好设置页在写入新选择后调用：应用到本进程，并通知其它实例同步。
    static func set(_ appearance: Preferences.Appearance) {
        Preferences.appearance = appearance
        apply()
        NotificationCenter.default.post(name: changeNotification, object: nil)
    }

    /// 在 app 启动时监听改动通知；返回 token，由调用方持有。
    @discardableResult
    static func observe() -> NSObjectProtocol {
        NotificationCenter.default.addObserver(
            forName: changeNotification,
            object: nil,
            queue: .main,
        ) { _ in apply() }
    }
}
