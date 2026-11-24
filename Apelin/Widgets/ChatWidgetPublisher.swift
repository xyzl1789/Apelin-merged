import ActivityKit
import Foundation
import os
import UIKit
import WidgetKit

/// Mirrors the conversations into the widgets: the snapshot the home screen
/// widget reads from the App Group container, and one Live Activity while
/// any conversation is working or waiting for an approval.
///
/// 会话开始、结束、改变优先级或等待审批时立即刷新；流式文案最多每秒刷新一次。
/// 回答预览只更新实时活动，不触发主屏小组件刷新。
@MainActor
final class ChatWidgetPublisher {
    static let shared = ChatWidgetPublisher()

    private weak var runtime: ChatRuntime?
    /// Folder name to display name, read from the projects' manifests.
    @objc private dynamic var projectNames: [String: String] = [:]
    @objc private dynamic var plannedRefresh: String?
    private let streamClock = ContinuousClock()
    private var lastLook: ContinuousClock.Instant?
    private var lastFocus: Set<ChatActivityFocus>?
    private var written: ChatWidgetSnapshot?
    private var shownActivity: ChatWidgetSnapshot?
    /// 最多一个 ActivityKit 调用在执行，后面只留最新快照，不排队重播旧回答。
    private var activityWork: Task<Void, Never>?
    private var pendingActivity: ChatWidgetSnapshot?
    /// Set once a quit has ended the activity: a change queued behind the
    /// quit must not bring one back.
    @objc private dynamic static var isClosedForQuit = false
    private struct ActivityNotice {
        let chat: ChatWidgetSnapshot.Chat
        let expiresAt: Date
    }
    /// 活动会话结束时保留五秒；失败提示优先，但不改变进行中会话的排序和计数。
    private var knownProgressIDs: Set<UUID>?
    private var notices: [UUID: ActivityNotice] = [:]
    private var noticeExpiryTask: Task<Void, Never>?
    private let writer = DispatchQueue(label: "wiki.qaq.apelin.widgets.writer", qos: .utility)
    private let log = Logger(subsystem: "wiki.qaq.apelin", category: "widgets")

    /// 流式更新的最小间隔；不适用于会话切换。
    private static let streamInterval: Duration = .seconds(1)

    private init() {
        NotificationCenter.default.addObserver(
            forName: .apelinProjectsChanged,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { ChatWidgetPublisher.shared.reloadProjectNames() }
        }
    }

    /// Starts mirroring `runtime`, the window's.
    func attach(_ runtime: ChatRuntime) {
        self.runtime = runtime
        reloadProjectNames()
        chatsChanged()
    }

    /// 背景或卡片样式变了：快照本身不变，`chatsChanged` 的比较不会推送，
    /// 这里把当前活动原样重推一次，让扩展按新设置重新渲染。深浅色切换
    /// 也走这里——tint 只在内容更新时才被系统重画。
    func appearanceChanged() {
        guard shownActivity != nil, !Self.isClosedForQuit else { return }
        if shownActivity!.chats.isEmpty, shownActivity!.totalCount == 0 { return }
        showActivity(shownActivity!)
    }

    @objc dynamic func chatsChanged() {
        guard let runtime, runtime.isReconciled, !Self.isClosedForQuit else { return }
        let focus = Set(runtime.records.values.compactMap(\.widgetFocus))
        if focus != lastFocus {
            lastFocus = focus
            publishNow()
            return
        }
        guard plannedRefresh == nil else { return }
        let elapsed = lastLook.map { $0.duration(to: streamClock.now) } ?? Self.streamInterval
        if elapsed >= Self.streamInterval {
            publishNow()
            return
        }
        let token = UUID().uuidString
        plannedRefresh = token
        Task { [weak self] in
            try? await Task.sleep(for: Self.streamInterval - elapsed)
            guard let self, plannedRefresh == token else { return }
            publishNow()
        }
    }

    @objc private dynamic func publishNow() {
        plannedRefresh = nil
        lastLook = streamClock.now
        publish()
    }

