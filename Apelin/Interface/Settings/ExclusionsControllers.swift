import ApelinProtocol
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
        for raw in ModelExclusions.stored.providers {
            guard !known.contains(raw), let extra = AgentProvider(rawValue: raw) else { continue }
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

/// Individual models, picked from the models the app already offers: one
/// section per provider, a switch on every model the reader enabled there.
/// Turning one on keeps the automatic assistant and the speed test off it.
///
/// The list is the same catalog the composer's picker shows, so the reader
/// never has to type a model id to exclude it. A typed rule is still accepted
/// for a model a relay lists only sometimes.
final class ExcludedModelsController: TableController {
    private struct Row: Hashable {
        var provider: String
        var providerName: String
        var model: String
    }

    private lazy var dataSource = TableDataSource<String, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] table, _, row in
        guard let self else { return nil }
        let cell = table.dequeueReusableCell(withIdentifier: "model") ?? UITableViewCell(style: .subtitle, reuseIdentifier: "model")
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.model
        content.secondaryText = row.providerName
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
        toggle.isOn = isExcluded(row)
        toggle.accessibilityLabel = row.model
        toggle.accessibilityValue = row.providerName
        toggle.accessibilityIdentifier = row.provider + "/" + row.model
        toggle.removeTarget(nil, action: nil, for: .valueChanged)
        toggle.addTarget(self, action: #selector(changed(_:)), for: .valueChanged)
        cell.accessoryView = toggle
        return cell
    }

    /// Section id → its rows, in the order the providers are shown.
    private var sections: [(String, [Row])] = []
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
        dataSource.headerTitle = { id in self.sections.first { $0.0 == id }?.1.first?.providerName }
        dataSource.footerTitle = { _ in String(localized: "Excluded Models Footnote") }
        rebuild()
        load()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(updateRows),
            name: .enabledModelsChanged,
            object: nil,
        )
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        loader = Task { [weak self] in
            guard let self else { return }
            let selected = EnabledModels.selectedModelIDs()
            guard let listed = try? await ApelinService.app
                .agentAccountList(extraModels: selected, onlyExtraModels: true).accounts
            else { return }
            guard !Task.isCancelled else { return }
            let accounts = EnabledModels.accounts(from: listed)
            var built: [(String, [Row])] = []
            for account in accounts {
                let rows = (account.models ?? []).map { model in
                    Row(provider: account.provider.rawValue, providerName: account.provider.displayName, model: model)
                }
                guard !rows.isEmpty else { continue }
                built.append((account.provider.rawValue, rows))
            }
            self.sections = built
            self.rebuild()
        }
    }

    /// The catalog, plus any excluded model the catalog does not list right
    /// now (a relay that dropped it, or a typed rule): those keep a row, so a
    /// rule is never invisible and always removable.
    private func rebuild() {
        var shown = sections
        let listed = Set(shown.flatMap { _, rows in rows.map { $0.provider + "/" + $0.model } })
        for rule in ModelExclusions.stored.models where !listed.contains(rule.provider + "/" + rule.model) {
            guard let provider = AgentProvider(rawValue: rule.provider) else { continue }
            let row = Row(provider: rule.provider, providerName: provider.displayName, model: rule.model)
            if let index = shown.firstIndex(where: { $0.0 == rule.provider }) {
                shown[index].1.append(row)
            } else {
                shown.append((rule.provider, [row]))
            }
        }
        shown = shown.filter { !$0.1.isEmpty }
        shown.sort { $0.1[0].providerName.localizedStandardCompare($1.1[0].providerName) == .orderedAscending }
        sections = shown
        dataSource.update(sections.map { ($0.0, $0.1) }, reconfigure: true)
    }

    private func isExcluded(_ row: Row) -> Bool {
        ModelExclusions.stored.models.contains { $0.provider == row.provider && $0.model == row.model }
    }

    @objc private dynamic func updateRows() {
        rebuild()
    }

    @objc private dynamic func changed(_ toggle: UISwitch) {
        guard let id = toggle.accessibilityIdentifier else { return }
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2, let provider = AgentProvider(rawValue: parts[0]) else { return }
        ModelExclusions.setModel(provider, model: parts[1], excluded: toggle.isOn)
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
