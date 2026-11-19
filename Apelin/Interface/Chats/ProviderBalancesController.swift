import ApelinProtocol
import Then
import UIKit

/// 点击余额徽章后的详情页：每个能查询余额的服务商一张卡片——服务商名、大字
/// 余额与币种，底部一行小字左边是这条自己的查询时间，站点地址推到这一行最右端
/// （如 api.deepseek.com）；查询失败的那条以橙色写出原因，站点照旧在最右。列表
/// 从第一张卡开始排，过期的那条排在最前，其余按查询时间从新到旧。查过的余额永远
/// 显示上次的数值（「暂无」只出现在真的一条余额都没有、也从没查到过的时候）。
final class ProviderBalancesController: UITableViewController {
    /// 页内正在画的行，已按排序规则排好。
    private var balances: [ProviderBalance] = []
    private var refreshing = false

    private let emptyContainer = UIView()
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

    /// 过期（本次查询失败）的排最前，其余按查询时间从新到旧：一进页面
    /// 先看到的是需要处理的那条，然后是刚查过的。
    private static func sorted(_ balances: [ProviderBalance]) -> [ProviderBalance] {
        balances.sorted { left, right in
            if left.stale != right.stale { return left.stale }
            return left.updatedAt > right.updatedAt
        }
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
        // 卡片自己画圆角与底色，表格只当容器：不要分隔线，行高按内容算。
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 112
        tableView.register(
            ProviderBalanceCardCell.self,
            forCellReuseIdentifier: ProviderBalanceCardCell.reuseIdentifier,
        )
        buildEmptyState()
        apply(ProviderBalanceStore.shared.balances)
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
        apply(ProviderBalanceStore.shared.balances)
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
            apply(ProviderBalanceStore.shared.balances)
        }
    }

    /// 换一份数据重画：排好序、决定空态，再整表刷新。
    private func apply(_ next: [ProviderBalance]) {
        balances = Self.sorted(next)
        emptyContainer.isHidden = !balances.isEmpty
        tableView.reloadData()
    }

    private func buildEmptyState() {
        emptyContainer.addSubview(emptyCard)
        emptyCard.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            emptyCard.topAnchor.constraint(equalTo: emptyContainer.topAnchor, constant: 16),
            emptyCard.leadingAnchor.constraint(equalTo: emptyContainer.leadingAnchor, constant: 16),
            emptyCard.trailingAnchor.constraint(equalTo: emptyContainer.trailingAnchor, constant: -16),
        ])
        tableView.backgroundView = emptyContainer
    }

    // MARK: - Table

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        balances.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(
            withIdentifier: ProviderBalanceCardCell.reuseIdentifier,
            for: indexPath,
        ) as! ProviderBalanceCardCell
        cell.configure(with: balances[indexPath.row])
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        balances.isEmpty ? nil : String(localized: "A provider that cannot report a balance is not shown; unavailable is not zero.")
    }
}

/// 一个服务商一张卡：名字一行，大字余额 + 币种一行，底部一行小字是查询时间
/// 与站点地址（失败时是失败原因与站点地址）。
final class ProviderBalanceCardCell: UITableViewCell {
    static let reuseIdentifier = "ProviderBalanceCard"

    private let card = UIView()
    private let providerLabel = UILabel()
    private let amountLabel = UILabel()
    private let currencyLabel = UILabel()
    private let timeLabel = UILabel()
    private let hostLabel = UILabel()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        selectionStyle = .none

        card.backgroundColor = .secondarySystemGroupedBackground
        card.layer.cornerRadius = 14
        card.layer.cornerCurve = .continuous
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        providerLabel.font = .preferredFont(forTextStyle: .subheadline)
        providerLabel.textColor = .secondaryLabel
        providerLabel.numberOfLines = 1

        amountLabel.font = .monospacedDigitSystemFont(ofSize: 34, weight: .semibold)
        amountLabel.textColor = .label
        amountLabel.numberOfLines = 1
        amountLabel.adjustsFontSizeToFitWidth = true
        amountLabel.minimumScaleFactor = 0.6
        // 金额很长时先压缩它自己，币种始终留在后面。
        amountLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        currencyLabel.font = .preferredFont(forTextStyle: .footnote)
        currencyLabel.textColor = .secondaryLabel
        currencyLabel.setContentHuggingPriority(.required, for: .horizontal)
        let amountRow = UIStackView(arrangedSubviews: [amountLabel, currencyLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .firstBaseline
            $0.spacing = 6
        }

        // 底部一行：左边是查询时间（失败时是原因），站点推到卡片最右端，
        // 中间留弹性空白，两者不贴在一起。宽度不够时先截断左边的时间。
        timeLabel.font = .preferredFont(forTextStyle: .footnote)
        timeLabel.textColor = .tertiaryLabel
        timeLabel.numberOfLines = 1
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)
        timeLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        hostLabel.font = .preferredFont(forTextStyle: .footnote)
        hostLabel.textColor = .tertiaryLabel
        hostLabel.lineBreakMode = .byTruncatingMiddle
        hostLabel.numberOfLines = 1
        hostLabel.setContentHuggingPriority(.required, for: .horizontal)
        hostLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        // 中间的空白：先被拉伸到占满剩余宽度，也先被压缩到 0。
        let footerGap = UIView().then {
            $0.setContentHuggingPriority(.init(1), for: .horizontal)
            $0.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        }
        let footerRow = UIStackView(arrangedSubviews: [timeLabel, footerGap, hostLabel]).then {
            $0.axis = .horizontal
            $0.alignment = .center
            $0.spacing = 8
        }

        let stack = UIStackView(arrangedSubviews: [providerLabel, amountRow, footerRow]).then {
            $0.axis = .vertical
            $0.alignment = .fill
            $0.spacing = 4
            $0.translatesAutoresizingMaskIntoConstraints = false
        }
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(style:reuseIdentifier:)")
    }

    func configure(with balance: ProviderBalance) {
        providerLabel.text = balance.provider.displayName
        amountLabel.text = balance.amount
        amountLabel.textColor = balance.stale ? .systemOrange : .label
        currencyLabel.text = balance.currency
        hostLabel.text = balance.label
        if balance.stale {
            // 查不到时这一行写原因，站点照旧跟在后面。
            timeLabel.text = balance.problem ?? String(localized: "Balance unavailable")
            timeLabel.textColor = .systemOrange
        } else {
            timeLabel.text = String(
                localized: "Updated \(ProviderBalancesController.relativeTime(balance.updatedAt))",
            )
            timeLabel.textColor = .tertiaryLabel
        }
        accessibilityLabel = "\(balance.provider.displayName)，\(balance.amount) \(balance.currency)"
        accessibilityValue = "\(timeLabel.text ?? "")，\(balance.label)"
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
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
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
}
