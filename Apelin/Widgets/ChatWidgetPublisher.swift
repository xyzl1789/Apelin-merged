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
    private var lastStepSignal: String?
    private var written: ChatWidgetSnapshot?
    private var shownActivity: ChatWidgetSnapshot?
    private var pinnedChatID: UUID? {
        ChatActivityPinStore.pinnedID()
    }
    /// 最多一个会话固定；新的固定会话替换旧值，并绕过流式节流立即刷新。
    @discardableResult
    func toggleLiveActivityPin(for id: UUID) -> Bool {
        let shouldPin = pinnedChatID != id
        ChatActivityPinStore.setPinnedID(shouldPin ? id : nil)
        publishNow()
        return shouldPin
    }

    func isPinnedForLiveActivity(_ id: UUID) -> Bool {
        pinnedChatID == id
    }

    /// 最多一个 ActivityKit 调用在执行，后面只留最新快照，不排队重播旧回答。
    private var activityWork: Task<Void, Never>?
    private var pendingActivity: ChatWidgetSnapshot?

    /// 每批事件都会来问一次：事件条数、工作状态、标题和项目都没变的会话，
    /// 复用上次算出的行，不再把它的整份历史重扫一遍。
    private var chatRows: [UUID: CachedChat] = [:]

    private struct CachedChat {
        let events: Int
        let working: Bool
        let isStopping: Bool
        let title: String
        let project: String?
        let isPinned: Bool
        let chat: ChatWidgetSnapshot.Chat
    }

    private func chatRow(_ record: ChatRecord, projectName: String?) -> ChatWidgetSnapshot.Chat {
        let id = record.summary.id
        let title = record.summary.displayTitle
        let isStopping = record.run == .stopping
        let isPinned = pinnedChatID == id
        if let cached = chatRows[id], cached.events == record.events.count,
           cached.working == record.summary.isWorking, cached.isStopping == isStopping,
           cached.title == title, cached.project == projectName, cached.isPinned == isPinned
        {
            return cached.chat
        }
        var chat = record.widgetChat(projectName: projectName)
        chat.isPinned = isPinned
        chatRows[id] = CachedChat(
            events: record.events.count,
            working: record.summary.isWorking,
            isStopping: isStopping,
            title: title,
            project: projectName,
            isPinned: isPinned,
            chat: chat,
        )
        return chat
    }

    /// Set once a quit has ended the activity: a change queued behind the
    /// quit must not bring one back.
    @objc private dynamic static var isClosedForQuit = false
    /// 提示只占展示位置，不改变进行中会话的排序、计数或跳转目标。
    private var knownProgressIDs: Set<String> = []
    /// 本批中固定后完成的会话不再作为结果行或最终活动行出现。
    private var hiddenPinnedCompletions: Set<String> = []
    private var noticeQueue = ChatActivityResultQueue()
    private var noticeExpiryTask: Task<Void, Never>?
    private let writer = DispatchQueue(label: "wiki.qaq.apelin.widgets.writer", qos: .utility)
    private let log = Logger(subsystem: "wiki.qaq.apelin", category: "widgets")

    /// 流式更新的最小间隔；不适用于会话切换。
    private static let streamInterval: Duration = .seconds(1)

    private init() {
        NotificationCenter.default.addObserver(
            forName: ForegroundBackground.enabledChanged,
            object: nil,
            queue: .main,
        ) { _ in
            MainActor.assumeIsolated { ChatWidgetPublisher.shared.backgroundPreferenceChanged() }
        }
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

    /// 不走流式节流，也不结束/重建活动。先更新已有快照，再从 runtime 恢复最新详情。
    @objc private dynamic func backgroundPreferenceChanged() {
        guard !Self.isClosedForQuit else { return }
        plannedRefresh = nil
        if let shownActivity {
            let next = shownActivity.withActivityDetails(ForegroundBackground.enabled).fittingActivityPayload()
            self.shownActivity = next
            showActivity(next)
        }
        publishNow()
    }

    @objc dynamic func chatsChanged() {
        guard let runtime, runtime.isReconciled, !Self.isClosedForQuit else { return }
        let focus = Set(runtime.records.values.compactMap(\.widgetFocus))
        let front = focus.min(by: ChatActivityFocus.precedes)
        let stepSignal = front.flatMap { item in
            item.approvalID == nil ? runtime.records[item.id]?.widgetStepSignal : nil
        }
        if focus != lastFocus || stepSignal != lastStepSignal {
            lastFocus = focus
            lastStepSignal = stepSignal
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
        // 来源用真实会话标题解析，不按标题猜父子关系，也不扫描其他会话历史。
        let sessionTitles = records.reduce(into: [String: String]()) { titles, record in
            if let session = record.sessionID { titles[session] = record.summary.displayTitle }
        }
        let listed = records.filter { $0.isListedInWidgets || $0.summary.isWorking }.map { record in
            let project = record.summary.projectName.map { projectNames[$0] ?? $0 }
            return (chat: chatRow(record, projectName: project), updated: record.summary.lastInteraction, listed: record.isListedInWidgets)
        }
        let widgetChats = listed.filter { $0.listed }.map { row -> (chat: ChatWidgetSnapshot.Chat, updated: Date) in
            var chat = row.chat
            chat.isPinned = false
            return (chat: chat, updated: row.updated)
        }
        let snapshot = ChatWidgetSnapshot(chats: widgetChats)
        if snapshot != written {
            written = snapshot
            write(snapshot)
        }
        let running = listed.filter { $0.chat.isInProgress }
        let runningIDs = Set(running.map { $0.chat.id })
        hiddenPinnedCompletions.subtract(runningIDs)
        if let completedPin = ChatActivityPinStore.clearPinIfNotRunning(runningIDs: runningIDs) {
            hiddenPinnedCompletions.insert(completedPin.uuidString)
            chatRows.removeValue(forKey: completedPin)
        }

        let endedIDs = knownProgressIDs.subtracting(runningIDs)
        knownProgressIDs = runningIDs
        let ended = listed.compactMap { row -> ChatWidgetSnapshot.Chat? in
            guard !running.isEmpty, endedIDs.contains(row.chat.id),
                  !hiddenPinnedCompletions.contains(row.chat.id),
                  let id = UUID(uuidString: row.chat.id),
                  let outcome = runtime.records[id]?.widgetTurns.last?.outcome,
                  outcome == .succeeded || outcome == .failed else { return nil }
            var chat = row.chat
            chat.status = outcome == .failed ? .failed : .done
            chat.project = nil
            chat.approvalTool = nil
            chat.startedAt = nil
            return chat
        }.sorted { $0.id < $1.id }
        let resultNotice = noticeQueue.update(
            ended: ended,
            runningIDs: runningIDs,
            waiting: running.contains { $0.chat.status == .waiting },
            now: .now,
        )
        scheduleNoticeExpiry(resultNotice?.expiresAt)
        var activity = ChatWidgetSnapshot(chats: running.map { ($0.chat, $0.updated) }).inProgress
        activity.transientResult = resultNotice
        if running.isEmpty {
            let batch = ChatActivityBatch(turns: records.flatMap(\.widgetTurns))
            // 冷启动时历史还没读进内存的会话不在 `listed` 里，可这一批已经
            // 结束了：直接按这一批的会话找记录，不再要求它列出过。否则列表
            // 拼成空的，活动被立即收掉，锁屏上只剩一块没有内容的背景。
            let participants: [(chat: ChatWidgetSnapshot.Chat, updated: Date)] = batch.chatIDs.compactMap { id in
                guard let record = runtime.records[id] else { return nil }
                let project = record.summary.projectName.map { projectNames[$0] ?? $0 }
                return (chat: chatRow(record, projectName: project), updated: record.summary.lastInteraction)
            }.filter { !hiddenPinnedCompletions.contains($0.chat.id) }
            activity = ChatWidgetSnapshot(chats: participants.map { ($0.chat, $0.updated) }).inProgress
            activity.batchOutcome = batch.outcome
            if let id = batch.finalChatID, var row = participants.first(where: { $0.chat.id == id.uuidString })?.chat {
                activity.chats.removeAll { $0.id == row.id }
                row.status = batch.outcome == .failed ? .failed : .done
                activity.chats.insert(row, at: 0)
                activity.chats = Array(activity.chats.prefix(ChatWidgetSnapshot.activityLimit))
                if let record = runtime.records[id] {
                    activity.recentTools = record.widgetRecentTools(completed: true)
                    activity.flowNotes = record.widgetFlowNotes(completed: true, conversationTitle: { sessionTitles[$0] })
                    if batch.outcome == .succeeded {
                        activity.answerPreview = record.widgetReply(completed: true)
                    }
                }
            }
        } else if let chat = activity.mostUrgent, chat.isInProgress,
                  let id = UUID(uuidString: chat.id), let record = runtime.records[id] {
            activity.progress = record.widgetProgress
            activity.recentTools = record.widgetRecentTools()
            activity.flowNotes = record.widgetFlowNotes(conversationTitle: { sessionTitles[$0] })
            activity.metrics = record.widgetMetrics
        }
        // 启动时历史按需读入。暂时没投影出任何回合，不等于用户清空了会话。
        if activity.chats.isEmpty, records.contains(where: { !runtime.historyIsReady($0.summary.id) }) {
            return
        }
        activity = activity.withActivityDetails(ForegroundBackground.enabled).fittingActivityPayload()
        if activity != shownActivity {
            shownActivity = activity
            showActivity(activity)
        }
    }

    private func scheduleNoticeExpiry(_ expiry: Date?) {
        noticeExpiryTask?.cancel()
        guard let expiry else {
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

        // ActivityKit can retain an older stale instance while a newer active
        // one is already present. Keep exactly one canonical activity before
        // updating or creating; otherwise every later refresh keeps the extra
        // activity alive because only `existing.first` was updated.
        let primary = existing.first(where: { $0.activityState == .active }) ?? existing.first
        if let primary {
            let duplicates = existing.filter { $0.id != primary.id }
            for duplicate in duplicates {
                await duplicate.end(nil, dismissalPolicy: .immediate)
            }
        }

        // 让系统到期重绘；组件只隐藏提示，不清除运行中的会话。
        let content = ActivityContent(state: state, staleDate: state.transientResult?.expiresAt)
        if let primary {
            await primary.update(content)
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
        ForegroundBackground.stop()

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
