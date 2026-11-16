import ApelinProtocol
import ProgressCard
import UIKit

// MARK: - Excluded providers

/// Every provider the app can sign in to, each with a switch. Turning one on
/// keeps the automatic assistant (and the speed test) from using that whole
/// provider. The set is stored by `ModelExclusions`.
final class ExcludedProvidersController: TableController {
    private struct Row: Equatable {
        let provider: AgentProvider
        let title: String
    }

    private lazy var dataSource = TableDataSource<Int, String, Row>(
        tableView: tableView,
        identifier: { $0.provider.rawValue },
    ) { [weak self] table, _, row in
        guard let self else { return nil }
        let cell = table.dequeueReusableCell(withIdentifier: "provider") ?? UITableViewCell()
        var content = UIListContentConfiguration.cell()
        content.text = row.title
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
        toggle.isOn = ModelExclusions.isProviderExcluded(row.provider)
        toggle.accessibilityLabel = row.title
        toggle.accessibilityIdentifier = row.provider.rawValue
        toggle.removeTarget(nil, action: nil, for: .valueChanged)
        toggle.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private var rows: [Row] {
        var providers = AgentProvider.allCases
        // Further OpenAI-compatible endpoints the reader added and then
        // excluded still have a rule here even though they are not in allCases.
        let known = Set(providers.map(\.rawValue))
        for raw in ModelExclusions.stored.providers where !known.contains(raw),
            let extra = AgentProvider(rawValue: raw)
        {
            providers.append(extra)
        }
        return providers.map { Row(provider: $0, title: $0.displayName) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Excluded Providers")
        dataSource.footerTitle = { _ in String(localized: "Excluded Providers Footnote") }
        updateRows()
    }

    @objc private dynamic func updateRows() {
        dataSource.update([(0, rows)], reconfigure: true)
    }

    @objc private dynamic func changed(_ toggle: UISwitch) {
        guard let raw = toggle.accessibilityIdentifier,
              let provider = AgentProvider(rawValue: raw)
        else { return }
        ModelExclusions.setProvider(provider, excluded: toggle.isOn)
    }
}

// MARK: - Excluded models

/// Individual models, named together with the provider they belong to. The
/// list starts with every model the signed-in accounts offer and a switch on
/// each; a typed rule adds any model id, useful for a relay whose model list
/// changes or a provider the app is signed out of right now.
final class ExcludedModelsController: TableController {
    private struct Row: Hashable {
        var provider: String
        var model: String
        var title: String
        var subtitle: String
    }

    private enum Section: Hashable {
        case accountModels
        case custom
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] table, _, row in
        guard let self else { return nil }
        let cell = table.dequeueReusableCell(withIdentifier: "model") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "model")
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.model
        content.secondaryText = row.subtitle
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
        toggle.isOn = ModelExclusions.stored.models.contains { $0.provider == row.provider && $0.model == row.model }
        toggle.tag = row.hashValue
        toggle.accessibilityLabel = row.model
        toggle.removeTarget(nil, action: nil, for: .valueChanged)
        toggle.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    private var fromAccounts: [Row] = []
    private var custom: [Row] = []
    private var loader: Task<Void, Never>?

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Excluded Models")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(addRule),
        )
        navigationItem.rightBarButtonItem?.accessibilityLabel = String(localized: "Add Excluded Model")
        dataSource.headerTitle = { section in
            switch section {
            case .accountModels: String(localized: "Signed-In Models")
            case .custom: String(localized: "Other Rules")
            }
        }
        dataSource.footerTitle = { _ in String(localized: "Excluded Models Footnote") }
        rebuild()
        load()
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        loader = Task { [weak self] in
            guard let accounts = try? await ApelinService.app.agentAccountList().accounts else { return }
            guard !Task.isCancelled, let self else { return }
            var rows: [Row] = []
            for account in accounts where account.signedIn {
                for model in account.models ?? [] {
                    rows.append(Row(
                        provider: account.provider.rawValue,
                        model: model,
                        title: model,
                        subtitle: account.provider.displayName,
                    ))
                }
            }
            self.fromAccounts = rows
            self.rebuild()
        }
    }

    private func rebuild() {
        let rules = ModelExclusions.stored.models
        custom = rules
            .filter { rule in !fromAccounts.contains { $0.provider == rule.provider && $0.model == rule.model } }
            .map { Row(provider: $0.provider, model: $0.model, title: $0.model, subtitle: $0.provider) }
        dataSource.update([(.accountModels, fromAccounts), (.custom, custom)], reconfigure: true)
    }

    @objc private dynamic func updateRows() {
        rebuild()
    }

    @objc private dynamic func changed(_ toggle: UISwitch) {
        let all = fromAccounts + custom
        guard let row = all.first(where: { $0.hashValue == toggle.tag }),
              let provider = AgentProvider(rawValue: row.provider)
        else { return }
        ModelExclusions.setModel(provider, model: row.model, excluded: toggle.isOn)
        rebuild()
    }

    @objc private dynamic func addRule() {
        presentTextInput(
            title: "Add Excluded Model",
            message: "Type the provider and model id, separated by a slash, for example openAI/gpt-4o.",
            placeholder: "provider/model",
            doneTitle: "Add",
        ) { [weak self] text in
            let parts = text.split(separator: "/", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let provider = AgentProvider(rawValue: parts[0]),
                  !parts[1].isEmpty
            else {
                self?.presentNotice(
                    title: "Invalid Model",
                    message: "Use provider/model, with the provider's exact identifier.",
                )
                return
            }
            ModelExclusions.setModel(provider, model: parts[1], excluded: true)
            self?.updateRows()
        }
    }
}
