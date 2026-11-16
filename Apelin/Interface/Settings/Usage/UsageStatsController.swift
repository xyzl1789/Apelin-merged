import ApelinCore
import Then
import UIKit

/// 设置 ▸ Agent ▸ 用量统计：模型 token 用量的汇总、按模型分组与最近请求。
/// 数据来自 AgentSession 写下的 `<数据根>/usage/usage.jsonl`，与 TrollAgent 的
/// 用量统计同构：一张汇总卡，一组按模型的分项，以及最近的请求明细。
final class UsageStatsController: TableController {
    private enum Section: Hashable, CaseIterable {
        case summary
        case models
        case recent
    }

    private enum Row: Hashable {
        case totals
        case model(String)
        case request(Int)
        case empty
    }

    /// 一次读取的全部记录，按时间新到旧。
    private var records: [UsageRecord] = []
    /// 按模型汇总：模型 id → (请求数, 输入, 输出, 缓存读, 缓存写)。
    private var byModel: [(model: String, count: Int, input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = []
    private var totals: (count: Int, prompt: Int, output: Int, cacheRead: Int, cacheWrite: Int) = (0, 0, 0, 0, 0)
    private var dataSource: UITableViewDiffableDataSource<Section, Row>!
    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let maximumRecent = 50

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "用量统计")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "清空记录"),
            primaryAction: UIAction { [weak self] _ in self?.confirmClear() },
        ).then {
            $0.accessibilityLabel = String(localized: "清空记录")
        }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Usage")
        dataSource = UITableViewDiffableDataSource<Section, Row>(tableView: tableView) { [weak self] tableView, indexPath, row in
            self?.cell(tableView, indexPath: indexPath, row: row) ?? UITableViewCell()
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard snapshot().sectionIdentifiers.indices.contains(section) else { return nil }
        switch snapshot().sectionIdentifiers[section] {
        case .summary: return String(localized: "汇总")
        case .models: return String(localized: "按模型")
        case .recent: return String(localized: "最近请求")
        }
    }

    /// 快照的便捷读取：section 标题里要用。
    private func snapshot() -> NSDiffableDataSourceSnapshot<Section, Row> {
        dataSource.snapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        let url = UsageRecorder.file(in: DataFolder.app.root)
        let loaded = Task.detached { UsageRecorder.readAll(from: url) }
        Task { [weak self] in
            let loaded = await loaded.value.sorted { $0.time > $1.time }
            guard let self else { return }
            records = loaded
            rebuildSummary()
            apply()
        }
    }

    private func rebuildSummary() {
        var models: [String: (Int, Int, Int, Int, Int)] = [:]
        var totals = (count: 0, prompt: 0, output: 0, cacheRead: 0, cacheWrite: 0)
        for record in records {
            let entry = models[record.model, default: (0, 0, 0, 0, 0)]
            models[record.model] = (
                entry.0 + 1,
                entry.1 + record.promptTokens,
                entry.2 + record.output,
                entry.3 + record.cacheRead,
                entry.4 + record.cacheWrite,
            )
        }
        byModel = models
            .map { (model: $0.key, count: $0.value.0, input: $0.value.1, output: $0.value.2, cacheRead: $0.value.3, cacheWrite: $0.value.4) }
            .sorted { $0.input + $0.output > $1.input + $1.output }
        totals.count = records.count
        for entry in byModel {
            totals.prompt += entry.input
            totals.output += entry.output
            totals.cacheRead += entry.cacheRead
            totals.cacheWrite += entry.cacheWrite
        }
        self.totals = totals
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections(Section.allCases)
        snapshot.appendItems([.totals], toSection: .summary)
        if byModel.isEmpty {
            snapshot.appendItems([.empty], toSection: .models)
        } else {
            snapshot.appendItems(byModel.map { .model($0.model) }, toSection: .models)
        }
        let recent: [Row] = records.prefix(Self.maximumRecent).enumerated().map { .request($0.offset) }
        if recent.isEmpty {
            snapshot.appendItems([.empty], toSection: .recent)
        } else {
            snapshot.appendItems(recent, toSection: .recent)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func cell(_ tableView: UITableView, indexPath: IndexPath, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Usage", for: indexPath)
        var content = UIListContentConfiguration.valueCell()
        content.textProperties.numberOfLines = 2
        content.secondaryTextProperties.numberOfLines = 2
        switch row {
        case .totals:
            content.text = String(localized: "全部请求：\(totals.count) 次")
            content.secondaryText = totals.count == 0
                ? String(localized: "还没有用量记录。")
                : String(localized: "输入 \(format(totals.prompt)) ｜ 输出 \(format(totals.output)) ｜ 缓存读 \(format(totals.cacheRead)) ｜ 缓存写 \(format(totals.cacheWrite))")
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case let .model(id):
            guard let entry = byModel.first(where: { $0.model == id }) else { break }
            content.text = id
            content.secondaryText = String(localized: "\(entry.count) 次 ｜ 输入 \(format(entry.input)) ｜ 输出 \(format(entry.output))")
        case let .request(index):
            guard records.indices.contains(index) else { break }
            let record = records[index]
            let time = record.time.formatted(date: .abbreviated, time: .shortened)
            content.text = "\(record.model) ｜ \(time)"
            content.secondaryText = String(localized: "输入 \(format(record.input)) ｜ 输出 \(format(record.output)) ｜ 缓存读 \(format(record.cacheRead)) ｜ 缓存写 \(format(record.cacheWrite))")
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .footnote)
        case .empty:
            content.text = String(localized: "暂无记录")
            cell.accessoryType = .none
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    /// 千位分组：给表格里的 token 数读起来一个形状。
    private func format(_ value: Int) -> String {
        numberFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func confirmClear() {
        let alert = UIAlertController(
            title: String(localized: "清空用量记录？"),
            message: String(localized: "全部 token 用量统计将被删除，无法恢复。"),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "清空"), style: .destructive) { [weak self] _ in
            UsageRecorder.clear(UsageRecorder.file(in: DataFolder.app.root))
            self?.reload()
        })
        present(alert, animated: true)
    }
}
