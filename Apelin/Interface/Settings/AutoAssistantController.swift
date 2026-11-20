import ApelinCore
import ApelinProtocol
import UIKit

/// Settings ▸ Agent ▸ Auto Assistant.
///
/// The switches themselves live where they apply: in a conversation's own
/// More (…) menu, so a reader decides per conversation, and a subagent
/// follows the conversation that opened it. What is left here is what is not
/// bound to one conversation — measuring every model, and the exclusions both
/// the measurement and the send path honour — plus a line saying where the
/// switches went.
final class AutoAssistantController: TableController {
    private enum Section: Hashable, CaseIterable {
        case where_
        case models
        case exclusions
    }

    private enum Row: Hashable {
        case whereItIs
        case pickFastest
        case autoMeasureInterval
        case lastMeasurement
        case excludeProviders
        case excludeModels
    }

    private struct RowContent: Equatable {
        let row: Row
        /// 显示值进内容里，间隔或测速状态一变数据源就认出这行要重绘。
        var measureRunning = false
        var intervalTitle = ""
    }

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, row in
        self?.cell(in: table, content: row)
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Auto Assistant")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.headerTitle = { [weak self] in self?.header(for: $0) }
        dataSource.footerTitle = { [weak self] in self?.footer(for: $0) }
        updateRows()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRows),
            name: .modelExclusionsChanged,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRows),
            name: MeasurementRunner.changed,
            object: nil,
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRows),
            name: .measurementScheduleChanged,
            object: nil,
        )
    }

    @objc private dynamic func updateRows() {
        let running = MeasurementRunner.shared.isRunning
        let interval = MeasurementSchedule.interval.title
        dataSource.update([
            (.where_, [RowContent(row: .whereItIs)]),
            (.models, [
                RowContent(row: .pickFastest, measureRunning: running),
                RowContent(row: .autoMeasureInterval, intervalTitle: interval),
                RowContent(row: .lastMeasurement),
            ]),
            (.exclusions, [
                RowContent(row: .excludeProviders),
                RowContent(row: .excludeModels),
            ]),
        ], reconfigure: true)
    }

    private func header(for section: Section) -> String? {
        switch section {
        case .where_: nil
        case .models: String(localized: "Measure Models")
        case .exclusions: String(localized: "Exclusions")
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .where_: String(localized: "Auto Assistant Lives in the Conversation")
        case .models: String(localized: "Measure Models Footnote")
        case .exclusions: String(localized: "Exclusions Footnote")
        }
    }

    private func title(for row: Row, running: Bool) -> String {
        switch row {
        case .whereItIs: String(localized: "Turn It On in a Conversation")
        case .pickFastest:
            String(localized: running
                ? "Measuring Models in Background" : "Measure Models in Background")
        case .autoMeasureInterval: String(localized: "Auto Measure Interval")
        case .lastMeasurement: String(localized: "Last Measurement")
        case .excludeProviders: String(localized: "Excluded Providers")
        case .excludeModels: String(localized: "Excluded Models")
        }
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "auto-assistant")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "auto-assistant")
        var content = UIListContentConfiguration.valueCell()
        content.text = title(for: value.row, running: value.measureRunning)
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.accessoryView = nil
        cell.selectionStyle = .default
        if value.row == .autoMeasureInterval {
            var valued = content
            valued.secondaryText = value.intervalTitle
            valued.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = valued
        }
        if value.row == .whereItIs {
            // Nothing to open: the instruction is the whole row.
            cell.selectionStyle = .none
        } else {
            // 这些行才进下一级页面，才给 >。
            cell.accessoryType = .disclosureIndicator
            // 测速是就地执行的动作，不是进页面：永不给 >，跑起来改转圈。
            if value.row == .pickFastest {
                cell.accessoryType = .none
                if value.measureRunning {
                    let spinner = UIActivityIndicatorView(style: .medium)
                    spinner.startAnimating()
                    cell.accessoryView = spinner
                }
            }
            if value.row == .lastMeasurement, AutoAssistantSheet.lastResults.isEmpty {
                cell.accessoryType = .none
                cell.selectionStyle = .none
            }
        }
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let content = dataSource.value(at: indexPath) else { return false }
        if content.row == .pickFastest, content.measureRunning { return false }
        return content.row != .whereItIs
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .whereItIs:
            break
        case .pickFastest:
            MeasurementRunner.shared.start(from: self)
        case .autoMeasureInterval:
            presentMeasurementIntervalPicker(sourceView: tableView)
        case .lastMeasurement:
            push(MeasurementResultsController(style: .insetGrouped))
        case .excludeProviders:
            push(ExcludedProvidersController(style: .insetGrouped))
        case .excludeModels:
            push(ExcludedModelsController(style: .insetGrouped))
        }
    }

    private func push(_ page: UIViewController) {
        navigationController?.pushViewController(page, animated: true)
    }
}
