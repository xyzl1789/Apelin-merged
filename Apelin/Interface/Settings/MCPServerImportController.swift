import ApelinCore
import Then
import UIKit

/// Preview first, then commit only the entries the iOS MCP client can run.
final class MCPServerImportController: TableController, UITextViewDelegate {
    private let store = MCPServerStore(root: DataFolder.app.root)
    private let input = UITextView()
    private var preview: MCPServerImportPreview?
    private var replacingNames: Set<String> = []

    init() { super.init(style: .insetGrouped) }
    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("Use init()") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "导入 MCP JSON"
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "解析", primaryAction: UIAction { [weak self] _ in self?.parse() },
        )
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.autocorrectionType = .no
        input.autocapitalizationType = .none
        input.accessibilityLabel = "MCP JSON 配置"
        input.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "cell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
        tableView.tableFooterView = UIView(frame: .zero)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard section == 1 else { return 1 }
        guard let preview else { return 0 }
        return max(preview.servers.count + preview.unsupported.count, 1)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        if section == 0 { return "粘贴 MCP JSON" }
        guard let preview else { return nil }
        return "导入预览 · \(preview.servers.count) 个可导入 · \(preview.unsupported.count) 个不支持 · \(replacingNames.count) 个同名配置将更新"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 { return "接受标准 mcpServers JSON。iOS 当前仅支持 HTTP Streamable；STDIO/SSE 会在预览中列出并跳过。" }
        return nil
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 0 {
            let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
            input.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(input)
            NSLayoutConstraint.activate([
                input.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                input.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                input.topAnchor.constraint(equalTo: cell.contentView.topAnchor, constant: 8),
                input.bottomAnchor.constraint(equalTo: cell.contentView.bottomAnchor, constant: -8),
                input.heightAnchor.constraint(greaterThanOrEqualToConstant: 240),
            ])
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "cell", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if let preview, indexPath.row < preview.servers.count {
            let server = preview.servers[indexPath.row]
            content.text = server.connection.name
            let replacement = replacingNames.contains(server.connection.name) ? " · 将更新已有配置" : ""
            content.secondaryText = server.connection.url + (server.enabled ? "" : " · 已停用") + replacement
            content.image = UIImage(systemName: "globe")
            content.imageProperties.tintColor = .systemGreen
        } else if let preview, indexPath.row - preview.servers.count < preview.unsupported.count {
            content.text = preview.unsupported[indexPath.row - preview.servers.count]
            content.secondaryText = "此项不会导入"
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
        } else {
            content.text = "没有可导入的 HTTP 配置"
            content.textProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }

    func textViewDidChange(_ textView: UITextView) {
        preview = nil
        replacingNames = []
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "解析", primaryAction: UIAction { [weak self] _ in self?.parse() },
        )
        tableView.reloadSections(IndexSet(integer: 1), with: .automatic)
    }

    private func parse() {
        do {
            let parsed = try store.parseImport(input.text)
            let existingNames = Set(try store.read().servers.items.map { $0.connection.name })
            replacingNames = Set(parsed.servers.map { $0.connection.name }.filter(existingNames.contains))
            preview = parsed
            let count = parsed.servers.count
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "导入", primaryAction: UIAction { [weak self] _ in self?.commit() },
            )
            navigationItem.rightBarButtonItem?.isEnabled = count > 0
        } catch {
            preview = nil
            replacingNames = []
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: "解析", primaryAction: UIAction { [weak self] _ in self?.parse() },
            )
            presentNotice(title: "JSON 无效", message: error.readableMessage)
        }
        tableView.reloadData()
    }

    private func commit() {
        guard let preview else { return }
        do {
            let current = try store.read()
            let existingNames = Set(current.servers.items.map { $0.connection.name })
            let conflicts = preview.servers.map { $0.connection.name }.filter(existingNames.contains).sorted()
            guard !conflicts.isEmpty else {
                try apply(preview)
                return
            }
            presentConfirmation(
                title: "更新同名服务器？",
                message: "这些名称已存在：\(conflicts.joined(separator: "、"))。继续后会用导入内容替换对应配置，包括请求头。",
                cancelTitle: "取消",
                confirmTitle: "更新并导入",
            ) { [weak self] in
                do { try self?.apply(preview) }
                catch { self?.presentNotice(title: "导入失败", message: error.readableMessage) }
            }
        } catch {
            presentNotice(title: "导入失败", message: error.readableMessage)
        }
    }

    private func apply(_ preview: MCPServerImportPreview) throws {
        let current = try store.read()
        let next = try store.merging(preview, into: current)
        _ = try store.save(next)
        navigationController?.popViewController(animated: true)
    }
}
