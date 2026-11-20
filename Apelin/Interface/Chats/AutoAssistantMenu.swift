import ApelinProtocol
import SPIndicator
import UIKit

/// The automatic assistant, one entry in the conversation's More (…) menu:
/// 「自动助手…」, which puts up a sheet where the two switches, the
/// measurement and the exclusions are picked. Flat items stayed too crowded;
/// one entry keeps the menu short and the sheet carries everything.
///
/// The state is read when the menu opens, never captured when it is built:
/// the sheet always shows the values as they are now.
enum AutoAssistantMenu {
    /// The one entry for one conversation. `controller` is where the sheet
    /// shows and the exclusions push their pages from; the action keeps it
    /// weakly.
    @MainActor
    static func actions(for id: UUID, in controller: UIViewController) -> [UIMenu] {
        let entry = UIAction(
            title: String(localized: "Auto Assistant…"),
            image: UIImage(systemName: "wand.and.stars"),
        ) { [weak controller] _ in
            guard let controller else { return }
            // 三个子页（上次测量、排除供应商、排除模型）都往导航栈里推，
            // 所以弹层必须自己带一个导航控制器，否则推入什么都不发生。
            let sheet = AutoAssistantSheet(id: id)
            let navigation = UINavigationController(rootViewController: sheet)
            controller.present(navigation, animated: true)
        }
        return [UIMenu(options: .displayInline, children: [entry])]
    }
}

/// The sheet 「自动助手…」 opens: the two switches, the measure action and
/// the two exclusion pages, in one grouped table.
@MainActor
final class AutoAssistantSheet: UITableViewController {
    private enum Row: Int, CaseIterable {
        case switchOnFailure
        case retryOnTimeout
        case retryDelay
        case measure
        case autoMeasureInterval
        case measureResults
        case excludedProviders
        case excludedModels
    }

    private let id: UUID

