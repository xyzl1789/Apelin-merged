import UIKit
import UserNotifications

/// 会话宿主仍按原规则发送通知；真实可见的当前会话静默，其他按独立开关展示。
/// 打开可见会话时清除已读通知，点击沿用原有会话 URL 路由。
@MainActor
final class ConversationNotices: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ConversationNotices()
    /// 宿主通知中保存会话链接的字段名。
    nonisolated static let linkKey = "link"
    @objc private dynamic var hasAsked = false
    /// 只弱引用正在显示的聊天页；会话 ID 在通知到达时读取，避免切换或新建后的旧缓存。
    weak var visibleChat: ChatController?

    nonisolated static func suppressesViewedConversation(
        notificationSession: String,
        visibleSession: String?,
        actuallyVisible: Bool
    ) -> Bool {
        guard actuallyVisible, let visibleSession, !visibleSession.isEmpty else { return false }
        return notificationSession == visibleSession
    }

    /// 在 didFinishLaunching 返回前设置代理，保证冷启动时通知点击也能被接收。
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
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void,
    ) {
        let session = notification.request.content.threadIdentifier
        DispatchQueue.main.async {
            if Self.suppressesViewedConversation(
                notificationSession: session,
                visibleSession: self.visibleChat?.notificationSessionID,
                actuallyVisible: ForegroundBackground.isActuallyVisible
            ) {
                completionHandler([])
                return
            }
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
