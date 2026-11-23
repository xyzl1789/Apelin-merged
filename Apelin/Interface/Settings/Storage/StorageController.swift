import ApelinCore
import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// 设置 ▸ 存储：本应用在这台设备上占了多大，只在页面打开时测，一次一个区，
/// 谁的遍历结束就先显示谁，不让最大的目录拖住其他数字。
///
/// 两种清理。守护进程清空没有模型索引的目录（构建、临时文件、导出、日志、
/// 编辑备份），走 `storagePurge`。项目、对话和会话记录属于显示它们的运行时：
/// 从那里删，侧栏与对话列表才会同步忘掉。SDK 与工具链在各自的页面移除，
/// 本页只负责打开它们。
final class StorageController: TableController {
    private enum Section: Hashable, CaseIterable {
        case disk
        case areas
        case purgeable
    }

    private enum Row: Hashable {
        case disk
        case area(StorageArea)
        case shares
        case purge(StorageArea)
        case purgeAll
    }

    private struct RowContent: Equatable {
        let row: Row
        let detail: String?
    }

    /// 本页测量、由运行时或各自的页面删除。
    static let areas: [StorageArea] = [.projects, .chats, .sessions, .sdks, .toolchains]
    /// 由守护进程清空。
    static let purgeable: [StorageArea] = [.builds, .temporary, .exports, .logs, .backups]

    private lazy var dataSource = TableDataSource<Section, Row, RowContent>(
        tableView: tableView,
        identifier: { $0.row },
    ) { [weak self] table, _, content in
        self?.cell(in: table, content: content)
    }

