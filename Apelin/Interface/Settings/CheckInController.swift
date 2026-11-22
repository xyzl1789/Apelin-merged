import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// 设置 ▸ 自动签到：每天第一次打开 App 时为已登录的 WorkBuddy / WorkBuddy AI、
/// Trae CN、Qoder / Qoder CN 账号领取当天积分。页面本身随时可以手动点「全部签到」再看一遍。
///
/// 结果行只说今天怎样（已领、领过了、没有活动、未登录、失败原因），不展示
/// 服务端正文；换行显示领取到的积分数与连签天数，都是服务端给的数字。
final class CheckInController: TableController {
    private enum Section: Hashable {
        case automatic
        case actions
        case platforms
        case growth
        case log
    }

    private enum Row: Hashable {
        case automatic
        case runAll
        case platform(CheckInPlatform)
        case detail(platform: CheckInPlatform, index: Int)
        case logEntry(Int)
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] table, _, row in
        self?.cell(in: table, for: row)
    }

    private var runner: Task<Void, Never>?
    /// 签到日志快照（最近 10 条，最新的在前），供日志 section 展示。
    private var logSnapshot: [CheckInResult] = []

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        runner?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Check In")
        dataSource.headerTitle = { _ in nil }
        dataSource.footerTitle = { [weak self] section in self?.footer(for: section) }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRows),
            name: .checkInChanged,
            object: nil,
        )
        updateRows()
        load()
    }

    @objc private dynamic func updateRows() {
        var sections: [(Section, [Row])] = [
            (.automatic, [.automatic]),
            (.actions, [.runAll]),
            (.platforms, CheckInPlatform.allCases.map { .platform($0) }),
        ]
        // 成长中心逐项明细：失败项有红灯，点开这一页就能看见为什么没做成。
        var detailRows: [Row] = []
        for platform in CheckInPlatform.allCases {
            guard let details = CheckInStore.shared.result(for: platform)?.details else { continue }
            for index in details.indices {
                detailRows.append(.detail(platform: platform, index: index))
            }
        }
        if !detailRows.isEmpty { sections.append((.growth, detailRows)) }
        // 签到日志：最近 10 条，最新的在前。
        logSnapshot = Array(CheckInStore.shared.logEntries.prefix(10))
        var logRows: [Row] = []
        for index in logSnapshot.indices { logRows.append(.logEntry(index)) }
        if !logRows.isEmpty { sections.append((.log, logRows)) }
        dataSource.update(sections, reconfigure: true)
    }

    /// 进页面先把今天的缓存读一遍；worker 对同一天不会再打服务端。
    @objc(apelin_load) private dynamic func load() {
        runner?.cancel()
        runner = Task { [weak self] in
            await self?.refresh(platforms: [], force: false)
        }
    }

    private func refresh(platforms: [CheckInPlatform], force: Bool) {
        Task { [weak self] in
            await CheckInStore.shared.refresh(platforms: platforms, force: force)
            self?.updateRows()
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .automatic:
            String(localized: "Once a day, when you open Apelin, each signed-in WorkBuddy, Trae CN and Qoder CN account checks in for you.")
        case .actions:
            String(localized: "Each row shows today's result. Check In All asks the server again right away.")
        case .platforms:
            String(localized: "Growth tasks that need real use on the desktop stay red until they are done; the reason is listed below.")
        case .growth:
            String(localized: "Red means the action could not be finished automatically. A light means it was done or is harmless to skip.")
        case .log:
            "过去每次签到的结果，最新的一条排在最前。"
        }
    }

    // MARK: - 单元格

    private func cell(in tableView: UITableView, for row: Row) -> UITableViewCell {
        switch row {
        case .automatic:
            let cell = tableView.dequeueReusableCell(withIdentifier: "toggle") ?? UITableViewCell()
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Automatic Check-In")
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
            toggle.isOn = CheckInStore.shared.automaticEnabled
            toggle.accessibilityLabel = String(localized: "Automatic Check-In")
            toggle.accessibilityValue = CheckInStore.shared.automaticEnabled
                ? String(localized: "On")
                : String(localized: "Off")
            toggle.removeTarget(nil, action: nil, for: .valueChanged)
            toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        case .runAll:
            let cell = tableView.dequeueReusableCell(withIdentifier: "action") ?? UITableViewCell(style: .value1, reuseIdentifier: "action")
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Check In All")
            content.secondaryText = CheckInStore.shared.isRunning ? String(localized: "Checking In…") : nil
            cell.contentConfiguration = content
            cell.selectionStyle = .default
            cell.accessoryType = .none
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = String(localized: "Check In All")
            cell.accessibilityValue = content.secondaryText
            return cell
        case let .platform(platform):
            let cell = tableView.dequeueReusableCell(withIdentifier: "platform")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "platform")
            var content = UIListContentConfiguration.subtitleCell()
            content.text = platform.brand
            var parts: [String] = []
            if let summary = summary(for: platform) { parts.append(summary) }
            let red = CheckInStore.shared.result(for: platform)?.details?.filter { !$0.succeeded }.count ?? 0
            if red > 0 { parts.append("🔴 \(red)") }
            content.secondaryText = parts.isEmpty ? nil : parts.joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .default
            return cell
        case let .detail(platform, index):
            let cell = tableView.dequeueReusableCell(withIdentifier: "detail")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "detail")
            guard let details = CheckInStore.shared.result(for: platform)?.details,
                  details.indices.contains(index) else { return cell }
            let item = details[index]
            var content = UIListContentConfiguration.subtitleCell()
            content.text = "\(item.succeeded ? "🟢" : "🔴") \(item.title)"
            content.secondaryText = item.note
            content.secondaryTextProperties.color = item.succeeded ? .secondaryLabel : .systemRed
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = item.title
            cell.accessibilityValue = item.note
            return cell
        case let .logEntry(index):
            guard index < logSnapshot.count else { return UITableViewCell() }
            let entry = logSnapshot[index]
            let cell = tableView.dequeueReusableCell(withIdentifier: "log")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "log")
            var content = UIListContentConfiguration.subtitleCell()
            content.text = entry.platform.brand
            var parts: [String] = []
            switch entry.outcome {
            case .claimed:
                parts.append("已签到")
                if let credit = entry.credit { parts.append("\(credit) 积分") }
            case .alreadyClaimed:
                parts.append("已签过")
                if let total = entry.total { parts.append("\(total) 积分") }
            case .nothingToDo:
                parts.append("今日无奖励")
            case .notSignedIn:
                parts.append("未登录")
            case .failed:
                parts.append("签到失败")
            }
            parts.append(relativeTime(entry.updatedAt))
            content.secondaryText = parts.joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = entry.platform.brand
            cell.accessibilityValue = content.secondaryText
            return cell
        }
    }

    /// 「x 分钟/小时/天前」式的相对时间。
    private func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "刚刚" }
        if interval < 3600 { return "\(Int(interval / 60))分钟前" }
        if interval < 86_400 { return "\(Int(interval / 3600))小时前" }
        return "\(Int(interval / 86_400))天前"
    }

    @objc private dynamic func toggleChanged(_ toggle: UISwitch) {
        CheckInStore.shared.automaticEnabled = toggle.isOn
        if toggle.isOn, CheckInStore.automaticDay != Self.todayKey() {
            CheckInStore.markAutomaticRunToday()
            refresh(platforms: [], force: false)
        }
        updateRows()
    }

    private static func todayKey() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar.current
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    // MARK: - 状态文字

    private func summary(for platform: CheckInPlatform) -> String? {
        if CheckInStore.shared.isRunning {
            return String(localized: "Checking In…")
        }
        guard let result = CheckInStore.shared.result(for: platform) else { return nil }
        switch result.outcome {
        case .claimed:
            var parts = [String(localized: "Checked In")]
            if let credit = result.credit {
                parts.append("\(credit) \(String(localized: "Points"))")
            }
            if let streak = result.streak, streak > 0 {
                parts.append(String(format: String(localized: "Streak %lld Days"), streak))
            }
            return parts.joined(separator: " · ")
        case .alreadyClaimed:
            var parts = [String(localized: "Checked In")]
            if let total = result.total {
                parts.append("\(total) \(String(localized: "Points"))")
            }
            if let streak = result.streak, streak > 0 {
                parts.append(String(format: String(localized: "Streak %lld Days"), streak))
            }
            return parts.joined(separator: " · ")
        case .nothingToDo:
            return String(localized: "No Reward Today")
        case .notSignedIn:
            return String(localized: "Not Signed In")
        case .failed:
            switch result.reason {
            case .signedOut:
                return String(localized: "Sign-In Expired")
            case .network:
                return String(localized: "No Internet Connection")
            case .rateLimited:
                return String(localized: "Usage Limit Reached")
            case .rejected:
                return String(localized: "Request Refused")
            case .server, .none:
                return String(localized: "Something went wrong. Try again.")
            }
        }
    }

    // MARK: - 点击处理

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath) else { return true }
        switch row {
        case .automatic: return false
        case .runAll: return !CheckInStore.shared.isRunning
        case .platform: return !CheckInStore.shared.isRunning
        case .detail: return false
        case .logEntry: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .automatic:
            break
        case .runAll:
            let notice = "开始自动签到"
            SPIndicator.present(title: notice, preset: .done, haptic: .success)
            UIAccessibility.post(notification: .announcement, argument: notice)
            refresh(platforms: [], force: true)
        case let .platform(platform):
            refresh(platforms: [platform], force: true)
        case .detail:
            break
        case .logEntry:
            break
        }
    }
}
