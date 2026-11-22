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

/// Each field has a section of its own, laid out after Minis: the header names
/// what to fill in, the row holds it, the footer explains the rule. The fields
/// are staged here; Save validates the entire record and persists it. Back
/// discards edits, so an incomplete URL never disables a server.
final class MCPServerEditorController: TableController, UITextViewDelegate {
    private enum Row: Equatable {
        case name
        case url
        case header(String)
        case addHeader
        case note
        case enabled
    }

    /// One header being typed, with the two fields that hold it and the row
    /// that shows them: a reload puts the same text back in the same row, and
    /// moving the fields between cells never costs the keyboard its focus.
    private final class HeaderDraft {
        let id = UUID().uuidString
        let name = UITextField()
        let value = UITextField()
        var cell: UITableViewCell?
    }

    private lazy var dataSource = TableDataSource<Int, String, Row>(
        tableView: tableView, identifier: { Self.identifier(of: $0) }
    ) { [weak self] table, _, row in self?.cell(in: table, row: row) }
    private let store = MCPServerStore(root: DataFolder.app.root)
    private let original: MCPServerRecord?
    private let nameField = UITextField()
    private let urlField = UITextField()
    private let noteView = UITextView()
    private let enabledSwitch = UISwitch()
    private var headerDrafts: [HeaderDraft] = []
    /// Each row keeps its cell: a change elsewhere in the list re-asks for
    /// them, and a field handed to a new cell would lose the keyboard.
    private lazy var nameCell = fieldCell(nameField)
    private lazy var urlCell = fieldCell(urlField)
    private lazy var noteCell = fieldCell(noteView, minimumHeight: 132)
    private lazy var addHeaderRow = addHeaderCell()
    private lazy var enabledCell = switchCell()

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
        tableView.rowHeight = UITableView.automaticDimension
        configure(nameField, label: String(localized: "Server Name"), value: original?.connection.name)
        configure(urlField, label: String(localized: "Server URL"), value: original?.connection.url)
        urlField.keyboardType = .URL
        urlField.autocapitalizationType = .none
        urlField.autocorrectionType = .no
        noteView.text = original?.connection.note
        noteView.accessibilityLabel = String(localized: "Note (Shown to Agent)")
        noteView.font = .preferredFont(forTextStyle: .body)
        noteView.adjustsFontForContentSizeCategory = true
        noteView.autocapitalizationType = .sentences
        noteView.backgroundColor = .clear
        noteView.isScrollEnabled = false
        noteView.textContainerInset = .zero
        noteView.textContainer.lineFragmentPadding = 0
        noteView.delegate = self
        enabledSwitch.isOn = original?.enabled ?? true
        enabledSwitch.accessibilityLabel = String(localized: "Enabled")
        enabledSwitch.addAction(UIAction { [weak self] _ in self?.enabledChanged() }, for: .valueChanged)
        for (name, value) in (original?.connection.headers ?? [:]).sorted(by: { $0.key < $1.key }) {
            headerDrafts.append(headerDraft(named: name, value: value))
        }
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case 1: String(localized: "Server Name")
            case 2: String(localized: "Server URL")
            case 3: String(localized: "HTTP Headers")
            case 4: String(localized: "Note (Shown to Agent)")
            default: nil
            }
        }
        dataSource.footerTitle = { [weak self] section in
            switch section {
            case 0:
                // A new server is only written by Save, so the switch has
                // nothing to act on yet: say what Back does instead.
                self?.original == nil
                    ? String(localized: "Go back to discard unsaved changes. New settings apply when the conversation is opened again.")
                    : String(localized: "This switch takes effect at once. Each tool still needs approval according to your permission mode.")
            case 1: String(localized: "Server names use letters, digits, _ and - only, up to 64 characters.")
            case 2: String(localized: "iOS supports HTTP Streamable only for now. Enter the server's full MCP HTTP endpoint.")
            case 3: String(localized: "One header per row: the name on the left, the value on the right. Tokens are kept in this app's data folder.")
            default: String(localized: "This note is handed to the agent as the server's description, so it knows when to use these tools.")
            }
        }
        updateRows()
    }

    /// The switch is not one of the fields Save collects: it decides whether
    /// this server is handed to a new conversation at all, so it is written as
    /// it is turned, the way the list's own Enable and Disable menu items are.
    /// A server that does not exist yet has nothing to write; Save creates it.
    private func enabledChanged() {
        guard let original else { return }
        do {
            var next = try store.read()
            guard let index = next.servers.items.firstIndex(where: { $0.id == original.id }) else { return }
            next.servers.items[index].enabled = enabledSwitch.isOn
            try store.save(next)
        } catch {
            enabledSwitch.setOn(original.enabled, animated: true)
            presentNotice(title: "Error", message: error.readableMessage)
        }
    }

    private static func identifier(of row: Row) -> String {
        switch row {
        case .name: "name"
        case .url: "url"
        case let .header(id): "header-\(id)"
        case .addHeader: "add-header"
        case .note: "note"
        case .enabled: "enabled"
        }
    }

    private func updateRows(focusing draft: HeaderDraft? = nil) {
        let rows: [(Int, [Row])] = [
            (0, [.enabled]),
            (1, [.name]),
            (2, [.url]),
            (3, headerDrafts.map { Row.header($0.id) } + [.addHeader]),
            (4, [.note]),
        ]
        guard let draft else {
            dataSource.update(rows)
            return
        }
        // the new row exists only once the change is in, so the keyboard waits for it
        dataSource.update(rows, completion: { _ = draft.name.becomeFirstResponder() })
    }

    private func configure(_ field: UITextField, label: String, value: String?) {
        field.text = value
        field.placeholder = label
        field.accessibilityLabel = label
        field.font = .preferredFont(forTextStyle: .body)
        field.adjustsFontForContentSizeCategory = true
        field.clearButtonMode = .whileEditing
    }

    private func headerDraft(named name: String = "", value: String = "") -> HeaderDraft {
        let draft = HeaderDraft()
        configure(draft.name, label: String(localized: "Header Name"), value: name)
        configure(draft.value, label: String(localized: "Header Value"), value: value)
        for field in [draft.name, draft.value] {
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
        }
        return draft
    }

    private func cell(in table: UITableView, row: Row) -> UITableViewCell {
        switch row {
        case .name:
            return nameCell
        case .url:
            return urlCell
        case .note:
            return noteCell
        case let .header(id):
            guard let draft = headerDrafts.first(where: { $0.id == id }) else { return UITableViewCell() }
            return headerCell(draft)
        case .addHeader:
            return addHeaderRow
        case .enabled:
            return enabledCell
        }
    }

    /// A field filling the row's margins; the field is the element, not the row.
    private func fieldCell(_ field: UIView, minimumHeight: CGFloat = 44) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        field.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(field)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            field.topAnchor.constraint(equalTo: margins.topAnchor),
            field.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumHeight),
        ])
        return cell
    }

    /// One header: its name on the left and its value on the right, each its
    /// own stop for VoiceOver. The row is made once per header and handed back
    /// on every reload, so a swipe or an added row never drops the keyboard.
    private func headerCell(_ draft: HeaderDraft) -> UITableViewCell {
        if let cell = draft.cell { return cell }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        let row = UIStackView(arrangedSubviews: [draft.name, draft.value])
        row.axis = .horizontal
        row.spacing = 12
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(row)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            row.topAnchor.constraint(equalTo: margins.topAnchor),
            row.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            draft.name.widthAnchor.constraint(equalTo: draft.value.widthAnchor),
        ])
        draft.cell = cell
        return cell
    }

    private func addHeaderCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = UIListContentConfiguration.cell()
        content.text = String(localized: "Add Header")
        content.textProperties.color = .tintColor
        content.image = UIImage(systemName: "plus.circle")
        content.imageProperties.tintColor = .tintColor
        cell.contentConfiguration = content
        cell.accessibilityTraits.insert(.button)
        return cell
    }

    /// A row that names its switch: the switch speaks its own on and off, and
    /// the row's name is what tells it apart from the others.
    private func switchCell() -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = String(localized: "Enabled")
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        cell.accessoryView = enabledSwitch
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard dataSource.value(at: indexPath) == .addHeader else { return }
        let draft = headerDraft()
        headerDrafts.append(draft)
        updateRows(focusing: draft)
    }

    /// Only a header row can be swiped away; the fields keep their text.
    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        guard let row = dataSource.value(at: indexPath), case .header = row else { return .none }
        return .delete
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        guard editingStyle == .delete, case let .header(id)? = dataSource.value(at: indexPath) else { return }
        headerDrafts.removeAll { $0.id == id }
        updateRows()
    }

    /// The note is a text view that grows with its text: the row follows it
    /// rather than scrolling a few lines inside a fixed height.
    func textViewDidChange(_ textView: UITextView) {
        guard textView === noteView else { return }
        UIView.performWithoutAnimation {
            tableView.beginUpdates()
            tableView.endUpdates()
        }
    }

    private func recordFromFields() throws -> MCPServerRecord {
        var headers: [String: String] = [:]
        for draft in headerDrafts {
            let name = (draft.name.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let value = (draft.value.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // a row left empty is one the user did not fill in, not a mistake
            if name.isEmpty, value.isEmpty { continue }
            guard !name.isEmpty, headers[name] == nil else { throw MCPStoreError.invalidHeader }
            headers[name] = value
        }
        let connection = try MCPConnection(
            name: (nameField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            url: (urlField.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            headers: headers, note: noteView.text
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
