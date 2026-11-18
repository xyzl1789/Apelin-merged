import ApelinProtocol
import Then
import UIKit

/// 点击余额徽章后的详情页：每个服务商一条卡片——服务商名、账户标签、
/// 余额数字（大字）、币种、该条自己的查询时间；查询失败的那条以橙色
/// 标出原因。顶部是当前选中服务商的汇总卡，支持查询的服务商在页内
/// 立即刷新。查过的余额永远显示上次的数值（「暂无」只出现在真的
/// 一条余额都没有、也从没查到过的时候）。
final class ProviderBalancesController: UITableViewController {
    private var balances: [ProviderBalance] = []
    private var refreshing = false

    private let spinnerContainer = UIView()
    private let summaryCard = ProviderBalanceSummaryCard()
    private let emptyCard = ProviderBalanceEmptyCard()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

    /// 「x 分钟前」式的相对时间：一分钟内说「刚刚」。
    static func relativeTime(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return String(localized: "just now") }
        if interval < 3600 {
            return String(localized: "\(Int(interval / 60))m ago")
        }
        if interval < 86_400 {
            return String(localized: "\(Int(interval / 3600))h ago")
        }
        return timeFormatter.string(from: date)
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Provider Balances")
        navigationItem.backButtonDisplayMode = .minimal
        let refreshItem = UIBarButtonItem(
            title: String(localized: "Refresh"),
            primaryAction: UIAction { [weak self] _ in self?.refresh(force: true) },
        ).then {
            $0.accessibilityLabel = String(localized: "Refresh")
        }
        navigationItem.rightBarButtonItem = refreshItem
        balances = ProviderBalanceStore.shared.balances
        tableView.separatorInset = UIEdgeInsets(top: 0, left: 20, bottom: 0, right: 20)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Balance")
        tableView.tableFooterView = makeFooter()
        refresh()
    }

    /// 打开页面时若距上次查询超过一分钟就自动刷新一次（页头刷新按钮
    /// 才强制绕过 worker 缓存）。
    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        NotificationCenter.default.addObserver(
            self, selector: #selector(balancesChanged),
            name: .providerBalancesChanged, object: nil,
        )
        if ProviderBalanceStore.shared.balances.isEmpty
            || Date().timeIntervalSince(ProviderBalanceStore.shared.balances.map(\.updatedAt).max() ?? .distantPast) > 60
        {
            refresh()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        NotificationCenter.default.removeObserver(self, name: .providerBalancesChanged, object: nil)
    }

    @objc private func balancesChanged() {
        balances = ProviderBalanceStore.shared.balances
        reload()
    }

    /// 手动刷新：强制绕过 worker 的短缓存，按钮转菊花，页内所有数字
    /// 与徽章一起更新（store 发 providerBalancesChanged）。
    private func refresh(force: Bool = false) {
        guard !refreshing else { return }
        refreshing = true
        let item = navigationItem.rightBarButtonItem
        item?.isEnabled = false
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.startAnimating()
        item?.customView = spinner
        Task { [weak self] in
            _ = await ProviderBalanceStore.shared.refresh(force: force)
            guard let self else { return }
            refreshing = false
            item?.customView = nil
            item?.isEnabled = true
            balances = ProviderBalanceStore.shared.balances
            reload()
        }
    }

    private func reload() {
        summaryCard.configure(
            selection: nil,
            balances: balances,
        )
        summaryCard.setNeedsLayout()
        tableView.reloadData()
        tableView.tableFooterView = makeFooter()
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        balances.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        balances.isEmpty ? nil : String(localized: "All Providers")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Balance", for: indexPath)
        let balance = balances[indexPath.row]
        var content = UIListContentConfiguration.valueCell()
        content.text = balance.provider.displayName
        content.secondaryText = balance.label
        content.textProperties.font = .preferredFont(forTextStyle: .body)
        content.textProperties.numberOfLines = 1
        content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        content.secondaryTextProperties.color = .secondaryLabel
        content.secondaryTextProperties.numberOfLines = 1
        // 右侧大字余额 + 币种小字，失败的那条橙色并写原因。
        let amountLabel = UILabel()
        amountLabel.text = balance.amount
        amountLabel.font = .monospacedDigitSystemFont(ofSize: 17, weight: .semibold)
        amountLabel.textAlignment = .right
        amountLabel.adjustsFontSizeToFitWidth = true
        amountLabel.textColor = balance.stale ? .systemOrange : .label
        let currencyLabel = UILabel()
        currencyLabel.text = balance.currency
        currencyLabel.font = .preferredFont(forTextStyle: .footnote)
        currencyLabel.textColor = .secondaryLabel
        let stack = UIStackView(arrangedSubviews: [amountLabel, currencyLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .firstBaseline
            $0.spacing = 4
        }
        cell.contentConfiguration = content
        cell.accessoryView = stack
        cell.accessibilityValue = "\(balance.amount) \(balance.currency)，\(Self.relativeTime(balance.updatedAt))"
        if balance.stale {
            cell.accessibilityValue = "\(cell.accessibilityValue ?? "")，\(balance.problem ?? String(localized: "Balance unavailable"))"
        }
        cell.selectionStyle = .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "A provider that cannot report a balance is not shown; unavailable is not zero.")
    }

    // MARK: - Header & footer

    /// 顶部汇总卡：当前选中服务商的余额（查过就显示上次数值），下面
    /// 一行小字写刷新时间；没有任何可显示的余额时换空态卡。
    override func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if balances.isEmpty {
            emptyCard.configure()
            return emptyCard
        }
        summaryCard.configure(selection: currentSelectionProvider(), balances: balances)
        return summaryCard
    }

    override func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        balances.isEmpty ? 120 : 108
    }

    /// 当前聊天页选中的服务商；从模型选择里读，与徽章同一来源。
    private func currentSelectionProvider() -> AgentProvider? {
        ComposerModelSelection.selection(for: ChatStore.shared.activeChatID ?? UUID())?.provider
    }

    private func makeFooter() -> UIView {
        let container = UIView()
        let label = UILabel()
        if let latest = balances.map(\.updatedAt).max() {
            label.text = String(localized: "Last refresh \(Self.relativeTime(latest))")
        } else {
            label.text = String(localized: "Not refreshed yet")
        }
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = .secondaryLabel
        label.textAlignment = .center
        label.frame = CGRect(x: 0, y: 8, width: tableView.bounds.width, height: 20)
        container.addSubview(label)
        container.frame = CGRect(x: 0, y: 0, width: tableView.bounds.width, height: 32)
        return container
    }
}

