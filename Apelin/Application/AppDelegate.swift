import AlertController
import ApelinCore
import UIKit

/// Not `@main`: `main.swift` clears saved scenes before `UIApplicationMain`.
final class AppDelegate: UIResponder, UIApplicationDelegate {
    @objc dynamic func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions _: [UIApplication.LaunchOptionsKey: Any]?,
    ) -> Bool {
        ExecutableWatch.start {
            let alert = UIAlertController(
                title: String(localized: "Apelin Updated or Removed"),
                message: String(localized: "Quit to apply the change, or keep using this version for now."),
                preferredStyle: .alert,
            )
            alert.addAction(UIAlertAction(title: String(localized: "Later"), style: .cancel))
            alert.addAction(UIAlertAction(title: String(localized: "Quit"), style: .destructive) { _ in
                QuietExit.run()
            })
            Self.presentWhenActive(alert, in: application)
        }
        // before anything reads the data folder
        let recovered = DataFolder.container.flatMap { ContainerDataFolder.recover(from: $0, into: .app) }
        AppJournal.start()
        if let recovered {
            AppJournal.note(recovered)
        }
        NetworkAccess.start()
        ConversationNotices.start()
        // 偏好设置页改外观后，本进程所有 window 跟着变。
        AppAppearance.observe()
        // the progress card and the alerts carry the app's icon, as Fila's do
        AlertControllerConfiguration.alertImage = UIImage(named: "AppIconMark")
        // the app's own accent (`AppAccent`); the library's default is red
        AlertControllerConfiguration.accentColor = AppAccent.color(glass: .systemBlue)
        AlertControllerConfiguration.accentForegroundColor = AppAccent.foreground(glass: .white)
        ConsoleLaunch.start()
        // models.dev's catalog: the shipped copy in place, then a newer one if
        // the copy on this device is old (ModelDataRefresh).
        ModelDataRefresh.start()
        // The WeChat channel writes its replies in the app's own language,
        // which the host cannot read for itself: told at launch, and again
        // when the channel's page opens. The host may still be starting,
        // hence the retries.
        Task { await ChannelLanguage.pushIfChanged(retries: 5) }
        // 深浅色切换时重推一次当前活动：实时活动的 backgroundTint 只在
        // 内容更新时才被系统重画，不重推就一直是旧外观的颜色。iOS 16 没有
        // 全局的外观变化通知，借一个不进层级的视图的 traitCollectionDidChange 来听。
        AppearanceProbeView.install {
            ChatWidgetPublisher.shared.appearanceChanged()
        }
        return true
    }

    /// A quit takes the Live Activity with it: nothing would update it
    /// after (`ChatWidgetPublisher.endActivitiesForQuit`).
    @objc dynamic func applicationWillTerminate(_: UIApplication) {
        ChatWidgetPublisher.endActivitiesForQuit()
    }

    @objc dynamic func application(
        _: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options _: UIScene.ConnectionOptions,
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    /// The watch fires once, and may fire with no scene active: at launch,
    /// in the background, or on resume before the scene activates. The
    /// notice then waits for the next activation instead of being lost.
    @objc private dynamic static func presentWhenActive(_ alert: UIAlertController, in application: UIApplication) {
        let active = application.connectedScenes.first { $0.activationState == .foregroundActive }
        guard let scene = active as? UIWindowScene else {
            var observer: NSObjectProtocol?
            observer = NotificationCenter.default.addObserver(
                forName: UIScene.didActivateNotification,
                object: nil,
                queue: .main,
            ) { _ in
                MainActor.assumeIsolated {
                    if let observer {
                        NotificationCenter.default.removeObserver(observer)
                    }
                    presentWhenActive(alert, in: application)
                }
            }
            return
        }
        // In front of whatever the scene shows: a root already presenting a
        // sheet or another alert would drop it.
        guard var top = scene.keyWindow?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        top.present(alert, animated: true)
    }
}

final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    @objc dynamic var window: UIWindow?

    @objc dynamic func sceneDidBecomeActive(_: UIScene) {
        (window?.rootViewController as? RootInterfaceController)?.checkShareInbox()
    }

    @objc dynamic func scene(
        _ scene: UIScene,
        willConnectTo _: UISceneSession,
        options connectionOptions: UIScene.ConnectionOptions,
    ) {
        guard let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        window.tintColor = AppAccent.windowTint
        AppAppearance.apply(to: window)
        let root = RootInterfaceController()
        let urls = connectionOptions.urlContexts.map(\.url)
        // 在视图恢复上次会话之前先把附件排进队列。
        root.attachFiles(urls.filter(Self.isAttachment).sorted { $0.absoluteString < $1.absoluteString })
        window.rootViewController = root
        window.makeKeyAndVisible()
        self.window = window
        // 冷启动的「在 Apelin 中打开」或 `apelin://` 链接随场景到达，
        // 下一轮再打开，此时根控制器已在屏幕上可以弹出。
        DispatchQueue.main.async { [weak self] in self?.openSpecialURL(in: urls, scene: scene) }
    }

    /// App 运行时收到「在 Apelin 中打开」或 `apelin://` 链接。
    @objc dynamic func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
        guard let scene = scene as? UIWindowScene else { return }
        let urls = contexts.map(\.url).sorted { $0.absoluteString < $1.absoluteString }
        (window?.rootViewController as? RootInterfaceController)?.attachFiles(urls.filter(Self.isAttachment))
        openSpecialURL(in: urls, scene: scene)
    }

    /// 普通文件是聊天附件；toolchain / SDK / project / transfer 包走各自入口。
    private static func isAttachment(_ url: URL) -> Bool {
        url.isFileURL && TransferKind(fileName: url.lastPathComponent) == nil
    }

    private func openSpecialURL(in urls: [URL], scene: UIWindowScene) {
        if let special = urls.first(where: { !Self.isAttachment($0) }), !ApelinLinkRouter.open(special, in: scene) {
            TransferOpener.open(special, in: scene)
        }
    }
}
