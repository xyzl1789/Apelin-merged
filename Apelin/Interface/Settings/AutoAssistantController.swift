import ApelinCore
import ApelinProtocol
import UIKit

/// Settings ▸ Agent ▸ Auto Assistant.
///
/// Three independent switches, an action that measures every signed-in model
/// and leaves the reader on the fastest one, and an editor for the exclusions
/// both the measurement and the send path honour. Every switch is off until
/// the reader turns it on: the app never changes their model on its own.
final class AutoAssistantController: TableController {
    private enum Section: Hashable, CaseIterable {
        case behaviour
        case models
        case exclusions
    }

    private enum Row: Hashable {
        case switchOnFailure
        case retryOnTimeout
        case pickFastest
        case excludeProviders
        case excludeModels
    }

    private struct RowContent: Equatable {
        let row: Row
    }

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, row in
        self?.cell(in: table, content: row)
    }

    private var measuring = false

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
    }

    @objc private dynamic func updateRows() {
        dataSource.update([
            (.behaviour, [
                RowContent(row: .switchOnFailure),
                RowContent(row: .retryOnTimeout),
            ]),
            (.models, [RowContent(row: .pickFastest)]),
            (.exclusions, [
                RowContent(row: .excludeProviders),
                RowContent(row: .excludeModels),
            ]),
        ], reconfigure: true)
    }

    private func header(for section: Section) -> String? {
        switch section {
        case .behaviour: String(localized: "Automatic Behaviour")
        case .models: String(localized: "Measure Models")
        case .exclusions: String(localized: "Exclusions")
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .behaviour:
            String(localized: "Auto Assistant Footnote")
        case .models: String(localized: "Measure Models Footnote")
        case .exclusions: String(localized: "Exclusions Footnote")
        }
    }

    private var switchRows: Set<Row> {
        [.switchOnFailure, .retryOnTimeout]
    }

    private func isOn(_ row: Row) -> Bool {
        switch row {
        case .switchOnFailure: ModelExclusions.Automatic.switchOnFailure.isEnabled
        case .retryOnTimeout: ModelExclusions.Automatic.retryOnTimeout.isEnabled
        default: false
        }
    }

    /// A rule is set through `ModelExclusions`, which owns the defaults key;
    /// the enum's own property is only the reader for it.
    private func set(_ row: Row, on: Bool) {
        switch row {
        case .switchOnFailure: ModelExclusions.setAutomatic(.switchOnFailure, on: on)
        case .retryOnTimeout: ModelExclusions.setAutomatic(.retryOnTimeout, on: on)
        default: break
        }
        updateRows()
    }

    private func title(for row: Row) -> String {
        switch row {
        case .switchOnFailure: String(localized: "Switch Model on Failure")
        case .retryOnTimeout: String(localized: "Retry on Timeout")
        case .pickFastest: String(localized: "Measure Now and Use Fastest")
        case .excludeProviders: String(localized: "Excluded Providers")
        case .excludeModels: String(localized: "Excluded Models")
        }
    }

    /// The switch's stable tag identifies its action across reused cells.
    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "auto-assistant")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "auto-assistant")
        var content = UIListContentConfiguration.valueCell()
        content.text = title(for: value.row)
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.selectionStyle = .default
        if switchRows.contains(value.row) {
            cell.selectionStyle = .none
            let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
            toggle.isOn = isOn(value.row)
            toggle.tag = value.row == .switchOnFailure ? 1 : 2
            toggle.removeTarget(nil, action: nil, for: .valueChanged)
            toggle.addTarget(self, action: #selector(switchChanged(_:)), for: .valueChanged)
            toggle.accessibilityLabel = content.text
            cell.accessoryView = toggle
        } else {
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
            if value.row == .pickFastest, measuring {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
                cell.accessoryType = .none
            }
        }
        return cell
    }

    @objc private dynamic func switchChanged(_ toggle: UISwitch) {
        guard toggle.tag == 1 || toggle.tag == 2 else { return }
        set(toggle.tag == 1 ? .switchOnFailure : .retryOnTimeout, on: toggle.isOn)
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath)?.row else { return false }
        return !switchRows.contains(row)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .switchOnFailure, .retryOnTimeout:
            break // 开关处理
        case .pickFastest:
            measureAndUseFastest()
        case .excludeProviders:
            push(ExcludedProvidersController(style: .insetGrouped))
        case .excludeModels:
            push(ExcludedModelsController(style: .insetGrouped))
        }
    }

    private func push(_ page: UIViewController) {
        navigationController?.pushViewController(page, animated: true)
    }

    // MARK: - Measure every signed-in model, use the fastest

    private func measureAndUseFastest() {
        guard !measuring else { return }
        measuring = true
        updateRows()
        Task { [weak self] in
            guard let self else { return }
            defer {
                measuring = false
                updateRows()
            }
            do {
                let selected = try await ProgressCard.run(
                    title: String(localized: "Measuring Models"),
                    message: String(localized: "Testing each signed-in model…"),
                    cancellable: true,
                    from: self,
                ) { update in
                    try await ModelSpeedPicker.pickFastest { measured, total in
                        update(ProgressCard.Status(
                            subtitle: String(localized: "Testing each signed-in model…"),
                            fraction: Double(measured) / Double(max(total, 1)),
                            count: "\(measured) / \(total)",
                        ))
                    }
                }
                guard !Task.isCancelled else { return }
                guard let selected else {
                    presentNotice(
                        title: "No Model Available",
                        message: "None of the signed-in models answered, or all were excluded.",
                    )
                    return
                }
                // 选最快改的是全局默认：下一个新对话从这里起步，正在进行的
                // 对话不被打断。
                ComposerModelSelection.current = selected
                presentNotice(
                    title: "Fastest Model Selected",
                    message: String(format: String(localized: "Now using %@ from %@."), selected.model, selected.provider.displayName),
                )
            } catch is CancellationError {
                // 用户取消，无需提示。
            } catch {
                presentNotice(title: "Unable to Measure Models", message: error.readableMessage)
            }
        }
    }
}
