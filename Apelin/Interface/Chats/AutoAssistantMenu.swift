import ApelinProtocol
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
            controller?.present(AutoAssistantSheet(id: id), animated: true)
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
        case measure
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
        tableView.reloadData()
    }

    @objc private func done() {
        dismiss(animated: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        // 排除页可能改了排除名单，回来时开关状态重读一遍。
        tableView.reloadData()
    }

    /// 上一次测量的完整排名，快到慢；没有测过就是空。结果随弹层的生命周期
    /// 保留，测一次够这一轮用。
    static var lastResults: [ModelSpeedPicker.Result] = []

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
        case .measure:
            cell.contentConfiguration = Self.content(
                text: String(localized: "Measure Now and Use Fastest"),
                image: UIImage(systemName: "speedometer"),
            )
            cell.accessoryType = .none
            cell.selectionStyle = .default
        case .measureResults:
            let has = !Self.lastResults.isEmpty
            cell.contentConfiguration = Self.content(
                text: String(localized: "Last Measurement"),
                image: UIImage(systemName: "list.bullet.clipboard"),
            )
            cell.accessoryType = has ? .disclosureIndicator : .none
            cell.selectionStyle = has ? .default : .none
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
        case .measure:
            measureAndUseFastest(for: id, from: self)
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

    /// 同 `AutoAssistantMenu` 早期的实现：测速选中最快的模型，落到这条对话上，
    /// 完整排名留给「上次测量」页看。
    private func measureAndUseFastest(for id: UUID, from controller: UIViewController) {
        Task { @MainActor in
            do {
                let measured = try await ProgressCard.run(
                    title: String(localized: "Measuring Models"),
                    message: String(localized: "Testing each signed-in model…"),
                    cancellable: true,
                    from: controller,
                ) { update in
                    try await ModelSpeedPicker.measureAll(progress: { measured, total in
                        update(ProgressCard.Status(
                            subtitle: String(localized: "Testing each signed-in model…"),
                            fraction: Double(measured) / Double(max(total, 1)),
                            count: "\(measured) / \(total)",
                        ))
                    })
                }
                guard !Task.isCancelled else { return }
                Self.lastResults = measured.results
                guard let selected = measured.fastest else {
                    controller.presentNotice(
                        title: "No Model Available",
                        message: "None of the signed-in models answered, or all were excluded.",
                    )
                    self.tableView.reloadData()
                    return
                }
                ComposerModelSelection.choose(selected, for: id)
                ComposerModelSelection.rememberSelection(selected)
                self.tableView.reloadData()
                controller.presentNotice(
                    title: "Fastest Model Selected",
                    message: String(
                        format: String(localized: "Now using %@ from %@."),
                        selected.model,
                        selected.provider.displayName,
                    ),
                )
            } catch is CancellationError {
                // The reader cancelled: nothing to say.
            } catch {
                controller.presentNotice(title: "Unable to Measure Models", message: error.readableMessage)
            }
        }
    }
}

/// 「上次测量」的结果页：每个成功的模型一行，快到慢，点击切到那个模型。
@MainActor
final class MeasurementResultsController: UITableViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Last Measurement")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int {
        max(AutoAssistantSheet.lastResults.count, 1)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "measurement")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "measurement")
        let results = AutoAssistantSheet.lastResults
        guard indexPath.row < results.count else {
            var config = cell.defaultContentConfiguration()
            config.text = String(localized: "No Model Answered")
            config.textProperties.color = .secondaryLabel
            cell.contentConfiguration = config
            cell.accessoryType = .none
            return cell
        }
        let result = results[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = result.selection.model
        config.secondaryText = result.selection.provider.displayName
        config.textProperties.color = .label
        config.secondaryTextProperties.color = .secondaryLabel
        config.image = UIImage(systemName: indexPath.row == 0 ? "trophy" : "clock")
        config.imageToTextPadding = 12
        cell.contentConfiguration = config
        cell.detailTextLabel?.text = nil
        // 附件用 accessoryView 放毫秒数，value1 的 detailTextLabel 与
        // contentConfiguration 并存时后者的 secondaryText 已经承担了它。
        let label = UILabel()
        label.text = String(format: "%.0f ms", result.milliseconds)
        label.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        label.textColor = indexPath.row == 0 ? .systemGreen : .secondaryLabel
        label.sizeToFit()
        label.accessibilityLabel = String(
            format: String(localized: "%@ milliseconds"), NSNumber(value: result.milliseconds),
        )
        cell.accessoryView = label
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let results = AutoAssistantSheet.lastResults
        guard indexPath.row < results.count else { return }
        let selection = results[indexPath.row].selection
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
