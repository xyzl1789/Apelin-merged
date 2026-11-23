import UIKit

/// 待投递批次及已进入草稿或历史的附件，只管理 Apelin 自己的副本。
final class StorageSharesController: TableController {
    private enum Section: Hashable { case pending, files, actions }
    private enum Row: Hashable { case pending(UUID), file(ChatRuntime.ShareCopy), clear, empty }

    private let runtime: ChatRuntime
    private var batches: [ShareInbox.StoredBatch] = []
    private var files: [ChatRuntime.ShareFileEntry] = []
    private var busy = false
    private var generation = 0
    private lazy var dataSource = TableDataSource<Section, Row, Row>(tableView: tableView, identifier: { $0 }) {
        [weak self] table, _, row in self?.cell(in: table, row: row)
    }

    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(runtime:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "分享内容")
        dataSource.headerTitle = { section in
            switch section {
            case .pending: String(localized: "待投递")
            case .files: String(localized: "已导入的附件")
            case .actions: nil
            }
        }
        dataSource.footerTitle = { section in
            section == .actions ? String(localized: "只删除 Apelin 的副本，不会删除照片或文件中的原件。") : nil
        }
        let refresh = UIRefreshControl()
        refresh.addAction(UIAction { [weak self] _ in self?.reload() }, for: .valueChanged)
        refreshControl = refresh
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reload()
    }

    private func reload() {
        generation += 1
        let revision = generation
        Task { [weak self] in
            let batches = await Task.detached { ShareInbox.storedBatches() }.value
            guard let self, generation == revision else { return }
            self.batches = batches
            files = runtime.shareFiles()
            var sections: [(Section, [Row])] = []
            if !batches.isEmpty { sections.append((.pending, batches.map { .pending($0.id) })) }
            if !files.isEmpty { sections.append((.files, files.map { .file($0.copy) })) }
            sections.append((.actions, [sections.isEmpty ? .empty : .clear]))
            dataSource.update(sections, reconfigure: true, changedItems: Set(sections.flatMap { $0.1 }))
            refreshControl?.endRefreshing()
        }
    }

    private func cell(in table: UITableView, row: Row) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "share-storage")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "share-storage")
        var content = UIListContentConfiguration.subtitleCell()
        content.secondaryTextProperties.numberOfLines = 2
        cell.accessoryType = .none
        cell.selectionStyle = .default
        switch row {
        case let .pending(id):
            guard let entry = batches.first(where: { $0.id == id }) else { return cell }
            if let batch = entry.batch {
                let caption = String(batch.text.prefix(80))
                content.text = batch.files.first?.name ?? caption
                let target: String
                if runtime.deliveringShares.contains(id) {
                    target = String(localized: "正在投递")
                } else if let id = batch.target {
                    target = runtime.summary(id)?.displayTitle ?? String(localized: "原会话已删除，请重选")
                } else {
                    target = String(localized: "新建会话")
                }
                content.secondaryText = [target, StorageController.format(entry.bytes)].joined(separator: " · ")
            } else {
                content.text = String(localized: "无法读取的分享")
                content.secondaryText = StorageController.format(entry.bytes)
            }
            cell.accessoryType = .disclosureIndicator
        case let .file(copy):
            guard let entry = files.first(where: { $0.copy == copy }) else { return cell }
            content.text = entry.name
            let kind: String
            switch copy {
            case .draft: kind = String(localized: "草稿")
            case .history: kind = String(localized: "历史")
            }
            content.secondaryText = (entry.owners + [kind, StorageController.format(entry.bytes)]
                + (entry.protected ? [String(localized: "暂不可删除")] : [])).joined(separator: " · ")
        case .clear:
            content.text = String(localized: "批量清理")
            content.textProperties.color = .systemRed
        case .empty:
            content.text = String(localized: "没有分享内容")
            content.textProperties.color = .secondaryLabel
            cell.selectionStyle = .none
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard !busy, let row = dataSource.value(at: indexPath) else { return false }
        return row != .empty
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !busy, let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case let .pending(id): pendingActions(id)
        case let .file(copy):
            guard let entry = files.first(where: { $0.copy == copy }) else { return }
            guard !entry.protected else {
                presentNotice(title: "暂不可删除", message: "等相关会话完成发送、排队或运行后再试。")
                return
            }
            let message: String.LocalizationValue
            switch copy {
            case .draft: message = "附件会从草稿移除，草稿文字和系统原件保留。"
            case .history: message = "消息文字保留，但引用这份副本的历史或分叉会话将无法打开该附件。系统原件不变。"
            }
            confirmDelete(pending: [], copies: [copy], message: message)
        case .clear:
            confirmDelete(pending: batches.map(\.id), copies: files.filter { !$0.protected }.map(\.copy),
                          message: "会删除待投递的分享、从草稿移除可清理的附件，并让引用已删除副本的历史或分叉会话无法打开这些附件。发送中、排队或正在使用的内容会跳过。消息文字及系统原件保留。")
        case .empty: break
        }
    }

    private func pendingActions(_ id: UUID) {
        guard let entry = batches.first(where: { $0.id == id }) else { return }
        let names = entry.batch?.files.map(\.name).joined(separator: "\n")
        let alert = UIAlertController(title: String(localized: "待投递分享"), message: names, preferredStyle: .alert)
        if entry.batch != nil, !runtime.deliveringShares.contains(id) {
            alert.addAction(UIAlertAction(title: String(localized: "重试投递"), style: .default) { [weak self] _ in self?.deliver(id) })
            alert.addAction(UIAlertAction(title: String(localized: "重选目标会话"), style: .default) { [weak self] _ in self?.chooseDestination(id) })
        }
        alert.addAction(UIAlertAction(title: String(localized: "删除这批分享"), style: .destructive) { [weak self] _ in
            self?.confirmDelete(pending: [id], copies: [], message: "这批分享将不再投递。系统原件不变。")
        })
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        present(alert, animated: true)
    }

    private func chooseDestination(_ id: UUID) {
        let page = ShareDestinationController(destinations: runtime.summaries.sorted { $0.lastInteraction > $1.lastInteraction }) { [weak self] target in
            guard let self else { return }
            navigationController?.popViewController(animated: false)
            deliver(id, choose: true, target: target)
        }
        navigationController?.pushViewController(page, animated: true)
    }

    private func deliver(_ id: UUID, choose: Bool = false, target: UUID? = nil) {
        guard !busy else { return }
        busy = true
        Task { [weak self] in
            guard let self else { return }
            let result = await runtime.deliverShare(id, retarget: target, chooseTarget: choose)
            busy = false
            switch result {
            case .delivered: break
            case .needsDestination: presentNotice(title: "请选择其他会话", message: "这个会话已不存在，分享仍保留。")
            case .draftFull: presentNotice(title: "草稿附件已满", message: "每个草稿最多 8 个附件。移除一些附件或改投其他会话。")
            case .unavailable: presentNotice(title: "未能投递", message: "如果该批分享仍在列表中，可稍后重试或删除。")
            }
            reload()
        }
    }

    private func confirmDelete(pending: [UUID], copies: [ChatRuntime.ShareCopy], message: String.LocalizationValue) {
        guard !pending.isEmpty || !copies.isEmpty else { return }
        presentConfirmation(title: "删除分享副本？", message: message, confirmTitle: "删除", destructive: true) { [weak self] in
            self?.delete(pending: pending, copies: copies)
        }
    }

    private func delete(pending: [UUID], copies: [ChatRuntime.ShareCopy]) {
        guard !busy else { return }
        busy = true
        Task { [weak self] in
            guard let self else { return }
            var skipped = 0
            for id in pending {
                do { try runtime.deletePendingShare(id) }
                catch { skipped += 1 }
            }
            for copy in copies {
                do { try await runtime.deleteShareCopy(copy) }
                catch { skipped += 1 }
            }
            busy = false
            reload()
            if skipped > 0 {
                presentNotice(title: "有分享副本未删除", message: "有些副本仍在使用或无法删除，请刷新列表后重试。")
            }
        }
    }
}

private final class ShareDestinationController: TableController {
    private let destinations: [ChatSummary]
    private let choose: (UUID?) -> Void

    init(destinations: [ChatSummary], choose: @escaping (UUID?) -> Void) {
        self.destinations = destinations
        self.choose = choose
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(destinations:choose:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "重选目标会话")
    }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { destinations.count + 1 }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "share-target")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "share-target")
        var content = UIListContentConfiguration.subtitleCell()
        if indexPath.row == 0 {
            content.text = String(localized: "新建会话")
        } else {
            let destination = destinations[indexPath.row - 1]
            content.text = destination.displayTitle
            content.secondaryText = destination.projectName
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        choose(indexPath.row == 0 ? nil : destinations[indexPath.row - 1].id)
    }
}
