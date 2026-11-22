import ApelinProtocol
import Then
import UIKit

/// Settings ▸ 自动签到：每天第一次打开 App 时为已登录的 WorkBuddy、Trae CN、
/// Qoder CN 账号领取当天积分。页面本身随时可以手动点「全部签到」再看一遍。
///
/// 结果行只说今天怎样（已领、领过了、没有活动、未登录、失败原因），不展示
/// 服务端正文；换行显示领取到的积分数与连签天数，都是服务端给的数字。
final class CheckInController: TableController {
    private enum Section: Hashable {
        case automatic
        case actions
        case platforms
    }

    private enum Row: Hashable {
        case automatic
        case runAll
        case platform(CheckInPlatform)
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] table, _, row in
        self?.cell(in: table, for: row)
    }

    private var runner: Task<Void, Never>?

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
        dataSource.update([
            (.automatic, [.automatic]),
            (.actions, [.runAll]),
            (.platforms, CheckInPlatform.allCases.map { .platform($0) }),
        ], reconfigure: true)
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
            nil
        }
    }

    // MARK: - Cells

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
            content.secondaryText = summary(for: platform)
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
            return cell
        }
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

    // MARK: - Status text

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
                String(localized: "Sign-In Expired")
            case .network:
                String(localized: "No Internet Connection")
            case .rateLimited:
                String(localized: "Usage Limit Reached")
            case .rejected:
                String(localized: "Request Refused")
            case .server, .none:
                String(localized: "Something went wrong. Try again.")
            }
        }
    }

    // MARK: - Selection

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath) else { return true }
        switch row {
        case .automatic: return false
        case .runAll: return !CheckInStore.shared.isRunning
        case .platform: return !CheckInStore.shared.isRunning
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .automatic:
            break
        case .runAll:
            refresh(platforms: [], force: true)
        case let .platform(platform):
            refresh(platforms: [platform], force: true)
        }
    }
}