/// 顶部汇总卡：当前选中服务商的名字 + 大字余额 + 刷新时间。
final class ProviderBalanceSummaryCard: UIView {
    private let providerLabel = UILabel()
    private let amountLabel = UILabel()
    private let timeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        providerLabel.font = .preferredFont(forTextStyle: .subheadline)
        providerLabel.textColor = .secondaryLabel
        amountLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        amountLabel.textColor = .label
        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        timeLabel.textColor = .tertiaryLabel
        let stack = UIStackView(arrangedSubviews: [providerLabel, amountLabel, timeLabel]).then {
            $0.axis = .vertical
            $0.alignment = .leading
            $0.spacing = 4
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func configure(selection provider: AgentProvider?, balances: [ProviderBalance]) {
        // 当前选中且有自己余额的服务商优先；否则取最近更新的一条代表。
        let balance = provider.flatMap { own in balances.first { $0.provider == own } }
            ?? balances.max { $0.updatedAt < $1.updatedAt }
        guard let balance else {
            providerLabel.text = nil
            amountLabel.text = "--"
            timeLabel.text = nil
            return
        }
        providerLabel.text = balance.provider.displayName
        amountLabel.text = "\(balance.amount) \(balance.currency)"
        amountLabel.textColor = balance.stale ? .systemOrange : .label
        timeLabel.text = String(localized: "Updated \(ProviderBalancesController.relativeTime(balance.updatedAt))")
        accessibilityLabel = String(localized: "Provider Balances")
        accessibilityValue = "\(balance.provider.displayName)，\(balance.amount) \(balance.currency)"
    }
}

/// 一条余额都没有时的空态卡：不是「余额为 0」，是没有任何服务商支持
/// 或查到过余额。
final class ProviderBalanceEmptyCard: UIView {
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        titleLabel.font = .preferredFont(forTextStyle: .headline)
        titleLabel.text = String(localized: "No balance to show")
        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = .secondaryLabel
        detailLabel.text = String(localized: "Sign in to a provider that reports a balance, then tap Refresh.")
        detailLabel.numberOfLines = 0
        let stack = UIStackView(arrangedSubviews: [titleLabel, detailLabel]).then {
            $0.axis = .vertical
            $0.spacing = 6
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = titleLabel.text
        accessibilityValue = detailLabel.text
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func configure() {}
}
