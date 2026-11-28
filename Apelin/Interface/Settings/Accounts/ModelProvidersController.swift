import ApelinCore
import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// Settings ▸ Model Providers: every provider apelin-agent can sign in to,
/// in Apelin's display order. Signed-in ones first, each with who
/// it is signed in as under its name and a `…` menu (Edit Configuration or Sign In Again, Sign
/// Out); then the rest, those signed in to with an account apart from those
/// that take a typed key. A search field narrows the list by name. The
/// OpenAI-compatible login is there once for each endpoint signed in to,
/// told apart by its host, and once more among the keys to add another.
final class ModelProvidersController: TableController, UISearchResultsUpdating {
    private enum Group: Hashable {
        case signedIn
        case accounts
        case keys

        var title: String {
            switch self {
            case .signedIn: String(localized: "Signed In")
            case .accounts: String(localized: "Sign In with an Account")
            case .keys: String(localized: "API Keys")
            }
        }
    }

    private enum Status: Equatable {
        case loading
        case unavailable(String)
        case noResults
    }

    private enum Section: Hashable {
        case group(Group)
        case status
    }

    private enum Row: Equatable {
        case account(AgentAccount, note: String?, quota: AgentQuotaSnapshot?)
        case status(Status)
        var id: String {
            switch self {
            case let .account(account, _, _): (account.signedIn ? "account:" : "add:") + (account.storeID ?? account.provider.rawValue)
            case .status: "status"
            }
        }
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] _, _, row in
        guard let self else { return nil }
        switch row {
        case let .account(account, note, quota): return accountCell(account, note: note, quota: quota)
        case let .status(status): return statusCell(status)
        }
    }

    /// The accounts as apelin-agent last listed them.
    private var accounts: [AgentAccount] = []
    @objc private dynamic var loaded = false
    @objc private dynamic var failure: Error?
    @objc private dynamic var query = ""
    private var sections: [(Section, [Row])] = [(.status, [.status(.loading)])]
    private var loader: Task<Void, Never>?
    private var quotaLoader: Task<Void, Never>?
    private var quotas: [AgentQuotaSnapshot] = []
    private var refreshingQuotas = false
    private let search = UISearchController(searchResultsController: nil)

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        loader?.cancel()
        quotaLoader?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model Providers")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "arrow.clockwise"),
            primaryAction: UIAction { [weak self] _ in self?.loadQuotas(manual: true) },
        ).then { $0.accessibilityLabel = String(localized: "刷新额度", table: "Quota") }
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.loadQuotas(manual: true) }, for: .valueChanged)
        }
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search")
        search.searchBar.autocapitalizationType = .none
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            if case let .group(group) = section {
                return group.title
            }
            return nil
        }
        dataSource.footerTitle = { [weak self] section in
            guard let self, section == sections.last?.0, case .group = section else { return nil }
            // kwwk signs in and talks to every provider here: its version
            // is what a report about one needs.
            guard let kwwk = LinkedPackage.kwwkVersion else {
                return String(localized: "Credentials stay in this device’s keychain.")
            }
            return String(localized: "Credentials stay in this device’s keychain. Currently using kwwk \(kwwk).")
        }
        dataSource.update(sections)
        quotas = ProviderBalanceStore.shared.quotas
        NotificationCenter.default.addObserver(
            self, selector: #selector(quotasChanged), name: .providerBalancesChanged, object: nil
        )
    }

    @objc private func quotasChanged() {
        quotas = ProviderBalanceStore.shared.quotas
        if loaded { regroup() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    @objc(apelin_load) private dynamic func load() {
        loader?.cancel()
        dataSource.beginLoad()
        loader = Task { [weak self] in
            do {
                let accounts = try await ApelinService.app.agentAccountsWithKnownModels()
                guard !Task.isCancelled, let self else { return }
                self.accounts = accounts
                ProviderBalanceStore.shared.reconcile(accounts: accounts)
                quotas = ProviderBalanceStore.shared.quotas
                failure = nil
            } catch {
                guard !Task.isCancelled, let self else { return }
                failure = error
            }
            guard let self else { return }
            loaded = true
            regroup()
            loadQuotas(manual: false)
        }
    }

    /// 额度独立于账号列表更新，查询失败不抹掉已有数字。
    private func loadQuotas(manual: Bool) {
        guard !refreshingQuotas, accounts.contains(where: \.signedIn) else {
            refreshControl?.endRefreshing()
            return
        }
        let now = Date()
        let queryable = quotas.filter { $0.kind != .billingLink }
        let debounces = queryable.compactMap(\.manualDebounceUntil).filter { $0 > now }
        if manual, !queryable.isEmpty, debounces.count == queryable.count, let earliest = debounces.min() {
            refreshControl?.endRefreshing()
            let seconds = max(1, Int(ceil(earliest.timeIntervalSince(now))))
            SPIndicator.present(title: String(localized: "请在\(seconds)秒后重试", table: "Quota"), preset: .error, haptic: .warning)
            return
        }
        refreshingQuotas = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        quotaLoader = Task { [weak self] in
            guard let self else { return }
            defer {
                refreshingQuotas = false
                navigationItem.rightBarButtonItem?.isEnabled = true
                refreshControl?.endRefreshing()
            }
            do {
                quotas = try await ProviderBalanceStore.shared.loadQuotas(manual: manual)
                guard !Task.isCancelled else { return }
                regroup()
            } catch {
                guard !Task.isCancelled, manual else { return }
                presentNotice(title: String.LocalizationValue(stringLiteral: String(localized: "无法查询用量", table: "Quota")), message: error.readableMessage)
            }
        }
    }

    @objc dynamic func updateSearchResults(for searchController: UISearchController) {
        let text = (searchController.searchBar.text ?? "").trimmingCharacters(in: .whitespaces)
        guard text != query else { return }
        query = text
        regroup()
    }

    @objc private dynamic func regroup() {
        if !loaded {
            sections = [(.status, [.status(.loading)])]
        } else if let failure, accounts.isEmpty {
            sections = [(.status, [.status(.unavailable(ProviderLoginController.unavailableText(failure)))])]
        } else {
            let shown = query.isEmpty
                ? accounts
                : SearchScorer.sorted(accounts, query: query) {
                    "\($0.provider.displayName) \($0.account ?? "") \(Preferences.ProviderNotes.note(for: $0.provider) ?? "")"
                }
            let groups: [(Group, [AgentAccount])] = [
                (.signedIn, shown.filter(\.signedIn)),
                (.accounts, shown.filter { !$0.signedIn && $0.method != .apiKey }),
                (.keys, shown.filter { !$0.signedIn && $0.method == .apiKey }),
            ]
            sections = groups.filter { !$0.1.isEmpty }.map { group, accounts in
                (.group(group), accounts.map { account in
                    .account(account, note: Preferences.ProviderNotes.note(for: account.provider), quota: QuotaFormatting.snapshot(for: account, in: quotas))
                })
            }
            if sections.isEmpty {
                sections = [(.status, [.status(.noResults)])]
            }
        }
        dataSource.update(sections)
    }

    // MARK: - Table

    private func account(at indexPath: IndexPath) -> AgentAccount? {
        guard case let .account(account, _, _)? = dataSource.value(at: indexPath) else { return nil }
        return account
    }

    private func statusCell(_ status: Status) -> UITableViewCell {
        switch status {
        case .loading:
            return WaitingCell().then { $0.show(String(localized: "Loading…")) }
        case let .unavailable(message):
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.stackedValueCell()
            content.text = String(localized: "Model Providers Unavailable")
            content.secondaryText = message
            content.secondaryTextProperties.color = .secondaryLabel

            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        case .noResults:
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "No Results")
            content.textProperties.color = .secondaryLabel
            content.textProperties.alignment = .center
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
    }

    /// 备注独占标题行尾；菜单始终留在 UIKit 的 accessoryView 区域。
    private func accountCell(_ account: AgentAccount, note: String?, quota: AgentQuotaSnapshot?) -> UITableViewCell {
        var detail = account.signedIn ? Self.signedInLine(account) : nil
        if let quota, let summary = QuotaFormatting.summaryText(for: quota) {
            detail = [detail, summary].compactMap { $0 }.joined(separator: " · ")
        }
        let cell = ProviderAccountCell(
            name: account.provider.displayName,
            icon: account.provider.icon,
            note: note,
            detail: detail
        )
        if account.signedIn {
            cell.accessoryView = menuButton(account)
            cell.selectionStyle = .default
        } else {
            cell.accessoryType = .disclosureIndicator
        }
        return cell
    }

    /// Who is signed in, and until when where the sign-in ends: one phrase,
    /// never words set apart by a middle dot (owner, 2026-11-21).
    private static func signedInLine(_ account: AgentAccount) -> String {
        let name = account.account ?? String(localized: "Signed In")
        guard let expiresAt = account.expiresAt else { return name }
        let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
        return expiresAt < Date() ? String(localized: "\(name), expired \(date)") : String(localized: "\(name), until \(date)")
    }

    /// `…` with no circle, its menu read each time it opens.
    private func menuButton(_ account: AgentAccount) -> UIButton {
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "ellipsis"), for: .normal)
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            completion(self?.accountActions(account) ?? [])
        }])
        button.frame = CGRect(x: 0, y: 0, width: 32, height: 44)
        button.accessibilityLabel = String(localized: "\(account.provider.displayName) Options")
        return button
    }

    private func accountActions(_ account: AgentAccount) -> [UIMenuElement] {
        [
            UIAction(title: String(localized: "额度与详情", table: "Quota"), image: UIImage(systemName: "chart.bar")) { [weak self] _ in
                self?.openQuotaDetail(account)
            },
            addAccountAction(for: account.provider),
            UIAction(
                title: String(localized: "Edit"),
                image: UIImage(systemName: account.isAPIKeyAccount ? "pencil" : "arrow.clockwise"),
            ) { [weak self] _ in
                self?.signIn(account)
            },
            UIAction(
                title: String(localized: "Models"),
                image: UIImage(systemName: "checklist"),
            ) { [weak self] _ in
                self?.presentPageAsFormSheet(ModelActivationController(account: account))
            },
            UIAction(
                title: String(localized: "Model Parameters"),
                image: UIImage(systemName: "slider.horizontal.3"),
            ) { [weak self] _ in
                self?.presentPageAsFormSheet(ModelParametersController(account: account))
            },
            UIMenu(options: .displayInline, children: [
                UIAction(
                    title: String(localized: "Sign Out"),
                    image: UIImage(systemName: "rectangle.portrait.and.arrow.right"),
                    attributes: .destructive,
                ) { [weak self] _ in
                    self?.confirmSignOut(account)
                },
            ]),
        ]
    }

    private func noteActionTitle(for provider: AgentProvider) -> String {
        Preferences.ProviderNotes.note(for: provider) == nil
            ? String(localized: "Add Note")
            : String(localized: "Edit Note")
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let account = account(at: indexPath), account.signedIn,
              account.provider.kind == .openAICompatible else { return nil }
        let provider = account.provider
        let action = UIContextualAction(style: .normal, title: noteActionTitle(for: provider)) { [weak self] _, _, completion in
            guard let self, presentedViewController == nil else { completion(false); return }
            completion(true)
            editNote(for: provider)
        }
        action.backgroundColor = .systemIndigo
        let configuration = UISwipeActionsConfiguration(actions: [action])
        configuration.performsFirstActionWithFullSwipe = false
        return configuration
    }

    private func editNote(for provider: AgentProvider) {
        let title = noteActionTitle(for: provider)
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = Preferences.ProviderNotes.note(for: provider)
            field.accessibilityLabel = String(localized: "Provider Note")
            field.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
            guard let field = alert?.textFields?.first else { return }
            Preferences.ProviderNotes.save(field.text ?? "", for: provider)
            self?.regroup()
        })
        present(alert, animated: true)
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        account(at: indexPath) != nil
    }

    override func tableView(
        _: UITableView,
        contextMenuConfigurationForRowAt indexPath: IndexPath,
        point _: CGPoint,
    ) -> UIContextMenuConfiguration? {
        guard let account = account(at: indexPath), account.signedIn else { return nil }
        return UIContextMenuConfiguration(actionProvider: { [weak self] _ in
            UIMenu(children: self?.accountActions(account) ?? [])
        })
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let account = account(at: indexPath) else { return }
        if account.signedIn { openQuotaDetail(account) }
        else { signIn(account) }
    }

    // MARK: - Acting

    /// 空闲账号位由协议的统一身份规则分配，不覆盖原账号凭据。
    private func addAccountAction(for provider: AgentProvider) -> UIKit.UIAction {
        let ids = accounts.filter { $0.provider == provider && $0.signedIn }
            .map { $0.storeID ?? $0.provider.rawValue }
        let base = ids.first.map(AgentAccountID.base(of:)) ?? provider.rawValue
        let free = AgentAccountID.next(base: base, taken: Set(ids))
        let template = accounts.first { $0.provider == provider && !$0.signedIn }
            ?? accounts.first { $0.provider == provider }
        return UIKit.UIAction(
            title: String(localized: "添加账号", table: "Quota"),
            image: UIImage(systemName: "person.badge.plus"),
            attributes: free == nil || template == nil ? .disabled : [],
        ) { [weak self] _ in
            guard let self, let free, let template else { return }
            signIn(AgentAccount(
                provider: provider,
                method: template.method,
                alternativeMethods: template.alternativeMethods,
                signedIn: false,
                storeID: free,
            ))
        }
    }

    private func openQuotaDetail(_ account: AgentAccount) {
        let page = ProviderQuotaDetailController(
            account: account,
            initialQuota: QuotaFormatting.snapshot(for: account, in: quotas),
            onAccountsChanged: { [weak self] in self?.load() },
        )
        navigationController?.pushViewController(page, animated: true)
    }

    private func signIn(_ account: AgentAccount) {
        let page = ProviderLoginController(account: account)
        page.onFinish = { [weak self] in self?.load() }
        page.onSuccessfulSignIn = {
            ProviderBalanceStore.shared.configurationChanged()
        }
        // a sheet of its own over Settings, kept up until it is closed: a
        // stray swipe would end a sign-in waiting on Safari
        page.isModalInPresentation = true
        presentPageAsFormSheet(page)
    }

    /// An OpenAI-compatible endpoint is named by its host: there can be
    /// several, all with the provider's one name.
    private func confirmSignOut(_ account: AgentAccount) {
        let provider = account.provider
        let name = provider.kind == .openAICompatible ? account.account ?? provider.displayName : provider.displayName
        presentConfirmation(
            title: "Sign Out of \(name)?",
            message: "Agent sessions that use it stop working until you sign in again.",
            confirmTitle: "Sign Out",
            destructive: true,
        ) { [weak self] in
            self?.signOut(provider, accountID: account.storeID)
        }
    }

    private func signOut(_ provider: AgentProvider, accountID: String?) {
        Task { [weak self] in
            do {
                try await ApelinService.app.agentSignOut(provider: provider, accountID: accountID)
                ProviderBalanceStore.shared.invalidate(provider: provider, accountID: accountID)
                // 只有最后一个账号退出才清空服务商级模型和备注。
                if self?.accounts.contains(where: { $0.provider == provider && $0.signedIn && $0.storeID != accountID }) == false {
                    EnabledModels.remove(for: provider)
                    Preferences.ProviderNotes.save("", for: provider)
                }
                self?.load()
            } catch {
                self?.presentNotice(title: "Unable to Sign Out", message: error.readableMessage)
            }
        }
    }
}