    @objc private dynamic func reloadProjectNames() {
        Task {
            guard let projects = try? await ProjectSummary.load() else { return }
            let names = Dictionary(projects.map { ($0.name, $0.displayTitle) }) { first, _ in first }
            guard names != projectNames else { return }
            projectNames = names
            chatsChanged()
        }
    }

    /// Nothing is said until the saved conversations are read and checked
    /// against the host's live sessions: an empty list at launch would end
    /// a Live Activity the last run left showing, and a row saved working
    /// would start one for a turn long over.
    @objc private dynamic func publish() {
        guard let runtime, runtime.isReconciled else { return }
        let records = runtime.records.values
        let listed = records.filter { $0.isListedInWidgets || $0.summary.isWorking }.map { record in
            let project = record.summary.projectName.map { projectNames[$0] ?? $0 }
            return (chat: record.widgetChat(projectName: project), updated: record.summary.lastInteraction, listed: record.isListedInWidgets)
        }
        let snapshot = ChatWidgetSnapshot(chats: listed.filter { $0.listed }.map { ($0.chat, $0.updated) })
        if snapshot != written {
            written = snapshot
            write(snapshot)
        }
        let running = listed.filter { $0.chat.isInProgress }
        let runningIDs = Set(running.compactMap { UUID(uuidString: $0.chat.id) })
        if let knownProgressIDs {
            let endedIDs = knownProgressIDs.subtracting(runningIDs)
            for row in listed where endedIDs.contains(UUID(uuidString: row.chat.id) ?? UUID()) {
                guard row.chat.status == .done || row.chat.status == .failed,
                      let id = UUID(uuidString: row.chat.id) else { continue }
                notices[id] = ActivityNotice(chat: row.chat, expiresAt: Date().addingTimeInterval(5))
            }
        }
        knownProgressIDs = runningIDs
        let now = Date()
        notices = notices.filter { _, notice in
            runningIDs.contains(UUID(uuidString: notice.chat.id) ?? UUID()) == false && notice.expiresAt > now
        }
        scheduleNoticeExpiry()
        var activity = ChatWidgetSnapshot(chats: running.map { ($0.chat, $0.updated) }).inProgress
        if !running.isEmpty {
            activity.transientResult = notices.values
                .filter { $0.chat.status == .failed }
                .sorted { $0.expiresAt > $1.expiresAt }
                .first?.chat
                ?? notices.values.sorted { $0.expiresAt > $1.expiresAt }.first?.chat
        }
        if running.isEmpty {
            // 批次结果只在全部结束时才用。仍有任务时不重扫历史，也不把已结束的行送给组件。
            notices.removeAll()
            scheduleNoticeExpiry()
            let batch = ChatActivityBatch(turns: records.flatMap(\.widgetTurns))
            let participants = listed.filter { row in
                UUID(uuidString: row.chat.id).map(batch.chatIDs.contains) == true
            }
            activity = ChatWidgetSnapshot(chats: participants.map { ($0.chat, $0.updated) }).inProgress
            activity.batchOutcome = batch.outcome
            if let id = batch.finalChatID, var row = participants.first(where: { $0.chat.id == id.uuidString })?.chat {
                activity.chats.removeAll { $0.id == row.id }
                row.status = batch.outcome == .failed ? .failed : .done
                activity.chats.insert(row, at: 0)
                activity.chats = Array(activity.chats.prefix(ChatWidgetSnapshot.activityLimit))
                if batch.outcome == .succeeded {
                    activity.answerPreview = runtime.records[id]?.widgetReply(completed: true)
                }
            }
        } else if let chat = activity.mostUrgent, chat.status == .working,
                  let id = UUID(uuidString: chat.id), let record = runtime.records[id] {
            activity.currentTool = record.widgetCurrentTool
            if activity.currentTool == nil {
                activity.answerPreview = record.widgetReply(completed: false)
            }
        }
        // 启动时历史按需读入。暂时没投影出任何回合，不等于用户清空了会话。
        if activity.chats.isEmpty, records.contains(where: { !runtime.historyIsReady($0.summary.id) }) {
            return
        }
        activity = activity.fittingActivityPayload()
        if activity != shownActivity {
            shownActivity = activity
            showActivity(activity)
        }
    }