    init(id: UUID) {
        self.id = id
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Auto Assistant")
        navigationItem.rightBarButtonItem = UIBarButtonItem(barButtonSystemItem: .done, target: self, action: #selector(done))
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleChanged),
            name: .measurementScheduleChanged, object: nil,
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleChanged),
            name: MeasurementRunner.changed, object: nil,
        )
        tableView.reloadData()
    }

    @objc private func scheduleChanged() {
        tableView.reloadData()
    }

    @objc private func done() {
        dismiss(animated: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 排除页可能改了排除名单，测速也可能在后台结束，回来时重读一遍。
        tableView.reloadData()
    }

    /// 上一次测量的完整结果，成功在前、失败在后；没有测过就是空。结果落盘，
    /// 设置页与对话菜单共用同一份，重启后仍在。
    static var lastResults: [ModelSpeedPicker.Result] {
        get { MeasurementStore.load().results }
        set { MeasurementStore.save(results: newValue) }
    }

    /// 上次测速完成的时间；从没测过就是 nil。结果页在页脚显示它。
    static var lastMeasuredAt: Date? {
        MeasurementStore.load().measuredAt
    }

    private static func content(text: String, image: UIImage?) -> UIListContentConfiguration {
        var config = UIListContentConfiguration.cell()
        config.text = text
        config.textProperties.color = .label
        config.image = image
        config.imageToTextPadding = 12
        return config
    }

    private var settings: AutoAssistantPolicy.Settings {
        AutoAssistantPolicy.current(for: id)
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "auto-assistant")
            ?? UITableViewCell(style: .default, reuseIdentifier: "auto-assistant")
        let row = Row(rawValue: indexPath.row) ?? .switchOnFailure
        switch row {
        case .switchOnFailure:
            cell.contentConfiguration = Self.content(
                text: String(localized: "Switch Model on Failure"),
                image: UIImage(systemName: "arrow.triangle.swap"),
            )
            cell.accessoryType = settings.switchOnFailure ? .checkmark : .none
            cell.selectionStyle = .default
        case .retryOnTimeout:
            cell.contentConfiguration = Self.content(
                text: String(localized: "Retry on Timeout"),
                image: UIImage(systemName: "clock.arrow.circlepath"),
            )
            cell.accessoryType = settings.retryOnTimeout ? .checkmark : .none
            cell.selectionStyle = .default
        case .retryDelay:
            var config = UIListContentConfiguration.valueCell()
            config.text = String(localized: "Retry Wait Time")
            config.textProperties.color = settings.retryOnTimeout ? .label : .secondaryLabel
            config.secondaryText = AutoAssistantPolicy.RetryDelay(
                rawValue: settings.retryDelaySeconds,
            )?.title ?? AutoAssistantPolicy.RetryDelay.twenty.title
            config.secondaryTextProperties.color = .secondaryLabel
            config.image = UIImage(systemName: "hourglass")
            config.imageToTextPadding = 12
            cell.contentConfiguration = config
            cell.accessoryType = settings.retryOnTimeout ? .disclosureIndicator : .none
            cell.selectionStyle = settings.retryOnTimeout ? .default : .none
        case .measure:
            let running = MeasurementRunner.shared.isRunning
            cell.contentConfiguration = Self.content(
                text: String(localized: running ? "Measuring Models in Background" : "Measure Models in Background"),
                image: UIImage(systemName: "speedometer"),
            )
            cell.accessoryType = .none
            if running {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
            } else {
                cell.accessoryView = nil
            }
            cell.selectionStyle = running ? .none : .default
        case .measureResults:
            let has = !Self.lastResults.isEmpty
            cell.contentConfiguration = Self.content(
                text: String(localized: "Last Measurement"),
                image: UIImage(systemName: "list.bullet.clipboard"),
            )
            cell.accessoryType = has ? .disclosureIndicator : .none
            cell.selectionStyle = has ? .default : .none
        case .autoMeasureInterval:
            var config = UIListContentConfiguration.valueCell()
            config.text = String(localized: "Auto Measure Interval")
            config.textProperties.color = .label
            config.secondaryText = MeasurementSchedule.interval.title
            config.secondaryTextProperties.color = .secondaryLabel
            config.image = UIImage(systemName: "timer")
            config.imageToTextPadding = 12
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .excludedProviders:
            cell.contentConfiguration = Self.content(
                text: String(localized: "Excluded Providers"),
                image: UIImage(systemName: "person.crop.circle.badge.xmark"),
            )
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .excludedModels:
            cell.contentConfiguration = Self.content(
                text: String(localized: "Excluded Models"),
                image: UIImage(systemName: "minus.circle"),
            )
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }
        return cell
    }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        String(localized: "Auto Assistant Sheet Footer")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch Row(rawValue: indexPath.row) {
        case .switchOnFailure:
            var next = settings
            next.switchOnFailure.toggle()
            AutoAssistantPolicy.set(next, for: id)
            tableView.reloadData()
        case .retryOnTimeout:
            var next = settings
            next.retryOnTimeout.toggle()
            AutoAssistantPolicy.set(next, for: id)
            tableView.reloadData()
        case .retryDelay:
            guard settings.retryOnTimeout else { break }
            let sheet = UIAlertController(
                title: String(localized: "Retry Wait Time"),
                message: nil, preferredStyle: .actionSheet,
            )
            for delay in AutoAssistantPolicy.RetryDelay.allCases {
                let current = delay.rawValue == settings.retryDelaySeconds
                let action = UIAlertAction(
                    title: current ? "✓ " + delay.title : delay.title, style: .default,
                ) { _ in
                    var next = self.settings
                    next.retryDelaySeconds = delay.rawValue
                    AutoAssistantPolicy.set(next, for: self.id)
                    tableView.reloadData()
                }
                sheet.addAction(action)
            }
            sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            sheet.popoverPresentationController?.sourceView = tableView
            sheet.popoverPresentationController?.sourceRect = CGRect(
                x: tableView.bounds.midX, y: tableView.bounds.midY, width: 0, height: 0,
            )
            sheet.popoverPresentationController?.permittedArrowDirections = []
            present(sheet, animated: true)
        case .measure:
            MeasurementRunner.shared.start(from: self)
        case .autoMeasureInterval:
            presentMeasurementIntervalPicker(sourceView: tableView)
        case .measureResults:
            navigationController?.pushViewController(
                MeasurementResultsController(style: .insetGrouped), animated: true,
            )
        case .excludedProviders:
            navigationController?.pushViewController(
                ExcludedProvidersController(style: .insetGrouped), animated: true,
            )
        case .excludedModels:
            navigationController?.pushViewController(
                ExcludedModelsController(style: .insetGrouped), animated: true,
            )
        case nil:
            break
        }
    }
}

