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
        case lastMeasurement
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
            (.where_, [RowContent(row: .whereItIs)]),
            (.models, [
                RowContent(row: .pickFastest),
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

    private func title(for row: Row) -> String {
        switch row {
        case .whereItIs: String(localized: "Turn It On in a Conversation")
        case .pickFastest: String(localized: "Measure Now and Use Fastest")
        case .lastMeasurement: String(localized: "Last Measurement")
        case .excludeProviders: String(localized: "Excluded Providers")
        case .excludeModels: String(localized: "Excluded Models")
        }
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "auto-assistant")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "auto-assistant")
        var content = UIListContentConfiguration.valueCell()
        content.text = title(for: value.row)
        cell.contentConfiguration = content
        cell.accessoryType = .none
        cell.selectionStyle = .default
        if value.row == .whereItIs {
            // Nothing to open: the instruction is the whole row.
            cell.selectionStyle = .none
            cell.accessoryView = nil
        } else {
            cell.accessoryView = nil
            cell.accessoryType = .disclosureIndicator
            if value.row == .pickFastest, measuring {
                let spinner = UIActivityIndicatorView(style: .medium)
                spinner.startAnimating()
                cell.accessoryView = spinner
                cell.accessoryType = .none
            }
            if value.row == .lastMeasurement, AutoAssistantSheet.lastResults.isEmpty {
                cell.accessoryType = .none
                cell.selectionStyle = .none
            }
        }
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        dataSource.value(at: indexPath)?.row != .whereItIs
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .whereItIs:
            break
        case .pickFastest:
            measureAndUseFastest()
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

    // MARK: - Measure every signed-in model, use the fastest

    /// From here there is no conversation to apply it to, so it only sets the
    /// default the next new conversation starts on; a conversation's own menu
    /// has the same action, and applies it to that conversation.
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
                // 这里没有具体对话可改，只记成下一次新对话用的默认。
                ComposerModelSelection.current = selected
                presentNotice(
                    title: "Fastest Model Selected",
                    message: String(format: String(localized: "Now using %1$@ from %2$@. New conversations start with it."), selected.model, selected.provider.displayName),
                )
            } catch is CancellationError {
                // 用户取消，无需提示。
            } catch {
                presentNotice(title: "Unable to Measure Models", message: error.readableMessage)
            }
        }
    }
}
