import ApelinProtocol
import SnapKit
import SPIndicator
import Then
import UIKit

/// 账号自己的额度页；设置与模型选择器共用，不替换输入框原有余额详情。
final class ProviderQuotaDetailController: TableController {
    private enum Section: Hashable { case overview, balances, windows, actions, management }
    private enum Row: Hashable {
        case status, plan, source, updated, nextCheck, error
        case balance(AgentQuotaBalance), window(AgentQuotaWindow)
        case refresh, billing, edit, models, parameters, signOut
    }

    private var account: AgentAccount
    private let allowsAccountManagement: Bool
    private var snapshot: AgentQuotaSnapshot?
    private let onAccountsChanged: () -> Void
    private var loader: Task<Void, Never>?
    private var generation = UUID()
    private var refreshing = false
    private var lastError: String?
    private let spinner = UIActivityIndicatorView(style: .medium)
    private lazy var refreshItem = UIBarButtonItem(
        image: UIImage(systemName: "arrow.clockwise"),
        primaryAction: UIAction { [weak self] _ in self?.refresh(manual: true) },
    ).then { $0.accessibilityLabel = String(localized: "刷新额度", table: "Quota") }
    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in self?.cell(for: row) }

    init(
        account: AgentAccount,
        initialQuota: AgentQuotaSnapshot?,
        allowsAccountManagement: Bool = true,
        onAccountsChanged: @escaping () -> Void,
    ) {
        self.account = account
        self.allowsAccountManagement = allowsAccountManagement
        snapshot = initialQuota ?? QuotaFormatting.snapshot(for: account, in: ProviderBalanceStore.shared.quotas)
        self.onAccountsChanged = onAccountsChanged
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(account:initialQuota:onAccountsChanged:)") }
    deinit { loader?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "额度与详情", table: "Quota")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = refreshItem
        spinner.accessibilityLabel = String(localized: "正在刷新额度", table: "Quota")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 56
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.refresh(manual: true) }, for: .valueChanged)
        }
        dataSource.headerTitle = { section in
            switch section {
            case .overview: String(localized: "账号", table: "Quota")
            case .balances: String(localized: "余额", table: "Quota")
            case .windows: String(localized: "用量窗口", table: "Quota")
            case .actions: String(localized: "额度", table: "Quota")
            case .management: String(localized: "账号管理", table: "Quota")
            }
        }
        dataSource.footerTitle = { [weak self] section in
            switch section {
            case .overview: self?.account.account ?? self?.account.provider.displayName
            case .actions: String(localized: "手动刷新每30秒最多一次。", table: "Quota")
            default: nil
            }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(quotaChanged), name: .providerBalancesChanged, object: nil
        )
        rebuildSections()
    }

    @objc private func quotaChanged() {
        snapshot = QuotaFormatting.snapshot(for: account, in: ProviderBalanceStore.shared.quotas)
        if let snapshot, [AgentQuotaStatus.available, .exhausted].contains(snapshot.status) { lastError = nil }
        rebuildSections()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh(manual: false)
    }

    private func refresh(manual: Bool) {
        guard !refreshing else { refreshControl?.endRefreshing(); return }
        if manual, let until = snapshot?.manualDebounceUntil, until > Date() {
            let seconds = max(1, Int(ceil(until.timeIntervalSinceNow)))
            refreshControl?.endRefreshing()
            SPIndicator.present(title: String(localized: "请在\(seconds)秒后重试", table: "Quota"), preset: .error, haptic: .warning)
            return
        }
        loader?.cancel()
        let token = UUID()
        generation = token
        refreshing = true
        spinner.startAnimating()
        navigationItem.rightBarButtonItem = UIBarButtonItem(customView: spinner)
        rebuildSections()
        loader = Task { [weak self] in
            guard let self else { return }
            defer {
                if generation == token {
                    refreshing = false
                    spinner.stopAnimating()
                    navigationItem.rightBarButtonItem = refreshItem
                    refreshControl?.endRefreshing()
                    rebuildSections()
                }
            }
            do {
                let response = try await ProviderBalanceStore.shared.loadQuotas(
                    provider: account.provider, accountID: account.storeID, manual: manual
                )
                guard !Task.isCancelled, generation == token else { return }
                if let latest = QuotaFormatting.snapshot(for: account, in: response) {
                    snapshot = latest
                    lastError = nil
                } else {
                    lastError = String(localized: "无法查询用量", table: "Quota")
                }
            } catch {
                guard !Task.isCancelled, generation == token else { return }
                lastError = error.readableMessage
            }
        }
    }

    private func rebuildSections() {
        var overview: [Row] = [.status]
        if snapshot?.planName?.isEmpty == false { overview.append(.plan) }
        if snapshot != nil { overview.append(.source) }
        if snapshot?.updatedAt != nil { overview.append(.updated) }
        if let next = snapshot?.circuitBrokenUntil ?? snapshot?.cooldownUntil, next > Date() { overview.append(.nextCheck) }
        if lastError != nil || snapshot?.errorSummary?.isEmpty == false { overview.append(.error) }
        var sections: [(Section, [Row])] = [(.overview, overview)]
        if let balances = snapshot?.balances, !balances.isEmpty { sections.append((.balances, balances.map(Row.balance))) }
        if let windows = snapshot?.windows, !windows.isEmpty { sections.append((.windows, windows.map(Row.window))) }
        var actions: [Row] = [.refresh]
        if billingURL != nil { actions.append(.billing) }
        sections.append((.actions, actions))
        if allowsAccountManagement {
            sections.append((.management, [.edit, .models, .parameters, .signOut]))
        }
        dataSource.update(sections, reconfigure: true)
    }

    private func valueCell(_ title: String, value: String?, detail: String? = nil) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.stackedValueCell()
        content.text = value.map { "\(title)：\($0)" } ?? title
        content.textProperties.numberOfLines = 0
        content.secondaryText = detail
        content.secondaryTextProperties.numberOfLines = 0
        content.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    private func actionCell(_ title: String, image: String, destructive: Bool = false) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = title
        content.image = UIImage(systemName: image)
        content.textProperties.color = destructive ? .systemRed : .tintColor
        content.imageProperties.tintColor = destructive ? .systemRed : .tintColor
        cell.contentConfiguration = content
        cell.accessibilityTraits.insert(.button)
        return cell
    }

    private func cell(for row: Row) -> UITableViewCell {
        switch row {
        case .status:
            if snapshot == nil, refreshing { return valueCell(String(localized: "状态", table: "Quota"), value: String(localized: "正在刷新额度", table: "Quota")) }
            let status = lastError == nil ? snapshot.map { QuotaFormatting.statusText(for: $0.status) } : nil
            return valueCell(String(localized: "状态", table: "Quota"), value: status ?? String(localized: "无法查询用量", table: "Quota"))
        case .plan: return valueCell(String(localized: "套餐", table: "Quota"), value: snapshot?.planName)
        case .source: return valueCell(String(localized: "来源", table: "Quota"), value: snapshot.map { QuotaFormatting.sourceText(for: $0) })
        case .updated: return valueCell(String(localized: "更新时间", table: "Quota"), value: snapshot?.updatedAt?.formatted(date: .abbreviated, time: .shortened))
        case .nextCheck:
            return valueCell(String(localized: "下次自动查询", table: "Quota"), value: (snapshot?.circuitBrokenUntil ?? snapshot?.cooldownUntil)?.formatted(date: .abbreviated, time: .shortened))
        case .error: return valueCell(String(localized: "无法查询用量", table: "Quota"), value: nil, detail: lastError ?? snapshot?.errorSummary)
        case let .balance(balance):
            var parts: [String] = []
            if let total = balance.total, !balance.isUnlimited { parts.append(String(localized: "总额：\(QuotaFormatting.balanceAmountText(balance, amount: total))", table: "Quota")) }
            if let granted = balance.granted { parts.append(String(localized: "赠送：\(QuotaFormatting.balanceAmountText(balance, amount: granted))", table: "Quota")) }
            if let toppedUp = balance.toppedUp { parts.append(String(localized: "充值：\(QuotaFormatting.balanceAmountText(balance, amount: toppedUp))", table: "Quota")) }
            if let used = balance.used { parts.append(String(localized: "已用：\(QuotaFormatting.balanceAmountText(balance, amount: used))", table: "Quota")) }
            if !balance.isAvailable { parts.append(String(localized: "不可用", table: "Quota")) }
            return valueCell(balance.currency ?? balance.unitLabel ?? String(localized: "余额", table: "Quota"), value: QuotaFormatting.balanceAmountText(balance, amount: balance.remaining ?? balance.total), detail: parts.joined(separator: " · "))
        case let .window(window): return QuotaWindowCell(window: window)
        case .refresh: return actionCell(refreshing ? String(localized: "正在刷新额度", table: "Quota") : String(localized: "刷新额度", table: "Quota"), image: "arrow.clockwise")
        case .billing: return actionCell(String(localized: "打开官方账单页", table: "Quota"), image: "arrow.up.right.square")
        case .edit: return actionCell(account.isAPIKeyAccount ? String(localized: "编辑配置", table: "Quota") : String(localized: "重新登录", table: "Quota"), image: "pencil")
        case .models: return actionCell(String(localized: "模型", table: "Quota"), image: "checklist")
        case .parameters: return actionCell(String(localized: "模型参数", table: "Quota"), image: "slider.horizontal.3")
        case .signOut: return actionCell(String(localized: "退出登录", table: "Quota"), image: "rectangle.portrait.and.arrow.right", destructive: true)
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath) else { return false }
        switch row {
        case .refresh: return !refreshing
        case .billing: return true
        case .edit, .models, .parameters, .signOut: return allowsAccountManagement
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard self.tableView(tableView, shouldHighlightRowAt: indexPath),
              let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .refresh: refresh(manual: true)
        case .billing:
            if let url = billingURL, ["https", "http"].contains(url.scheme?.lowercased() ?? "") { UIApplication.shared.open(url) }
        case .edit:
            let page = ProviderLoginController(account: account)
            page.onFinish = { [weak self] in self?.onAccountsChanged() }
            page.onSuccessfulSignIn = { [weak self] in self?.reloadAccount() }
            page.isModalInPresentation = true
            presentPageAsFormSheet(page)
        case .models: presentPageAsFormSheet(ModelActivationController(account: account))
        case .parameters: presentPageAsFormSheet(ModelParametersController(account: account))
        case .signOut:
            let name = account.account ?? account.provider.displayName
            presentConfirmation(
                title: String.LocalizationValue(stringLiteral: String(localized: "退出账号\(name)？", table: "Quota")),
                message: String.LocalizationValue(stringLiteral: String(localized: "使用此账号的会话需要重新登录后才能继续。", table: "Quota")),
                confirmTitle: String.LocalizationValue(stringLiteral: String(localized: "退出登录", table: "Quota")),
                destructive: true,
            ) { [weak self] in self?.signOut() }
        default: break
        }
    }

    private func reloadAccount() {
        generation = UUID()
        loader?.cancel()
        ProviderBalanceStore.shared.configurationChanged()
        onAccountsChanged()
        Task { [weak self] in
            guard let self else { return }
            if let accounts = try? await ApelinService.app.agentAccountList().accounts,
               let latest = accounts.first(where: {
                   $0.provider == account.provider && $0.signedIn
                       && ($0.storeID ?? $0.provider.rawValue) == (account.storeID ?? account.provider.rawValue)
               })
            {
                ProviderBalanceStore.shared.reconcile(accounts: accounts)
                account = latest
                snapshot = QuotaFormatting.snapshot(for: latest, in: ProviderBalanceStore.shared.quotas)
            }
            generation = UUID()
            loader?.cancel()
            refreshing = false
            refresh(manual: false)
        }
    }

    private func signOut() {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await ApelinService.app.agentSignOut(provider: account.provider, accountID: account.storeID)
                generation = UUID()
                loader?.cancel()
                ProviderBalanceStore.shared.invalidate(provider: account.provider, accountID: account.storeID)
                if let accounts = try? await ApelinService.app.agentAccountList().accounts,
                   !accounts.contains(where: { $0.provider == account.provider && $0.signedIn })
                {
                    EnabledModels.remove(for: account.provider)
                    Preferences.ProviderNotes.save("", for: account.provider)
                }
                onAccountsChanged()
                if navigationController?.viewControllers.first === self { dismiss(animated: true) }
                else { navigationController?.popViewController(animated: true) }
            } catch {
                presentNotice(title: String.LocalizationValue(stringLiteral: String(localized: "无法退出登录", table: "Quota")), message: error.readableMessage)
            }
        }
    }

    private var billingURL: URL? {
        if let url = snapshot?.billingURL { return url }
        switch account.provider {
        case .openAI: return URL(string: "https://platform.openai.com/settings/organization/billing/overview")
        case .anthropic: return URL(string: "https://console.anthropic.com/settings/billing")
        case .anthropicOAuth: return URL(string: "https://claude.ai/settings/usage")
        case .openAICodex: return URL(string: "https://chatgpt.com/codex/settings/usage")
        case .google: return URL(string: "https://aistudio.google.com/spend")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/usage")
        case .openRouter: return URL(string: "https://openrouter.ai/settings/credits")
        case .githubCopilot: return URL(string: "https://github.com/settings/copilot")
        case .cursor: return URL(string: "https://cursor.com/dashboard?tab=billing")
        default: return nil
        }
    }
}

