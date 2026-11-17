import ApelinProtocol
import Then
import UIKit

/// 点击余额圆环后的详情页：每个服务商的实际余额、币种、刷新时间，以及
/// 手动刷新按钮。确定不支持的服务商不会出现在列表里；「未查到」不等于
/// 余额为 0，这句话只在这里说明。
final class ProviderBalancesController: TableController {
    private enum Row: Hashable {
        case balance(String)
        case empty
        case note
    }

    private var balances: [ProviderBalance] = []
    private var dataSource: UITableViewDiffableDataSource<Int, Row>!
    private var refreshing = false
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()

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
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Refresh"),
            primaryAction: UIAction { [weak self] _ in self?.refresh() },
        ).then {
            $0.accessibilityLabel = String(localized: "Refresh")
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Balance")
        dataSource = UITableViewDiffableDataSource<Int, Row>(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(tableView, indexPath: indexPath, row: row) ?? UITableViewCell()
        }
        apply()
        refresh()
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "A provider that cannot report a balance is not shown; unavailable is not zero.")
    }

    /// 手动刷新：强制绕过 worker 的短缓存，并让圆环同时更新。
    @objc private func refresh() {
        guard !refreshing else { return }
        refreshing = true
        navigationItem.rightBarButtonItem?.isEnabled = false
        Task { [weak self] in
            _ = await ProviderBalanceStore.shared.refresh(force: true)
            guard let self else { return }
            refreshing = false
            navigationItem.rightBarButtonItem?.isEnabled = true
            balances = ProviderBalanceStore.shared.balances
            apply()
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(balances.map { .balance($0.accountID) }, toSection: 0)
        if balances.isEmpty {
            snapshot.appendItems([.empty], toSection: 0)
        }
        snapshot.appendItems([.note], toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func cell(_ tableView: UITableView, indexPath: IndexPath, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Balance", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.numberOfLines = 2
        switch row {
        case .empty:
            content.text = String(localized: "No balance to show")
            content.secondaryText = nil
        case .note:
            content.text = String(localized: "Last refresh")
            content.secondaryText = balances.first.map { Self.timeFormatter.string(from: $0.updatedAt) }
                ?? String(localized: "Never")
        case let .balance(id):
            guard let balance = balances.first(where: { $0.accountID == id }) else { break }
            content.text = "\(balance.provider.displayName) · \(balance.label)"
            let amount = ProviderBalanceButton.amountText(balance)
            let time = Self.timeFormatter.string(from: balance.updatedAt)
            content.secondaryText = balance.stale
                ? String(localized: "\(amount) · \(balance.problem ?? "Balance unavailable") · \(time)")
                : String(localized: "\(amount) · \(time)")
            cell.accessibilityValue = content.secondaryText
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
