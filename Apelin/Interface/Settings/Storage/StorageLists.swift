import ApelinCore
import ApelinProtocol
import SPIndicator
import Then
import UIKit

/// 设置 ▸ 存储 ▸ 项目：每个项目及其目录大小，从运行时删除，侧栏随即忘掉它。
/// 目录、其中的文件和 Git 历史都会消失，无法恢复。
final class StorageProjectsController: TableController {
    private enum Row: Hashable {
        case deleteAll
        case project(name: String, title: String, bytes: Int64?)
        case reading
        case empty
    }

    private lazy var dataSource = TableDataSource<String, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case .deleteAll: "delete-all"
            case let .project(name, _, _): "project:" + name
            case .reading: "reading"
            case .empty: "empty"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let runtime: ChatRuntime
    private var projects: [ProjectSummary] = []
    private var sizes: [String: StorageEntry] = [:]
    private var loading = false
    private var deleting = false

    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(runtime:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Projects")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.footerTitle = { _ in
            String(localized: """
            项目的目录、其中的文件和 Git 历史会被删除，其中的每条对话也会一并消失。
            """)
        }
        tableView.backgroundView = LoadingView()
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            let projects = (try? await ProjectSummary.load()) ?? []
            let response = try? await ApelinService.app.storageUsage(areas: [.projects], children: true)
            guard let self else { return }
            loading = false
            self.projects = projects
            var sizes: [String: StorageEntry] = [:]
            for entry in response?.usage.first?.entries ?? [] {
                sizes[entry.name] = entry
            }
            self.sizes = sizes
            refreshControl?.endRefreshing()
            tableView.backgroundView = projects.isEmpty
                ? EmptyStateView(
                    symbolName: "folder",
                    title: String(localized: "No Projects"),
                    text: String(localized: "A project appears here once one is made."),
                )
                : nil
            show()
        }
    }

    private func show() {
        var rows: [Row] = []
        if !projects.isEmpty {
            rows.append(.deleteAll)
            rows.append(contentsOf: projects.map { project in
                .project(
                    name: project.name,
                    title: project.displayTitle,
                    bytes: sizes[project.name]?.bytes,
                )
            })
        } else {
            rows.append(.empty)
        }
        dataSource.update([("projects", rows)], reconfigure: true)
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "storage-project")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "storage-project")
        var content = UIListContentConfiguration.subtitleCell()
        switch row {
        case .deleteAll:
            content.text = String(localized: "Delete Every Project")
            content.textProperties.color = .systemRed
            cell.accessoryType = .none
            cell.selectionStyle = .default
            cell.isAccessibilityElement = false
        case let .project(name, title, bytes):
            content.text = title
            let size = bytes.map(StorageController.format)
            content.secondaryText = [name == title ? nil : name, size]
                .compactMap { $0 }
                .joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .default
            // 行自己画两行字，所以它才是无障碍的那一整个元素。
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = title
            cell.accessibilityValue = ([name == title ? nil : name, size] as [String?])
                .compactMap { $0 }
                .joined(separator: ", ")
            cell.accessibilityTraits = .button
        case .reading:
            content.text = String(localized: "Reading…")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
        case .empty:
            content.text = String(localized: "No Projects")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath) {
        case .deleteAll, .project: return !deleting
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .deleteAll:
            confirmDeleteAll()
        case let .project(name, title, bytes):
            confirmDelete(name: name, title: title, bytes: bytes)
        default:
            break
        }
    }

    private func confirmDelete(name: String, title: String, bytes: Int64?) {
        let size = bytes.map(StorageController.format) ?? String(localized: "Unknown Size")
        presentConfirmation(
            title: "删除\(title)？",
            message: """
            Projects/\(name) 的 \(size) 连同 Git 历史一并删除，其中的每条对话也会消失。此操作无法撤销。
            """,
            confirmTitle: "删除",
            destructive: true,
        ) { [weak self] in
            self?.delete(name)
        }
    }

    private func confirmDeleteAll() {
        presentTextInput(
            title: "删除所有项目？",
            message: """
            Projects/ 下的每个目录连同 Git 历史一并删除，其中的每条对话也会消失。此操作无法撤销。输入 DELETE 以继续。
            """,
            placeholder: "DELETE",
            doneTitle: "全部删除",
        ) { [weak self] typed in
            guard typed == "DELETE" else { return }
            self?.deleteAll()
        }
    }

    private func delete(_ name: String) {
        guard !deleting else { return }
        deleting = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await runtime.deleteProject(name)
                deleting = false
                SPIndicator.present(title: String(localized: "Deleted"), preset: .done, haptic: .success)
            } catch {
                deleting = false
                presentNotice(title: "无法删除项目", message: error.readableMessage)
            }
            load()
        }
    }

    private func deleteAll() {
        guard !deleting else { return }
        deleting = true
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for project in projects {
                do {
                    try await runtime.deleteProject(project.name)
                } catch {
                    failed += 1
                }
            }
            deleting = false
            if failed > 0 {
                presentNotice(title: "无法删除项目", message: "有些目录没能删除。")
            } else {
                SPIndicator.present(title: String(localized: "Deleted"), preset: .done, haptic: .success)
            }
            load()
        }
    }
}

