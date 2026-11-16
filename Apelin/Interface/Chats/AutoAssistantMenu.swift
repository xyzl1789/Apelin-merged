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

    private static func content(text: String, image: UIImage?) -> UIListContentConfiguration {
        var config = UIListContentConfiguration.cell()
        config.text = text
        config.textProperties.color = .label
        config.image = image
        config.imageToTextPadding = 12
        return config
    }

    private var settings: AutoAssistantPolicy {
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

    /// 同 `AutoAssistantMenu` 早期的实现：测速选中最快的模型，落到这条对话上。
    private func measureAndUseFastest(for id: UUID, from controller: UIViewController) {
        Task { @MainActor in
            do {
                let selected = try await ProgressCard.run(
                    title: String(localized: "Measuring Models"),
                    message: String(localized: "Testing each signed-in model…"),
                    cancellable: true,
                    from: controller,
                ) { update in
                    try await ModelSpeedPicker.pickFastest(progress: { measured, total in
                        update(ProgressCard.Status(
                            subtitle: String(localized: "Testing each signed-in model…"),
                            fraction: Double(measured) / Double(max(total, 1)),
                            count: "\(measured) / \(total)",
                        ))
                    })
                }
                guard !Task.isCancelled else { return }
                guard let selected else {
                    controller.presentNotice(
                        title: "No Model Available",
                        message: "None of the signed-in models answered, or all were excluded.",
                    )
                    return
                }
                ComposerModelSelection.choose(selected, for: id)
                ComposerModelSelection.rememberSelection(selected)
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
