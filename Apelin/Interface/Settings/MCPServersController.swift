import ApelinCore
import Then
import UIKit

/// HTTP MCP servers available to a session when it opens.
final class MCPServersController: TableController {
    private struct Row: Equatable {
        let id: String
        let name: String
        let url: String
        let enabled: Bool
    }

    private lazy var dataSource = TableDataSource<Int, String, Row>(
        tableView: tableView, identifier: { $0.id }
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }
    private let store = MCPServerStore(root: DataFolder.app.root)
    private var snapshot = MCPServerSnapshot()

    init() { super.init(style: .insetGrouped) }
    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("Use init()") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "MCP Servers")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: nil,
            menu: UIMenu(children: [
                UIAction(title: String(localized: "Add Server Manually"), image: UIImage(systemName: "plus")) { [weak self] _ in self?.add() },
                UIAction(title: String(localized: "Import JSON"), image: UIImage(systemName: "doc.text")) { [weak self] _ in self?.importJSON() },
                UIAction(title: String(localized: "Copy Configuration JSON"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyJSON() },
                UIAction(title: String(localized: "Share Configuration JSON"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.shareJSON() },
            ]),
        ).then { $0.accessibilityLabel = String(localized: "Add MCP Server") }
        dataSource.allowsEditing = true
        dataSource.footerTitle = { _ in
            String(localized: "MCP changes take effect when a conversation is opened again. Each tool still needs approval according to your permission mode.")
        }
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        do {
            snapshot = try store.read()
            let rows = snapshot.servers.items.map {
                Row(id: $0.id, name: $0.connection.name, url: $0.connection.url, enabled: $0.enabled)
            }
            dataSource.update([(0, rows)], reconfigure: true)
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
        }
    }

    private func cell(in table: UITableView, row: Row) -> UITableViewCell {
        let cell = table.dequeueReusableCell(withIdentifier: "mcp")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "mcp")
        var content = UIListContentConfiguration.subtitleCell()
        content.text = row.name
        content.secondaryText = String(localized: "HTTP Streamable") + " · " + row.url
            + (row.enabled ? "" : " · " + String(localized: "Off"))
        content.secondaryTextProperties.numberOfLines = 2
        content.image = UIImage(systemName: "circle.fill")
        content.imageProperties.tintColor = row.enabled ? .systemGreen : .tertiaryLabel
        cell.contentConfiguration = content
        cell.accessoryType = .disclosureIndicator
        return cell
    }

    private func add() {
        guard snapshot.servers.items.count + snapshot.servers.unreadable.count < MCPServerStore.maximumServers else {
            presentNotice(title: "Error", message: MCPStoreError.full.localizedDescription)
            return
        }
        navigationController?.pushViewController(MCPServerEditorController(record: nil), animated: true)
    }

    private func importJSON() {
        navigationController?.pushViewController(MCPServerImportController(), animated: true)
    }

    private func exportJSON() -> String? {
        do { return try store.exportJSON(snapshot.servers.items) }
        catch { presentNotice(title: "Error", message: error.readableMessage); return nil }
    }

    private func copyJSON() {
        guard let text = exportJSON() else { return }
        presentConfirmation(
            title: "Copy MCP Configuration?",
            message: "The exported JSON includes custom request headers, which may hold access tokens. Keep the copied text safe.",
            confirmTitle: "Copy",
        ) { UIPasteboard.general.string = text }
    }

    private func shareJSON() {
        guard let text = exportJSON() else { return }
        presentConfirmation(
            title: "Share MCP Configuration?",
            message: "The exported JSON includes custom request headers, which may hold access tokens. Share it only with someone you trust.",
            confirmTitle: "Continue",
        ) { [weak self] in
            guard let self else { return }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcp-servers-\(UUID().uuidString).json")
            do {
                try Data(text.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                sheet.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: file)
                }
                if let popover = sheet.popoverPresentationController {
                    popover.barButtonItem = navigationItem.rightBarButtonItem
                }
                present(sheet, animated: true)
            } catch {
                try? FileManager.default.removeItem(at: file)
                presentNotice(title: "Error", message: error.readableMessage)
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let id = dataSource.value(at: indexPath)?.id,
              let record = snapshot.servers.items.first(where: { $0.id == id }) else { return }
        navigationController?.pushViewController(MCPServerEditorController(record: record), animated: true)
    }

    override func tableView(_ tableView: UITableView, contextMenuConfigurationForRowAt indexPath: IndexPath,
                            point: CGPoint) -> UIContextMenuConfiguration? {
        guard let id = dataSource.value(at: indexPath)?.id,
              let record = snapshot.servers.items.first(where: { $0.id == id }) else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(title: String(localized: "View and Refresh Tools"), image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
                    self?.showTools(for: record)
                },
                UIAction(title: record.enabled ? String(localized: "Disable") : String(localized: "Enable"),
                         image: UIImage(systemName: record.enabled ? "pause.circle" : "play.circle")) { [weak self] _ in
                    self?.setEnabled(!record.enabled, for: record)
                },
            ])
        }
    }

    private func setEnabled(_ enabled: Bool, for record: MCPServerRecord) {
        do {
            var next = try store.read()
            guard let index = next.servers.items.firstIndex(where: { $0.id == record.id }) else { return }
            next.servers.items[index].enabled = enabled
            try store.save(next)
            load()
        } catch { presentNotice(title: "Error", message: error.readableMessage) }
    }

    private func showTools(for record: MCPServerRecord) {
        let controller = MCPServerToolsController(serverName: record.connection.name)
        let navigation = SheetNavigationController(rootViewController: controller)
        navigation.modalPresentationStyle = .pageSheet
        present(navigation, animated: true)
    }

    override func tableView(_: UITableView, editingStyleForRowAt _: IndexPath) -> UITableViewCell.EditingStyle {
        .delete
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, let id = dataSource.value(at: indexPath)?.id,
              let record = snapshot.servers.items.first(where: { $0.id == id }) else { return }
        presentConfirmation(
            title: "Remove \(record.connection.name)?",
            message: "This MCP server will not be available to conversations opened later.",
            confirmTitle: "Remove", destructive: true
        ) { [weak self] in
            guard let self else { return }
            var next = snapshot
            next.servers.items.removeAll { $0.id == id }
            do { try store.save(next); load() }
            catch { presentNotice(title: "Error", message: error.readableMessage) }
        }
    }
}

