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
        title = String(localized: "Import MCP JSON")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Parse"), primaryAction: UIAction { [weak self] _ in self?.parse() },
        )
        input.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        input.autocorrectionType = .no
        input.autocapitalizationType = .none
        input.accessibilityLabel = String(localized: "MCP JSON Configuration")
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
        if section == 0 { return String(localized: "Paste MCP JSON") }
        guard let preview else { return nil }
        return String(localized: "Import Preview · \(preview.servers.count) importable · \(preview.unsupported.count) unsupported · \(replacingNames.count) existing will be updated")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        if section == 0 {
            return String(localized: "Takes a standard mcpServers JSON. iOS supports HTTP Streamable only; STDIO and SSE entries are listed in the preview and skipped.")
        }
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
            let replacement = replacingNames.contains(server.connection.name) ? " · " + String(localized: "Will update the existing entry") : ""
            content.secondaryText = server.connection.url + (server.enabled ? "" : " · " + String(localized: "Off")) + replacement
            content.image = UIImage(systemName: "globe")
            content.imageProperties.tintColor = .systemGreen
        } else if let preview, indexPath.row - preview.servers.count < preview.unsupported.count {
            content.text = preview.unsupported[indexPath.row - preview.servers.count]
            content.secondaryText = String(localized: "This entry is not imported")
            content.image = UIImage(systemName: "exclamationmark.triangle.fill")
            content.imageProperties.tintColor = .systemOrange
        } else {
            content.text = String(localized: "No HTTP entry to import")
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
            title: String(localized: "Parse"), primaryAction: UIAction { [weak self] _ in self?.parse() },
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
                title: String(localized: "Import"), primaryAction: UIAction { [weak self] _ in self?.commit() },
            )
            navigationItem.rightBarButtonItem?.isEnabled = count > 0
        } catch {
            preview = nil
            replacingNames = []
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: String(localized: "Parse"), primaryAction: UIAction { [weak self] _ in self?.parse() },
            )
            presentNotice(title: "Invalid JSON", message: error.readableMessage)
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
                title: "Update Existing Servers?",
                message: "These names already exist: \(conflicts.joined(separator: ", ")). Continuing replaces their configuration with the imported one, request headers included.",
                cancelTitle: "Cancel",
                confirmTitle: "Update and Import",
            ) { [weak self] in
                do { try self?.apply(preview) }
                catch { self?.presentNotice(title: "Import Failed", message: error.readableMessage) }
            }
        } catch {
            presentNotice(title: "Import Failed", message: error.readableMessage)
        }
    }

    private func apply(_ preview: MCPServerImportPreview) throws {
        let current = try store.read()
        let next = try store.merging(preview, into: current)
        _ = try store.save(next)
        navigationController?.popViewController(animated: true)
    }
}