    private var usage: [StorageArea: StorageUsage] = [:]
    private var disk: StorageDisk?
    private var measuring: [StorageArea: Task<Void, Never>] = [:]
    private var diskTask: Task<Void, Never>?
    private var shareTask: Task<Void, Never>?
    private var shareBytes: Int64?
    private var working = false

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Storage")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.headerTitle = { [weak self] section in self?.header(for: section) }
        dataSource.footerTitle = { [weak self] section in self?.footer(for: section) }
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.measureAll() }, for: .valueChanged)
        }
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        measureAll()
    }

    /// 页面离开后不再测量：遍历跟着页面一起停下。
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        measuring.values.forEach { $0.cancel() }
        measuring.removeAll()
        diskTask?.cancel()
        diskTask = nil
        shareTask?.cancel()
        shareTask = nil
    }

    // MARK: - 测量

    private func measureAll() {
        measureDisk()
        measureShares()
        for area in Self.areas + Self.purgeable {
            measure(area, children: false)
        }
        updateRows()
    }

    func measure(_ area: StorageArea, children: Bool) {
        measuring[area]?.cancel()
        measuring[area] = Task { [weak self] in
            let response = try? await ApelinService.app.storageUsage(areas: [area], children: children)
            guard !Task.isCancelled, let self else { return }
            if let measured = response?.usage.first {
                usage[area] = measured
            }
            measuring[area] = nil
            refreshControl?.endRefreshing()
            updateRows()
        }
    }

    private func measureDisk() {
        diskTask?.cancel()
        diskTask = Task { [weak self] in
            let response = try? await ApelinService.app.storageUsage(areas: [], includeDisk: true)
            guard !Task.isCancelled, let self else { return }
            disk = response?.disk
            updateRows()
        }
    }

    private func measureShares() {
        shareTask?.cancel()
        shareTask = Task { [weak self] in
            let staged = await Task.detached { ShareInbox.storedBatches().reduce(Int64(0)) { $0 + $1.bytes } }.value
            guard !Task.isCancelled, let self else { return }
            shareBytes = staged + (runtime?.shareFiles().reduce(Int64(0), { $0 + $1.bytes }) ?? 0)
            updateRows()
        }
    }

    // MARK: - 行

    private func header(for section: Section) -> String? {
        switch section {
        case .disk: nil
        case .areas: String(localized: "On This Device")
        case .purgeable: String(localized: "Can Be Cleared")
        }
    }

    private func footer(for section: Section) -> String? {
        switch section {
        case .disk: nil
        case .areas:
            String(localized: """
            项目与对话会连同 Git 历史和消息一并永久删除。SDK 与工具链在各自的页面移除。
            """)
        case .purgeable:
            String(localized: """
            Apelin 自己清空这些目录。最近一小时内写过的构建目录会保留，以免构建还在用它。
            """)
        }
    }

    private func rows(in section: Section) -> [Row] {
        switch section {
        case .disk: [.disk]
        case .areas: Self.areas.map(Row.area) + [.shares]
        case .purgeable: Self.purgeable.map(Row.purge) + [.purgeAll]
        }
    }

    private func updateRows() {
        dataSource.update(Section.allCases.map { section in
            (section, rows(in: section).map(content(for:)))
        }, reconfigure: true)
    }

    private func content(for row: Row) -> RowContent {
        switch row {
        case .disk:
            return RowContent(row: row, detail: diskText)
        case let .area(area):
            return RowContent(row: row, detail: text(for: area))
        case .shares:
            return RowContent(row: row, detail: shareBytes.map(Self.format) ?? String(localized: "Reading…"))
        case let .purge(area):
            return RowContent(row: row, detail: text(for: area))
        case .purgeAll:
            return RowContent(row: row, detail: purgeableText)
        }
    }

    private var diskText: String? {
        guard let disk else { return String(localized: "Reading…") }
        let available = ByteCountFormatter.string(fromByteCount: disk.available, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: disk.total, countStyle: .file)
        return String(localized: "\(available) available of \(total)")
    }

    /// 每个可清理区都测完之后，它们一共能腾出多少。
    private var purgeableText: String? {
        if let failed = Self.purgeable.first(where: { usage[$0]?.failure != nil }) {
            return "\(Self.name(of: failed)) — \(String(localized: "Unable to Read"))"
        }
        let measured = Self.purgeable.compactMap { usage[$0] }
        guard measured.count == Self.purgeable.count else { return String(localized: "Reading…") }
        let bytes = measured.reduce(Int64(0)) { $0 + $1.bytes }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func text(for area: StorageArea) -> String {
        if let measured = usage[area] {
            guard measured.failure == nil else { return String(localized: "Unable to Read") }
            return Self.format(measured.bytes)
        }
        return measuring[area] == nil ? "" : String(localized: "Reading…")
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    static func name(of area: StorageArea) -> String {
        switch area {
        case .builds: String(localized: "Builds")
        case .temporary: String(localized: "Temporary Files")
        case .exports: String(localized: "Exports")
        case .logs: String(localized: "Logs")
        case .backups: String(localized: "Editing Backups")
        case .projects: String(localized: "Projects")
        case .chats: String(localized: "Conversations")
        case .sessions: String(localized: "Session Records")
        case .sdks: String(localized: "SDKs")
        case .toolchains: String(localized: "Toolchains")
        }
    }

    private func cell(in tableView: UITableView, content value: RowContent) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "storage")
            ?? UITableViewCell(style: .value1, reuseIdentifier: "storage")
        var configuration = UIListContentConfiguration.valueCell()
        configuration.secondaryText = value.detail
        cell.accessoryType = .disclosureIndicator
        cell.selectionStyle = .default
        switch value.row {
        case .disk:
            configuration.text = String(localized: "Device Storage")
            cell.accessoryType = .none
            cell.selectionStyle = .none
        case let .area(area):
            configuration.text = Self.name(of: area)
        case .shares:
            configuration.text = String(localized: "分享内容")
        case let .purge(area):
            configuration.text = Self.name(of: area)
            configuration.textProperties.color = .systemRed
        case .purgeAll:
            configuration.text = String(localized: "Clear Everything Above")
            configuration.textProperties.color = .systemRed
        }
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        guard let row = dataSource.value(at: indexPath)?.row else { return false }
        switch row {
        case .disk: return false
        case .area, .shares, .purge, .purgeAll: return !working
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath)?.row else { return }
        switch row {
        case .disk:
            break
        case let .area(area):
            open(area)
        case .shares:
            guard let runtime else { return }
            push(StorageSharesController(runtime: runtime))
        case let .purge(area):
            confirmPurge([area])
        case .purgeAll:
            confirmPurge(Self.purgeable)
        }
    }

    // MARK: - 有模型的区

    private var runtime: ChatRuntime? {
        (view.window?.rootViewController as? RootInterfaceController)?.conversations
    }

    private func open(_ area: StorageArea) {
        switch area {
        case .projects:
            guard let runtime else { return }
            push(StorageProjectsController(runtime: runtime))
        case .chats:
            guard let runtime else { return }
            push(StorageConversationsController(runtime: runtime))
        case .sessions:
            confirmClearSessions()
        case .sdks:
            push(SDKListController())
        case .toolchains:
            push(ToolchainController())
        case .builds, .temporary, .exports, .logs, .backups:
            break
        }
    }

    private func push(_ page: UIViewController) {
        navigationController?.pushViewController(page, animated: true)
    }

    /// 会话只记录对话进行到哪，不是对话的答案：删掉后对话照常可读，只是
    /// 不能从原处接着做。
    private func confirmClearSessions() {
        guard !(runtime?.hasWorkingConversations ?? false) else {
            presentNotice(
                title: "有对话正在进行",
                message: "等它结束后再清空会话记录。",
            )
            return
        }
        presentTextInput(
            title: "清空会话记录？",
            message: """
            每条对话都保留、照常可读，但不能再从原处接着做：下一条消息会重新开始一个会话。输入 DELETE 以清空。
            """,
            placeholder: "DELETE",
            doneTitle: "清空",
        ) { [weak self] typed in
            guard typed == "DELETE" else { return }
            self?.clearSessions()
        }
    }

    private func clearSessions() {
        guard !working else { return }
        working = true
        let folder = DataFolder.app
        Task { [weak self] in
            let removed = await Task.detached { () -> Int in
                let sessions = folder.sessions
                guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessions.path) else { return 0 }
                var count = 0
                for name in names {
                    let url = sessions.appendingPathComponent(name, isDirectory: true)
                    try? FileManager.default.removeItem(at: url)
                    count += 1
                }
                return count
            }.value
            guard let self else { return }
            working = false
            if removed > 0 {
                SPIndicator.present(title: String(localized: "Cleared"), preset: .done, haptic: .success)
            }
            measure(.sessions, children: false)
        }
    }

    // MARK: - 清空没有模型索引的目录

    private func confirmPurge(_ areas: [StorageArea]) {
        guard !areas.isEmpty, !working else { return }
        let bytes = areas.compactMap { usage[$0]?.failure == nil ? usage[$0] : nil }
            .reduce(Int64(0)) { $0 + $1.bytes }
        let size = Self.format(bytes)
        if areas.count == 1, let area = areas.first {
            presentConfirmation(
                title: "清空\(Self.name(of: area))？",
                message: "\(size) 会被删除，其他内容不受影响。",
                confirmTitle: "清空",
                destructive: true,
            ) { [weak self] in
                self?.purge(areas)
            }
            return
        }
        presentConfirmation(
            title: "清空以上全部？",
            message: "构建、临时文件、导出、日志和编辑备份都会清空，共 \(size)。",
            confirmTitle: "清空",
            destructive: true,
        ) { [weak self] in
            self?.purge(areas)
        }
    }

    private func purge(_ areas: [StorageArea]) {
        guard !working else { return }
        working = true
        Task { [weak self] in
            do {
                _ = try await ApelinService.app.storagePurge(areas)
                guard let self else { return }
                working = false
                SPIndicator.present(title: String(localized: "Cleared"), preset: .done, haptic: .success)
                measureDisk()
                for area in areas {
                    measure(area, children: false)
                }
            } catch {
                guard let self else { return }
                working = false
                presentNotice(title: "无法清空", message: error.readableMessage)
            }
        }
    }
}