/// 测速只在后台跑：没有进度卡片，不切换模型，也不拦着读者留在测速界面。
/// 谁发起都行（设置页或任意会话），同一时间只跑一轮；完成的结果落盘，
/// 「上次测量」页下次打开就能看到全部模型，自动切换从成功的里面选。
@MainActor
final class MeasurementRunner {
    static let shared = MeasurementRunner()

    private(set) var isRunning = false

    private init() {}

    /// 界面订阅这个通知刷新「正在后台测速」的状态。
    static let changed = Notification.Name("autoAssistant.measurementChanged")

    func start(from presenter: UIViewController?) {
        start(from: presenter, silently: false)
    }

    /// 回到前台时按间隔自动触发：只在该跑、且没有别的会话或用户正在跑时启动。
    /// 不弹「全部失败」这类提示——自动测速失败是常态，静默留盘即可。
    static func startAutomaticallyIfDue() {
        guard !shared.isRunning,
              MeasurementSchedule.interval != .off,
              AutoAssistantPolicy.anySwitchEnabled(),
              MeasurementSchedule.isDue() else { return }
        shared.start(from: nil, silently: true)
    }

    private func start(from presenter: UIViewController?, silently: Bool) {
        guard !isRunning else { return }
        isRunning = true
        post()
        // 手动点「在后台测速模型」时立刻回一声，让读者知道点了生效；
        // 回前台按间隔自动跑的静默一轮不打扰人。
        if !silently {
            let notice = String(localized: "Started Measuring Models in Background")
            SPIndicator.present(title: notice, preset: .done, haptic: .success)
            UIAccessibility.post(notification: .announcement, argument: notice)
        }
        Task { @MainActor [weak presenter] in
            defer {
                isRunning = false
                post()
            }
            do {
                let measured = try await ModelSpeedPicker.measureAll()
                AutoAssistantSheet.lastResults = measured.results
                let successful = measured.results.filter(\.success).count
                if successful == 0 && !silently {
                    presenter?.presentNotice(
                        title: "No Model Available",
                        message: "None of the signed-in models answered, or all were excluded.",
                    )
                }
            } catch {
                if !silently {
                    presenter?.presentNotice(title: "Unable to Measure Models", message: error.readableMessage)
                }
            }
        }
    }

    private func post() {
        NotificationCenter.default.post(name: Self.changed, object: self)
    }
}

/// 「上次测量」的落盘：`UserDefaults` 一个键存整份结果。设置页与对话菜单
/// 读同一份，重启后仍在。
enum MeasurementStore {
    private struct Stored: Codable {
        var results: [ModelSpeedPicker.Result]
    }

    private static let storageKey = "autoAssistant.lastMeasurement"

    static func load() -> (results: [ModelSpeedPicker.Result], measuredAt: Date?) {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(Stored.self, from: data)
        else { return ([], nil) }
        let date = UserDefaults.standard.object(forKey: storageKey + ".date") as? Date
        return (decoded.results, date)
    }