/// 每个窗口独立显示已用比例、剩余比例与重置时间，不把百分比当余额。
private final class QuotaWindowCell: UITableViewCell {
    init(window: AgentQuotaWindow) {
        super.init(style: .default, reuseIdentifier: nil)
        selectionStyle = .none
        isAccessibilityElement = true
        let title = UILabel().then {
            $0.text = QuotaFormatting.shortWindowLabel(window)
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.numberOfLines = 0
        }
        let used = QuotaFormatting.percentText(window.usedPercent)
        let percent = UILabel().then {
            $0.text = used
            $0.font = .preferredFont(forTextStyle: .body)
            $0.adjustsFontForContentSizeCategory = true
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        var detail = String(localized: "剩余\(QuotaFormatting.percentText(window.remainingPercent))", table: "Quota")
        if let reset = window.resetsAt { detail += " · " + QuotaFormatting.resetText(for: reset) }
        if let status = window.status, !status.isEmpty { detail += " · " + status }
        let subtitle = UILabel().then {
            $0.text = detail
            $0.font = .preferredFont(forTextStyle: .footnote)
            $0.adjustsFontForContentSizeCategory = true
            $0.textColor = .secondaryLabel
            $0.numberOfLines = 0
        }
        let progress = UIProgressView(progressViewStyle: .default)
        progress.progress = Float(NSDecimalNumber(decimal: max(0, min(100, window.usedPercent))).doubleValue / 100)
        progress.progressTintColor = window.usedPercent >= 95 ? .systemRed : (window.usedPercent >= 75 ? .systemOrange : .tintColor)
        let heading = UIStackView(arrangedSubviews: [title, percent]).then { $0.axis = .horizontal; $0.spacing = 8 }
        let stack = UIStackView(arrangedSubviews: [heading, progress, subtitle]).then { $0.axis = .vertical; $0.spacing = 6 }
        contentView.addSubview(stack)
        stack.snp.makeConstraints { $0.edges.equalTo(contentView.layoutMarginsGuide) }
        accessibilityLabel = title.text
        accessibilityValue = String(localized: "已用\(used)，\(detail)", table: "Quota")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(window:)") }
}
