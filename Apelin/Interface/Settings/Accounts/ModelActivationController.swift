import AlertController
import ApelinCore
import ApelinProtocol
import UIKit

/// Saves one provider's enabled models only when the user confirms.
final class ModelActivationController: TableController, UISearchResultsUpdating {
    private let account: AgentAccount
    @objc private dynamic var selected: Set<String>
    @objc private dynamic var shown: [String]
    @objc private dynamic var models: [String]
    @objc private dynamic var custom: Set<String>
    @objc private dynamic var hidden: Set<String>
    /// The limits each model has when the user sets none, as apelin-agent
    /// read them with the list: what an empty field shows.
    private var automaticLimits: [String: AgentModelLimits] = [:]
    private var loader: Task<Void, Never>?
    @objc private dynamic var saving = false
    /// 原地显示拉取进度，保留当前模型列表及搜索状态。
    private let fetchSpinner = UIActivityIndicatorView(style: .medium)
    private var fetchItem: UIBarButtonItem?
    private var fetching = false
    private var verification: TaskHandle?
    private let search = UISearchController(searchResultsController: nil)

    init(account: AgentAccount) {
        self.account = account
        let available = account.models ?? []
        let enabled = EnabledModels.ids(for: account.provider, storeID: account.storeID)
        custom = Set(EnabledModels.customIDs(for: account.provider, storeID: account.storeID))
        hidden = account.isAPIKeyAccount ? EnabledModels.hiddenIDs(for: account.provider, storeID: account.storeID) : []
        selected = account.isAPIKeyAccount ? enabled.subtracting(hidden) : enabled.intersection(available)
        models = account.isAPIKeyAccount
            ? Array(Set(available).union(custom).union(selected).subtracting(hidden)).sorted()
            : available
        shown = models
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(account:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Enable Models")
        navigationItem.largeTitleDisplayMode = .never
        let menu = usesAPIKey
            ? UIMenu(children: [UIAction(title: String(localized: "Save Without Verification")) { [weak self] _ in
                self?.save(verify: false)
            }])
            : nil
        let save = UIBarButtonItem(
            title: String(localized: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() },
            menu: menu,
        )
        let fetch = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.fetchModels() },
        )
        fetch.accessibilityLabel = String(localized: "刷新模型", table: "Quota")
        fetchItem = fetch
        fetchSpinner.accessibilityLabel = String(localized: "正在拉取模型", table: "Quota")
        navigationItem.rightBarButtonItems = usesAPIKey
            ? [save, addModelItem(), fetch]
            : [save, fetch]
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search Models")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        definesPresentationContext = true
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "model")
        updateRows()
    }

    private struct ModelRow: Equatable {
        let id: String
        let selected: Bool
        /// The user set its context window or largest reply.
        let limited: Bool
    }

    private lazy var dataSource = TableDataSource<Int, String, ModelRow>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, indexPath, row in
        self?.cell(in: table, at: indexPath, row: row)
    }

    @objc private dynamic func updateRows() {
        dataSource.headerTitle = { [weak self] _ in self.map { AccountNames.groupTitle(for: $0.account) } }
        dataSource.footerTitle = { _ in String(localized: "Choose the models to show in the chat model picker. You can change this later in Model Providers.") }
        dataSource.allowsEditing = usesAPIKey
        let rows = shown.map { model in
            ModelRow(
                id: model,
                selected: selected.contains(model),
                limited: usesAPIKey && ModelLimitsStore.limits(for: account.provider, storeID: account.storeID, model: model) != nil,
            )
        }
        dataSource.update([(0, rows)], reconfigure: true)
    }

    @objc private dynamic var usesAPIKey: Bool {
        account.isAPIKeyAccount
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard loader == nil else { return }
        fetchModels()
    }

    deinit { loader?.cancel() }

    private func addModelItem() -> UIBarButtonItem {
        let item = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.addCustomModel() },
        )
        item.accessibilityLabel = String(localized: "Add Custom Model")
        return item
    }

    /// 刷新图标原位变成转圈，保存与自定义模型按钮不移位。
    private func showFetching(_ active: Bool) {
        guard let fetchItem, var items = navigationItem.rightBarButtonItems else { return }
        if active {
            fetchSpinner.startAnimating()
            let item = UIBarButtonItem(customView: fetchSpinner)
            items = items.map { $0 === fetchItem ? item : $0 }
        } else {
            fetchSpinner.stopAnimating()
            items = items.map { $0.customView === fetchSpinner ? fetchItem : $0 }
        }
        navigationItem.rightBarButtonItems = items
    }

    @objc private dynamic func fetchModels() {
        guard !fetching, !saving else { return }
        fetching = true
        dataSource.beginLoad()
        navigationItem.prompt = nil
        showFetching(true)
        loader = Task { [weak self] in
            guard let self else { return }
            defer { fetching = false; showFetching(false) }
            do {
                let fetched = try await ApelinService.app.agentModelList(
                    provider: account.provider,
                    accountID: account.storeID,
                    limitsFor: custom.union(selected).sorted(),
                )
                guard !Task.isCancelled else { return }
                automaticLimits = fetched.limits ?? automaticLimits
                if !fetched.models.isEmpty {
                    models = Array(Set(fetched.models).union(custom).union(selected).subtracting(hidden)).sorted()
                } else {
                    navigationItem.prompt = String(localized: "无法拉取模型", table: "Quota")
                }
                updateSearchResults(for: search)
            } catch {
                guard !Task.isCancelled else { return }
                navigationItem.prompt = String(localized: "无法拉取模型", table: "Quota")
                updateSearchResults(for: search)
            }
        }
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        // 徽章图标按当前外观着色后是原样图，深浅色切换要重排单元格换新图。
        if previousTraitCollection?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            updateRows()
        }
    }

    @objc dynamic func updateSearchResults(for searchController: UISearchController) {
        let query = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { shown = models; updateRows(); return }
        // Ranked, not just filtered: an exact name or a word that starts with
        // the query comes before a model whose id happens to contain it. The
        // catalog's name and the wire id are both searched, and the cell shows
        // whichever answered.
        shown = SearchScorer.sorted(models, query: query) { [weak self] model in
            guard let self else { return model }
            if let title = self.account.catalogTitle(for: model) {
                return "\(title) \(model)"
            }
            return model
        }
        updateRows()
    }

    private func cell(in tableView: UITableView, at indexPath: IndexPath, row: ModelRow) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "model", for: indexPath)
        let model = row.id
        var content = cell.defaultContentConfiguration()
        // The catalog's name over the provider's id: the id is what the
        // conversation sends, and it stays readable under the name.
        content.text = account.displayName(for: model)
        content.textProperties.numberOfLines = 0
        if account.catalogTitle(for: model) != nil {
            content.secondaryText = model
            content.secondaryTextProperties.color = .secondaryLabel
        }
        // 照 Minis：能力直接以图标显示在模型名后（SF Symbols 的
        // text.bubble / eye / video / doc.text / mic.fill / brain），不做
        // 文字后缀——图标一行看全，占位也小。
        let badges = account.abilityBadges(for: model)
        if !badges.isEmpty {
            let result = NSMutableAttributedString(string: (content.text ?? "") + "  ")
            for badge in badges {
                let config = UIImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                guard let image = UIImage(systemName: badge.symbolName, withConfiguration: config) else { continue }
                // NSTextAttachment 里的模板图不会随深浅色切换重新着色，深色下
                // 留着浅色的描边就看不清了。按当前外观着成 label 色的原样图，
                // 外观变化时 traitCollectionDidChange 重排单元格换新图。
                let tinted = image.withTintColor(.label, renderingMode: .alwaysOriginal)
                let attachment = NSTextAttachment()
                attachment.image = tinted
                attachment.bounds = CGRect(x: 0, y: -2, width: image.size.width, height: image.size.height)
                result.append(NSAttributedString(attachment: attachment))
                result.append(NSAttributedString(string: " "))
            }
            content.text = nil
            content.attributedText = result
        }
        cell.contentConfiguration = content
        cell.accessoryType = row.selected ? .checkmark : .none
        cell.accessibilityTraits = row.selected ? [.button, .selected] : [.button]
        guard usesAPIKey else {
            cell.contentConfiguration = content
            cell.accessoryType = row.selected ? .checkmark : .none
            cell.accessoryView = nil
            cell.accessibilityCustomActions = nil
            return cell
        }
        // As Wi-Fi's list: the check leads, drawn clear on a row not
        // picked so every name starts at one edge, and the trailing button
        // opens the model's limits (#68).
        content.image = UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(weight: .semibold))
        content.imageProperties.tintColor = row.selected ? .tintColor : .clear
        content.secondaryText = row.limited ? String(localized: "Custom token limits") : nil
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .none
        let limits = UIButton(type: .detailDisclosure, primaryAction: UIAction { [weak self] _ in
            self?.showLimits(of: model)
        })
        limits.accessibilityLabel = String(localized: "Token Limits")
        cell.accessoryView = limits
        cell.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: String(localized: "Token Limits")) { [weak self] _ in
                self?.showLimits(of: model)
                return true
            },
        ]
        return cell
    }

    /// The page that sets `model`'s context window and largest reply.
    @objc private dynamic func showLimits(of model: String) {
        guard !saving else { return }
        let page = ModelLimitsController(provider: account.provider, storeID: account.storeID, model: model, automatic: automaticLimits[model])
        page.onSave = { [weak self] in self?.updateRows() }
        navigationController?.pushViewController(page, animated: true)
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !saving, let model = dataSource.itemIdentifier(for: indexPath) else { return }
        if !selected.insert(model).inserted {
            selected.remove(model)
        }
        updateRows()
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard usesAPIKey, !saving, let model = dataSource.itemIdentifier(for: indexPath) else { return nil }
        let delete = UIContextualAction(
            style: .destructive,
            title: String(localized: "Delete"),
        ) { [weak self] _, _, completion in
            guard let self, !saving, let row = shown.firstIndex(of: model) else { completion(false); return }
            selected.remove(model)
            custom.remove(model)
            hidden.insert(model)
            models.removeAll { $0 == model }
            shown.remove(at: row)
            completion(true)
            updateRows()
        }
        delete.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [delete])
    }

    @objc private dynamic func addCustomModel() {
        let alert = AlertInputViewController(
            title: "Add Custom Model",
            message: "Enter the model ID accepted by this provider.",
            placeholder: "Model ID",
            text: "",
            doneButtonText: "Add",
        ) { [weak self] value in
            guard let self else { return }
            let id = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty, id.count <= 256, !id.contains(where: \.isWhitespace) else {
                presentNotice(
                    title: "Invalid Model ID",
                    message: String(localized: "Enter a model ID without spaces or line breaks."),
                )
                return
            }
            custom.insert(id)
            hidden.remove(id)
            models = Array(Set(models + [id])).sorted()
            selected.insert(id)
            updateSearchResults(for: search)
        }
        present(alert, animated: true)
    }

    @objc private dynamic func save(verify: Bool = true) {
        guard !saving else { return }
        guard usesAPIKey && verify || account.provider == .githubCopilot,
              !selected.isEmpty
        else { finishSaving(); return }
        saving = true
        navigationController?.isModalInPresentation = true
        navigationItem.leftBarButtonItem?.isEnabled = false
        navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = false }
        Task { [weak self] in
            guard let self else { return }
            defer {
                saving = false
                verification = nil
                navigationController?.isModalInPresentation = false
                navigationItem.leftBarButtonItem?.isEnabled = true
                navigationItem.rightBarButtonItems?.forEach { $0.isEnabled = true }
            }
            do {
                try await ProviderProgress.run(
                    title: usesAPIKey ? "Verifying Models" : "Enabling Models",
                    message: "Waiting for a response from each selected model…",
                    from: self,
                    cancel: { [weak self] in
                        if let handle = self?.verification {
                            try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID)
                        }
                    },
                ) {
                    let handle = try await ApelinService.app.agentModelActivate(
                        provider: self.account.provider,
                        accountID: self.account.storeID,
                        models: self.selected.sorted(),
                    )
                    self.verification = handle
                    if Task.isCancelled {
                        try? await ApelinService.app.agentSignInCancel(taskID: handle.taskID)
                        throw CancellationError()
                    }
                    for try await event in ApelinService.app.events(of: handle) {
                        guard event.kind == TaskEvent.stateKind,
                              let state = event.payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)),
                              state.isTerminal
                        else { continue }
                        if state == .cancelled {
                            throw CancellationError()
                        }
                        guard state == .succeeded else {
                            throw ApelinError(
                                .unavailable,
                                event.payload?["message"]?.stringValue
                                    ?? String(localized: "Model verification failed."),
                            )
                        }
                        return
                    }
                    throw ApelinError(.unavailable, String(localized: "Model verification did not finish."))
                }
                finishSaving()
            } catch {
                if !(error is CancellationError) {
                    presentNotice(title: "Unable to Verify Models", message: error.readableMessage)
                }
            }
        }
    }

    @objc private dynamic func finishSaving() {
        EnabledModels.save(selected, custom: custom, hidden: hidden, for: account.provider, storeID: account.storeID)
        dismiss(animated: true)
    }
}