    static func save(results: [ModelSpeedPicker.Result]) {
        guard let data = try? JSONEncoder().encode(Stored(results: results)) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
        UserDefaults.standard.set(Date.now, forKey: storageKey + ".date")
    }
}

/// 「上次测量」的结果页：所有参与测速的模型都在，成功的快到慢排在前，
/// 失败的在后并写明原因。点击成功的模型可以切过去；失败的不响应点击。
@MainActor
final class MeasurementResultsController: UITableViewController {
    private enum Section: Int {
        case successful
        case failed
    }

    private var results: [ModelSpeedPicker.Result] = []
    private var sections: [Section] = []

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Last Measurement")
        NotificationCenter.default.addObserver(
            self, selector: #selector(measurementChanged),
            name: MeasurementRunner.changed, object: nil,
        )
        reload()
    }

    @objc private func measurementChanged() {
        reload()
    }

    private func reload() {
        results = AutoAssistantSheet.lastResults
        sections = []
        if results.contains(where: \.success) { sections.append(.successful) }
        if results.contains(where: { !$0.success }) { sections.append(.failed) }
        if sections.isEmpty { sections.append(.successful) }
        tableView.reloadData()
    }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        // 上次测速完成的时间；从没测过（结果页由后台新测量顶起）就没有。
        guard let measuredAt = AutoAssistantSheet.lastMeasuredAt else { return nil }
        return Self.timeFormatter.string(from: measuredAt)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private func results(in section: Int) -> [ModelSpeedPicker.Result] {
        guard sections.indices.contains(section) else { return [] }
        let kind = sections[section]
        return results.filter { kind == .successful ? $0.success : !$0.success }
    }

    override func numberOfSections(in _: UITableView) -> Int {
        sections.count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard sections.indices.contains(section) else { return nil }
        let kind = sections[section]
        return String(localized: kind == .successful ? "Successful Models" : "Failed Models")
    }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        if sections.isEmpty { return 1 }
        return max(results(in: section).count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "measurement")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "measurement")
        var config = cell.defaultContentConfiguration()
        guard sections.indices.contains(indexPath.section) else { return cell }
        let kind = sections[indexPath.section]
        let rows = results(in: indexPath.section)
        guard indexPath.row < rows.count else {
            config.text = String(localized: "No Model Answered")
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = .none
            cell.accessoryView = nil
            cell.selectionStyle = .none
            return cell
        }
        let result = rows[indexPath.row]
        config.text = result.selection.model
        if kind == .successful {
            config.secondaryText = result.selection.provider.displayName
            config.secondaryTextProperties.color = .secondaryLabel
            config.image = UIImage(systemName: indexPath.row == 0 ? "trophy" : "clock")
            let label = UILabel()
            label.text = String(format: "%.0f ms", result.milliseconds)
            label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            label.textColor = indexPath.row == 0 ? .systemGreen : .secondaryLabel
            label.sizeToFit()
            label.accessibilityLabel = String(
                format: String(localized: "%@ milliseconds"), NSNumber(value: result.milliseconds),
            )
            cell.accessoryView = label
            cell.accessoryType = .none
            cell.selectionStyle = .default
        } else {
            config.secondaryText = result.failure ?? String(localized: "Unavailable")
            config.secondaryTextProperties.color = .secondaryLabel
            config.secondaryTextProperties.numberOfLines = 0
            config.image = UIImage(systemName: "xmark.circle")
            cell.accessoryView = nil
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        config.imageToTextPadding = 12
        config.textProperties.color = .label
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section] == .successful else { return }
        let rows = results(in: indexPath.section)
        guard indexPath.row < rows.count else { return }
        let selection = rows[indexPath.row].selection
        ComposerModelSelection.current = selection
        presentNotice(
            title: "Model Selected",
            message: String(
                format: String(localized: "Now using %@ from %@."),
                selection.model,
                selection.provider.displayName,
            ),
        )
    }
}