    private func scheduleNoticeExpiry() {
        noticeExpiryTask?.cancel()
        guard let expiry = notices.values.map(\.expiresAt).min() else {
            noticeExpiryTask = nil
            return
        }
        let delay = max(0, expiry.timeIntervalSinceNow)
        noticeExpiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.publishNow()
        }
    }

    private func write(_ snapshot: ChatWidgetSnapshot) {
        writer.async { [log] in
            do {
                guard try ChatWidgetStore.write(snapshot) else {
                    log.error("No App Group container; the widgets show nothing")
                    return
                }
                DispatchQueue.main.async {
                    WidgetCenter.shared.reloadTimelines(ofKind: ChatWidgetStore.widgetKind)
                }
            } catch {
                log.error("Writing the widget snapshot failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func showActivity(_ state: ChatWidgetSnapshot) {
        guard #available(iOS 16.2, *), !Self.isClosedForQuit else { return }
        pendingActivity = state
        guard activityWork == nil else { return }
        activityWork = Task { [weak self] in
            guard let self else { return }
            while !Self.isClosedForQuit, let next = pendingActivity {
                pendingActivity = nil
                if !(await Self.apply(next)), shownActivity == next, pendingActivity == nil {
                    // 系统在后台可能拒绝新建。下次收到事件或回前台时，允许重试同一快照。
                    shownActivity = nil
                }
            }
            activityWork = nil
        }
    }

    /// 有现存活动就原地更新，不在切换时结束再重建。
    @available(iOS 16.2, *)
    private static func apply(_ state: ChatWidgetSnapshot) async -> Bool {
        guard !isClosedForQuit else { return true }
        let existing = Activity<ChatActivityAttributes>.activities.filter {
            $0.activityState == .active || $0.activityState == .stale
        }
        guard !state.chats.isEmpty else {
            for activity in existing {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            return true
        }
        let content = ActivityContent(state: state, staleDate: nil)
        if let activity = existing.first {
            await activity.update(content)
            return true
        }
        // 手动关闭后不重新创建纯终态活动。
        guard state.inProgressCount > 0 else { return true }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return false }
        do {
            _ = try Activity.request(attributes: ChatActivityAttributes(), content: content)
            return true
        } catch {
            Self.shared.log.error("无法创建实时活动：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// The app is quitting: nothing will update the activity after this,
    /// and the conversations go on in apelind out of its sight, so it is
    /// ended rather than left showing work that may be long over. The next
    /// launch shows it again if work is still in progress. Blocking,
    /// bounded by `timeout`, because `applicationWillTerminate` is the
    /// caller and anything still queued dies with the process; a suspended
    /// app gets no such call and keeps its activity.
    @objc dynamic static func endActivitiesForQuit(timeout: TimeInterval = 1) {
        isClosedForQuit = true
        guard #available(iOS 16.2, *) else { return }
        let activities = Activity<ChatActivityAttributes>.activities
        guard !activities.isEmpty else { return }
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            for activity in activities {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }
}

/// iOS 16 没有全局的深浅色变化通知：一个不加入任何可见层的小视图，
/// 隐藏着加进 key window，系统外观切换时它的 `traitCollectionDidChange`
/// 会被调用，转成回调交给发布器。
final class AppearanceProbeView: UIView {
    private static var onAppearanceChange: (() -> Void)?
    private static var installed = false

    static func install(onChange: @escaping () -> Void) {
        onAppearanceChange = onChange
        guard !installed else { return }
        installed = true
        DispatchQueue.main.async {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
                  let window = scene.keyWindow ?? scene.windows.first else { return }
            let probe = AppearanceProbeView(frame: .zero)
            probe.isHidden = true
            probe.isUserInteractionEnabled = false
            window.addSubview(probe)
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        if traitCollection.userInterfaceStyle != previousTraitCollection?.userInterfaceStyle {
            Self.onAppearanceChange?()
        }
    }
}
