import UIKit
import UserNotifications

/// 会话宿主仍按原规则发送通知。前台是否显示由独立开关决定；
/// 打开可见会话时清除已读通知，点击沿用原有会话 URL 路由。
@MainActor
final class ConversationNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ConversationNotices()
    /// 宿主通知中保存会话链接的字段名。
    nonisolated static let linkKey = "link"
    @objc private dynamic var hasAsked = false

    /// Before `didFinishLaunching` returns, or a banner tapped on a cold
    /// launch is delivered to nobody.
    @objc dynamic static func start() {
        UNUserNotificationCenter.current().delegate = shared
    }

    /// Asked when the reader sends a message, the first moment a banner
    /// means something to them; the system asks a person once, however
    /// often this runs.
    @objc dynamic func requestAuthorizationIfNeeded() {
        guard !hasAsked else { return }
        hasAsked = true
        Task {
            let center = UNUserNotificationCenter.current()
            guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
    }

    /// The reader has `session`'s conversation in front of them: what its
    /// banners said, they can see.
    @objc dynamic func withdraw(session: String?) {
        guard let session else { return }
        let center = UNUserNotificationCenter.current()
        center.getDeliveredNotifications { delivered in
            let identifiers = delivered
                .filter { $0.request.content.threadIdentifier == session }
                .map(\.request.identifier)
            guard !identifiers.isEmpty else { return }
            center.removeDeliveredNotifications(withIdentifiers: identifiers)
        }
    }

    @objc dynamic nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        DispatchQueue.main.async {
            let show = ForegroundBackground.foregroundNotifications ||
                UIApplication.shared.applicationState != .active
            completionHandler(show ? [.banner, .list, .sound] : [])
        }
    }

    @objc dynamic nonisolated func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void,
    ) {
        let link = response.notification.request.content.userInfo[Self.linkKey] as? String
        DispatchQueue.main.async {
            if let link, let url = URL(string: link) {
                UIApplication.shared.open(url)
            }
            completionHandler()
        }
    }
}