/// The fields are staged here; Save validates the entire record and persists
/// it. Back discards edits, so an incomplete URL never disables a server.
final class MCPServerEditorController: TableController, UITextViewDelegate {
    private enum Row: String { case name, url, note, headers, enabled }
    private lazy var dataSource = TableDataSource<Int, String, Row>(
        tableView: tableView, identifier: { $0.rawValue }
    ) { [weak self] table, _, row in self?.cell(in: table, row: row) }
    private let store = MCPServerStore(root: DataFolder.app.root)
    private let original: MCPServerRecord?
    private let nameField = UITextField()
    private let urlField = UITextField()
    private let noteField = UITextField()
    private let headersView = UITextView()
    private let enabledSwitch = UISwitch()

    init(record: MCPServerRecord?) {
        original = record
        super.init(style: .insetGrouped)
    }
    @available(*, unavailable) required init?(coder _: NSCoder) { fatalError("Use init()") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = original?.connection.name ?? String(localized: "New MCP Server")
        let exportMenu = UIMenu(children: [
            UIAction(title: String(localized: "Copy This Server's JSON"), image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copyCurrentJSON() },
            UIAction(title: String(localized: "Share This Server's JSON"), image: UIImage(systemName: "square.and.arrow.up")) { [weak self] _ in self?.shareCurrentJSON() },
        ])
        navigationItem.rightBarButtonItems = [
            UIBarButtonItem(title: String(localized: "Save"), primaryAction: UIAction { [weak self] _ in self?.save() }),
            UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), primaryAction: nil, menu: exportMenu),
        ]
        tableView.keyboardDismissMode = .interactive
        configure(nameField, label: String(localized: "Server Name"), value: original?.connection.name)
        configure(urlField, label: String(localized: "Server URL"), value: original?.connection.url)
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        configure(noteField, label: String(localized: "Description"), value: original?.connection.note)
        headersView.text = original?.connection.headers.sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }.joined(separator: "\n") ?? ""
        headersView.font = .preferredFont(forTextStyle: .body)
        headersView.adjustsFontForContentSizeCategory = true
        headersView.autocapitalizationType = .none
        headersView.autocorrectionType = .no
        headersView.accessibilityLabel = String(localized: "HTTP Headers")
        enabledSwitch.isOn = original?.enabled ?? true
        enabledSwitch.accessibilityLabel = String(localized: "Enabled")
        dataSource.headerTitle = { section in
            switch section {
            case 0: String(localized: "HTTP Streamable")
            case 1: String(localized: "HTTP Headers")
            default: nil
            }
        }
        dataSource.footerTitle = { section in
            switch section {
            case 0: String(localized: "iOS supports HTTP Streamable only for now. Enter the server's full MCP HTTP endpoint.")
            case 1: String(localized: "One header per line: Name: value. Tokens are stored in this app's data folder.")
            case 2: String(localized: "Go back to discard unsaved changes. New settings apply when the conversation is opened again.")
            default: nil
            }
        }
        dataSource.update([(0, [.name, .url, .note]), (1, [.headers]), (2, [.enabled])])
    }

    private func configure(_ field: UITextField, label: String, value: String?) {
        field.text = value
        field.placeholder = label
        field.accessibilityLabel = label
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
    }

    private func cell(in table: UITableView, row: Row) -> UITableViewCell {
        if row == .enabled {
            let cell = table.dequeueReusableCell(withIdentifier: "switch")
                ?? UITableViewCell(style: .default, reuseIdentifier: "switch")
            var content = UIListContentConfiguration.cell()
            content.text = String(localized: "Enabled")
            cell.contentConfiguration = content
            cell.accessoryView = enabledSwitch
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
            return cell
        }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        let field: UIView
        switch row {
        case .name: field = nameField
        case .url: field = urlField
        case .note: field = noteField
        case .headers: field = headersView
        case .enabled: field = enabledSwitch
        }
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: row == .headers ? 120 : 44),
        ])
        return cell
    }

    private func recordFromFields() throws -> MCPServerRecord {
        var headers: [String: String] = [:]
        for line in headersView.text.components(separatedBy: .newlines) where !line.isEmpty {
            guard let separator = line.firstIndex(of: ":") else { throw MCPStoreError.invalidHeader }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, headers[key] == nil else { throw MCPStoreError.invalidHeader }
            headers[key] = value
        }
        let connection = try MCPConnection(
            name: (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            url: (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            headers: headers, note: noteField.text
        )
        return MCPServerRecord(id: original?.id ?? UUID().uuidString.lowercased(),
                               connection: connection, enabled: enabledSwitch.isOn)
    }

    private func save() {
        do {
            let record = try recordFromFields()
            var next = try store.read()
            if let index = next.servers.items.firstIndex(where: { $0.id == record.id }) {
                next.servers.items[index] = record
            } else {
                next.servers.items.append(record)
            }
            try store.save(next)
            navigationController?.popViewController(animated: true)
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
        }
    }

    private func currentJSON() -> String? {
        do { return try store.exportJSON([recordFromFields()]) }
        catch { presentNotice(title: "Invalid Configuration", message: error.readableMessage); return nil }
    }

    private func copyCurrentJSON() {
        guard let text = currentJSON() else { return }
        presentConfirmation(
            title: "Copy MCP Configuration?",
            message: "The exported JSON includes custom request headers, which may hold access tokens. Keep the copied text safe.",
            confirmTitle: "Copy",
        ) { UIPasteboard.general.string = text }
    }

    private func shareCurrentJSON() {
        guard let text = currentJSON() else { return }
        presentConfirmation(
            title: "Share MCP Configuration?",
            message: "The exported JSON includes custom request headers, which may hold access tokens. Share it only with someone you trust.",
            confirmTitle: "Continue",
        ) { [weak self] in
            guard let self else { return }
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("mcp-server-\(UUID().uuidString).json")
            do {
                try Data(text.utf8).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                let sheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
                sheet.completionWithItemsHandler = { _, _, _, _ in
                    try? FileManager.default.removeItem(at: file)
                }
                if let popover = sheet.popoverPresentationController {
                    popover.barButtonItem = navigationItem.rightBarButtonItems?.last
                }
                present(sheet, animated: true)
            } catch {
                try? FileManager.default.removeItem(at: file)
                presentNotice(title: "Error", message: error.readableMessage)
            }
        }
    }
}
