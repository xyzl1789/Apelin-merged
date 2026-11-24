import ApelinProtocol
import SPIndicator
import UIKit

/// 设置 ▸ 签到：先看今天的进度，再处理各平台，历史与成长任务放在后面。
final class CheckInController: TableController {
    private enum Section: Hashable {
        case today, growth, automatic, history
        case platform(CheckInPlatform)
    }

    private enum Row: Hashable {
        case overview, runAll, requestError, automatic, growth
        case platform(CheckInPlatform)
        case detail(CheckInPlatform, Int)
        case log(CheckInPlatform, Date)
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView, identifier: { $0 }
    ) { [weak self] table, _, row in
        self?.cell(in: table, for: row)
    }

    @objc private dynamic var growthExpanded = false
    private var logSnapshot: [CheckInResult] = []

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Check In")
        dataSource.headerTitle = { section in
            switch section {
            case .platform(.workBuddy): return String(localized: "Platforms")
            case .history: return String(localized: "Recent Check-Ins")
            default: return nil
            }
        }
        dataSource.footerTitle = { section in
            guard section == .automatic else { return nil }
            return String(localized: "Automatic check-in runs the first time you open the app each day.")
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateRows), name: .checkInChanged, object: nil
        )
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        updateRows()
        CheckInStore.shared.automaticRunIfNeeded()
    }

    @objc private dynamic func updateRows() {
        let store = CheckInStore.shared
        var today: [Row] = [.overview, .runAll]
        if store.lastRequestFailed { today.append(.requestError) }
        var sections: [(Section, [Row])] = [(.today, today)]
        sections += CheckInPlatform.allCases.map { (.platform($0), [.platform($0)]) }
        let tasks = store.results.flatMap { result in
            (result.details ?? []).indices.map { Row.detail(result.platform, $0) }
        }
        if !tasks.isEmpty {
            sections.append((.growth, growthExpanded ? [.growth] + tasks : [.growth]))
        }
        sections.append((.automatic, [.automatic]))
        logSnapshot = Array(store.logEntries.prefix(10))
        if !logSnapshot.isEmpty {
            sections.append((.history, logSnapshot.map { .log($0.platform, $0.updatedAt) }))
        }
        let changed = Set(sections.filter { $0.0 != .history }.flatMap { $0.1 })
        dataSource.update(sections, changedItems: changed, animatingDifferences: false)
    }

    private func cell(in table: UITableView, for row: Row) -> UITableViewCell {
        let store = CheckInStore.shared
        switch row {
        case .overview:
            let cell = (table.dequeueReusableCell(withIdentifier: CheckInOverviewCell.reuseID) as? CheckInOverviewCell)
                ?? CheckInOverviewCell(style: .default, reuseIdentifier: CheckInOverviewCell.reuseID)
            let eligible = store.results.filter {
                $0.isDone || ($0.outcome == .failed && $0.reason != .signedOut)
            }.count
            let done = store.doneCount
            let progress = eligible == 0 ? 0 : Double(done) / Double(eligible)
            let summary: String
            if eligible > 0 {
                summary = String(localized: "\(done) / \(eligible) checked in")
            } else if store.results.isEmpty {
                summary = String(localized: "No check-in results yet")
            } else {
                summary = String(localized: "No eligible platforms in these results")
            }
            let complete = store.results.count == CheckInPlatform.allCases.count && eligible > 0 && done == eligible
            cell.configure(summary: summary, progress: progress, complete: complete)
            return cell
        case .runAll:
            let running = store.isRunning
            return listCell(title: running ? String(localized: "Checking In…") : String(localized: "Check In All"),
                            icon: running ? "clock" : "checkmark.circle", color: .tintColor, actionable: !running)
        case .requestError:
            return listCell(title: String(localized: "Something went wrong. Try again."),
                            icon: "exclamationmark.circle", color: .systemRed)
        case .automatic:
            let cell = listCell(title: String(localized: "Automatic Check-In"))
            let toggle = UISwitch()
            toggle.isOn = store.automaticEnabled
            toggle.accessibilityLabel = String(localized: "Automatic Check-In")
            toggle.addTarget(self, action: #selector(toggleChanged(_:)), for: .valueChanged)
            cell.accessoryView = toggle
            return cell
        case let .platform(platform):
            let result = store.result(for: platform)
            let running = store.runningPlatforms.contains(platform)
            let state = running ? PlatformState.running : PlatformState(result)
            var lines = [state.title]
            if let result { lines += metrics(for: result) }
            if !store.isRunning { lines.append(state.action) }
            return listCell(title: platform.brand, detail: lines.joined(separator: "\n"),
                            icon: state.icon, color: state.color, actionable: !store.isRunning)
        case .growth:
            let details = store.results.flatMap { $0.details ?? [] }
            let needsAttention = details.filter { !$0.succeeded }.count
            let detail = needsAttention > 0 ? String(localized: "Needs attention: \(needsAttention)") : nil
            return listCell(title: String(localized: "Growth Tasks"), detail: detail,
                            icon: growthExpanded ? "chevron.down" : "chevron.right", color: .tintColor,
                            actionable: true)
        case let .detail(platform, index):
            guard let details = store.result(for: platform)?.details, details.indices.contains(index) else {
                return UITableViewCell()
            }
            let item = details[index]
            let status = item.succeeded ? String(localized: "Done") : String(localized: "Needs Attention")
            return listCell(title: item.title, detail: status + " · " + item.note,
                            icon: item.succeeded ? "checkmark.circle" : "exclamationmark.circle",
                            color: item.succeeded ? .systemGreen : .systemOrange)
        case let .log(platform, date):
            guard let entry = logSnapshot.first(where: { $0.platform == platform && $0.updatedAt == date }) else {
                return UITableViewCell()
            }
            let state = PlatformState(entry)
            let details = [state.title, date.formatted(date: .abbreviated, time: .shortened)] + metrics(for: entry)
            return listCell(title: platform.brand, detail: details.joined(separator: " · "),
                            icon: state.icon, color: state.color)
        }
    }

    @objc private dynamic func listCell(title: String, detail: String? = nil, icon: String? = nil,
                                        color: UIColor = .secondaryLabel, actionable: Bool = false) -> UITableViewCell {
        let cell = UITableViewCell()
        var content = UIListContentConfiguration.subtitleCell()
        content.text = title
        content.secondaryText = detail
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        if let icon {
            content.image = UIImage(systemName: icon)
            content.imageProperties.tintColor = color
        }
        cell.contentConfiguration = content
        cell.selectionStyle = actionable ? .default : .none
        if actionable { cell.accessibilityTraits.insert(.button) }
        return cell
    }

    private func metrics(for result: CheckInResult) -> [String] {
        var lines: [String] = []
        if let credit = result.credit {
            lines.append(String(localized: "Points earned: \(credit)"))
        }
        if result.platform == .workBuddy || result.platform == .workBuddyAI, let total = result.total {
            lines.append(String(localized: "Total check-in points earned: \(total)"))
        }
        if let streak = result.streak, streak > 0 {
            lines.append(String(localized: "Streak \(streak) Days"))
        }
        return lines
    }

    @objc private dynamic func toggleChanged(_ toggle: UISwitch) {
        CheckInStore.shared.automaticEnabled = toggle.isOn
        if toggle.isOn { CheckInStore.shared.automaticRunIfNeeded() }
    }

    private func run(_ platforms: [CheckInPlatform]) {
        Task { [weak self] in
            let results = await CheckInStore.shared.refresh(platforms: platforms, force: true)
            guard self?.viewIfLoaded?.window != nil,
                  results.contains(where: \.isDone),
                  !results.contains(where: { $0.outcome == .failed }) else { return }
            SPIndicator.present(title: String(localized: "Checked In"), preset: .done, haptic: .success)
        }
    }

    private func openSignIn(for platform: CheckInPlatform) {
        let provider: AgentProvider
        switch platform {
        case .workBuddy: provider = .workBuddy
        case .workBuddyAI: provider = .workBuddyAI
        case .traeCN: provider = .trae
        case .qoderCN: provider = .qoderCN
        case .qoder: provider = .qoder
        }
        Task { [weak self] in
            let response = try? await ApelinService.app.agentAccountList(onlyExtraModels: true)
            guard let self, viewIfLoaded?.window != nil, navigationController?.topViewController === self,
                  presentedViewController == nil else { return }
            guard let account = response?.accounts.first(where: { $0.provider == provider }) else {
                navigationController?.pushViewController(ModelProvidersController(), animated: true)
                return
            }
            let page = ProviderLoginController(account: account)
            page.isModalInPresentation = true
            // 登录结束后把状态交回手动按钮，不在登录回调里自动领取奖励。
            page.onSuccessfulSignIn = {
                CheckInStore.shared.clearSignInFailure(for: platform)
            }
            presentPageAsFormSheet(page)
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath) else { return false }
        switch row {
        case .runAll, .platform: return !CheckInStore.shared.isRunning
        case .growth: return true
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        let store = CheckInStore.shared
        switch row {
        case .runAll where !store.isRunning: run([])
        case let .platform(platform) where !store.isRunning:
            let result = store.result(for: platform)
            if result?.outcome == .notSignedIn || result?.reason == .signedOut {
                openSignIn(for: platform)
            } else {
                run([platform])
            }
        case .growth:
            growthExpanded.toggle()
            updateRows()
        default: break
        }
    }
}

private enum PlatformState {
    case pending, running, done, noReward, signedOut, failed(CheckInReason?)

    init(_ result: CheckInResult?) {
        guard let result else { self = .pending; return }
        switch result.outcome {
        case .claimed, .alreadyClaimed: self = .done
        case .nothingToDo: self = .noReward
        case .notSignedIn: self = .signedOut
        case .failed: self = .failed(result.reason)
        }
    }

    var title: String {
        switch self {
        case .pending: return String(localized: "Waiting")
        case .running: return String(localized: "Checking In…")
        case .done: return String(localized: "Checked In")
        case .noReward: return String(localized: "No Reward Today")
        case .signedOut: return String(localized: "Not Signed In")
        case .failed(.signedOut?): return String(localized: "Sign-In Expired")
        case .failed(.network?): return String(localized: "No Internet Connection")
        case .failed(.rateLimited?): return String(localized: "Usage Limit Reached")
        case .failed(.rejected?): return String(localized: "Request Refused")
        case .failed: return String(localized: "Failed")
        }
    }

    var action: String {
        switch self {
        case .signedOut: return String(localized: "Sign In")
        case .failed(.signedOut?): return String(localized: "Sign In Again")
        case .failed: return String(localized: "Retry")
        case .done, .noReward: return String(localized: "Check In Again")
        case .pending, .running: return String(localized: "Check In")
        }
    }

    var icon: String {
        switch self {
        case .pending, .running: return "clock"
        case .done: return "checkmark.circle.fill"
        case .noReward: return "minus.circle"
        case .signedOut, .failed(.signedOut?): return "person.crop.circle"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    var color: UIColor {
        switch self {
        case .done: return .systemGreen
        case .running: return .tintColor
        case .failed(.signedOut?), .signedOut: return .systemOrange
        case .failed: return .systemRed
        default: return .secondaryLabel
        }
    }
}

private final class CheckInOverviewCell: UITableViewCell {
    static let reuseID = "check-in-overview"
    private let heading = UILabel()
    private let summary = UILabel()
    private let ring = ProgressRing()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        isAccessibilityElement = true
        accessibilityTraits.insert(.header)
        heading.text = String(localized: "Today’s Check-In")
        heading.font = .preferredFont(forTextStyle: .headline)
        summary.font = .preferredFont(forTextStyle: .title2)
        summary.textColor = .secondaryLabel
        for label in [heading, summary] {
            label.numberOfLines = 0
            label.adjustsFontForContentSizeCategory = true
        }
        let text = UIStackView(arrangedSubviews: [heading, summary])
        text.axis = .vertical
        text.spacing = 4
        let row = UIStackView(arrangedSubviews: [text, ring])
        row.alignment = .center
        row.spacing = 12
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        let guide = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
            row.topAnchor.constraint(equalTo: guide.topAnchor, constant: 8),
            row.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -8),
            ring.widthAnchor.constraint(equalToConstant: 44),
            ring.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    @objc dynamic func configure(summary: String, progress: Double, complete: Bool) {
        self.summary.text = summary
        accessibilityLabel = heading.text
        accessibilityValue = summary
        ring.tintColor = complete ? .systemGreen : .tintColor
        ring.set(complete ? .glyph("checkmark.circle.fill") : .progress(progress), animated: false)
    }
}