/// 标题和备注同基线；标题吸收剩余宽度，备注贴行尾且最多占标题区域的45%。
/// 内容只约束在 contentView 内，UIKit 会在它之外给省略号或箭头留位置。
private final class ProviderAccountCell: UITableViewCell {
    init(name: String, icon: UIImage?, note: String?, detail: String?) {
        super.init(style: .default, reuseIdentifier: nil)
        let title = UILabel()
        title.text = name
        title.font = .preferredFont(forTextStyle: .body)
        title.adjustsFontForContentSizeCategory = true
        title.textColor = .label
        title.numberOfLines = 1
        title.lineBreakMode = .byTruncatingMiddle
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let heading = UIStackView(arrangedSubviews: [title])
        heading.axis = .horizontal
        heading.alignment = .firstBaseline
        heading.spacing = 8
        if let text = note, !text.isEmpty {
            let noteLabel = UILabel()
            noteLabel.text = text
            noteLabel.font = UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .systemFont(ofSize: 13, weight: .semibold))
            noteLabel.adjustsFontForContentSizeCategory = true
            noteLabel.textColor = AppAccent.color(glass: .tintColor)
            noteLabel.textAlignment = .natural
            noteLabel.numberOfLines = 1
            noteLabel.lineBreakMode = .byTruncatingTail
            noteLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            noteLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            heading.addArrangedSubview(noteLabel)
            noteLabel.widthAnchor.constraint(lessThanOrEqualTo: heading.widthAnchor, multiplier: 0.45).isActive = true
        }

        let column = UIStackView(arrangedSubviews: [heading])
        column.axis = .vertical
        column.spacing = 3
        if let detail {
            let subtitle = UILabel()
            subtitle.text = detail
            subtitle.font = .preferredFont(forTextStyle: .subheadline)
            subtitle.adjustsFontForContentSizeCategory = true
            subtitle.textColor = .secondaryLabel
            subtitle.numberOfLines = 2
            subtitle.lineBreakMode = .byTruncatingTail
            column.addArrangedSubview(subtitle)
        }
        let mark = UIImageView(image: icon)
        mark.contentMode = .scaleAspectFit
        mark.isAccessibilityElement = false
        mark.widthAnchor.constraint(equalToConstant: 29).isActive = true
        mark.heightAnchor.constraint(equalToConstant: 29).isActive = true
        let row = UIStackView(arrangedSubviews: [mark, column])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 16
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        let margins = contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            row.topAnchor.constraint(equalTo: margins.topAnchor),
            row.bottomAnchor.constraint(equalTo: margins.bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }
}