/// 设置 ▸ 存储 ▸ 对话：每条对话的记录与事件日志大小，从运行时删除，侧栏的行
/// 随即一起消失。
final class StorageConversationsController: TableController {
    private enum Row: Hashable {
        case deleteAll
        case conversation(id: UUID, title: String, project: String?, bytes: Int64?)
        case empty
    }

    private lazy var dataSource = TableDataSource<String, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case .deleteAll: "delete-all"
            case let .conversation(id, _, _, _): "chat:" + id.uuidString
            case .empty: "empty"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let runtime: ChatRuntime
    private var sizes: [String: Int64] = [:]
    private var loading = false
    private var deleting = false

    init(runtime: ChatRuntime) {
        self.runtime = runtime
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(runtime:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Conversations")
        navigationItem.backButtonDisplayMode = .minimal
        dataSource.footerTitle = { _ in
            String(localized: """
            对话的消息与智能体续接用的记录会一并删除，无法恢复。
            """)
        }
        tableView.backgroundView = LoadingView()
        refreshControl = UIRefreshControl().then {
            $0.addAction(UIAction { [weak self] _ in self?.load() }, for: .valueChanged)
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        guard !loading else { return }
        loading = true
        Task { [weak self] in
            let response = try? await ApelinService.app.storageUsage(areas: [.chats], children: true)
            guard let self else { return }
            loading = false
            var sizes: [String: Int64] = [:]
            for entry in response?.usage.first?.entries ?? [] {
                sizes[entry.name] = entry.bytes
            }
            self.sizes = sizes
            refreshControl?.endRefreshing()
            tableView.backgroundView = rows().count <= 1
                ? EmptyStateView(
                    symbolName: "bubble.left.and.bubble.right",
                    title: String(localized: "No Conversations"),
                    text: String(localized: "A conversation appears here once one is started."),
                )
                : nil
            dataSource.update([("chats", rows())], reconfigure: true)
        }
    }

    private func rows() -> [Row] {
        let summaries = runtime.summaries.sorted { $0.lastInteraction > $1.lastInteraction }
        guard !summaries.isEmpty else { return [.empty] }
        return [.deleteAll] + summaries.map { summary in
            .conversation(
                id: summary.id,
                title: summary.title,
                project: summary.projectName,
                bytes: sizes[summary.id.uuidString] ?? sizes[summary.id.uuidString.lowercased()],
            )
        }
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "storage-chat")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "storage-chat")
        var content = UIListContentConfiguration.subtitleCell()
        switch row {
        case .deleteAll:
            content.text = String(localized: "Delete Every Conversation")
            content.textProperties.color = .systemRed
            cell.accessoryType = .none
            cell.isAccessibilityElement = false
        case let .conversation(_, title, project, bytes):
            content.text = title
            content.textProperties.numberOfLines = 1
            let size = bytes.map(StorageController.format)
            content.secondaryText = [project, size].compactMap { $0 }.joined(separator: " · ")
            content.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.isAccessibilityElement = true
            cell.accessibilityLabel = title
            cell.accessibilityValue = [project, size].compactMap { $0 }.joined(separator: ", ")
            cell.accessibilityTraits = .button
        case .empty:
            content.text = String(localized: "No Conversations")
            content.textProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath) {
        case .deleteAll, .conversation: return !deleting
        default: return false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .deleteAll:
            confirmDeleteAll()
        case let .conversation(id, title, _, bytes):
            let size = bytes.map(StorageController.format) ?? String(localized: "Unknown Size")
            presentConfirmation(
                title: "删除\(title)？",
                message: "\(size) 的消息以及智能体续接用的记录会一并删除。此操作无法撤销。",
                confirmTitle: "删除",
                destructive: true,
            ) { [weak self] in
                self?.delete([id])
            }
        default:
            break
        }
    }

    private func confirmDeleteAll() {
        presentTextInput(
            title: "删除所有对话？",
            message: """
            每条对话的消息以及智能体续接用的记录都会被删除。此操作无法撤销。输入 DELETE 以继续。
            """,
            placeholder: "DELETE",
            doneTitle: "全部删除",
        ) { [weak self] typed in
            guard typed == "DELETE" else { return }
            self?.delete(self?.runtime.summaries.map(\.id) ?? [])
        }
    }

    private func delete(_ ids: [UUID]) {
        guard !deleting, !ids.isEmpty else { return }
        deleting = true
        Task { [weak self] in
            guard let self else { return }
            var failed = 0
            for id in ids {
                do {
                    try await runtime.delete(id)
                } catch {
                    failed += 1
                }
            }
            deleting = false
            if failed > 0 {
                presentNotice(title: "无法删除对话", message: "有些对话没能删除。")
            } else {
                SPIndicator.present(title: String(localized: "Deleted"), preset: .done, haptic: .success)
            }
            load()
        }
    }
}
