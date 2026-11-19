import ApelinCore
import Then
import UIKit

/// Settings ▸ Agent ▸ Prompt Injection: the collection of personas the reader
/// keeps, the on/off switch and the one chosen manually. An automatic persona
/// whose model pattern matches wins over the manual one; the list marks which
/// is in force with the current model. Changes save as they are made — a
/// conversation already open reads the file at its next message.
final class PromptInjectionController: TableController {
    private enum Section: Hashable {
        case settings
        case persona(String)
        case empty
    }
    private enum Row: Equatable {
        case enabled
        case active(name: String)
        // 名字、置顶、副标题都进 Row：改名后 Equatable 检测到变化，列表
        // 才会重配这一行，否则只按 id 比较会被当成没变，名字不刷新。
        case persona(id: String, name: String, pinned: Bool, detail: String, inUse: Bool)
        case empty
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case .enabled: "enabled"
            case .active: "active"
            case let .persona(id, _, _, _, _): "persona:" + id
            case .empty: "empty"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let switchView = UISwitch()
    private var snapshot = PersonaSnapshot()

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Prompt Injection")
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.add() },
        ).then { $0.accessibilityLabel = String(localized: "Add Persona") }
        switchView.addAction(
            UIAction { [weak self] _ in self?.switchChanged() },
            for: .valueChanged,
        )
        switchView.accessibilityLabel = String(localized: "Enabled")
        dataSource.allowsEditing = true
        dataSource.headerTitle = { section in
            switch section {
            case .settings: nil
            case .persona: nil
            case .empty: nil
            }
        }
        dataSource.footerTitle = { [weak self] section in
            switch section {
            case .settings:
                return String(localized: "A persona's text is prepended to every conversation. An automatic persona matching the model takes over from the manual one.")
            case let .persona(id):
                // 每张人设卡片下方写明它的用处，自动/手动与置顶各说明一次。
                guard let persona = self?.snapshot.personas.first(where: { $0.id == id }) else { return nil }
                var lines: [String] = []
                if persona.matchMode == .automatic {
                    lines.append(String(localized: "自动：模型命中匹配规则时自动生效，压过手动；多个命中取优先级最高的。"))
                } else {
                    lines.append(String(localized: "手动：由上方「生效中」选定，没有自动人设命中时生效。"))
                }
                if persona.pinned {
                    lines.append(String(localized: "置顶只让人设在列表中排在最前，不影响注入效果。"))
                }
                return lines.joined(separator: "\n")
            case .empty:
                return String(localized: "Tap “+” to add a persona.")
            }
        }
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    private func load() {
        snapshot = Preferences.PromptInjection.snapshot
        switchView.isOn = snapshot.enabled
        let sorted = snapshot.personas.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        var sections: [(Section, [Row])] = [
            (.settings, [.enabled, .active(name: snapshot.personas.first { $0.id == snapshot.activeID }?.name ?? String(localized: "None"))]),
        ]
        if sorted.isEmpty {
            sections.append((.empty, [.empty]))
        } else {
            // 每个人设单独一节：设置表格里一节就是一张独立卡片。
            for persona in sorted {
                let detail = persona.matchMode == .automatic
                    ? String(localized: "Automatic") + " · " + (persona.modelPatterns.joined(separator: ", "))
                    : String(localized: "Manual")
                sections.append((
                    .persona(persona.id),
                    [.persona(
                        id: persona.id,
                        name: persona.name,
                        pinned: persona.pinned,
                        detail: detail,
                        inUse: snapshot.activeID == persona.id,
                    )],
                ))
            }
        }
        dataSource.update(sections, reconfigure: true)
    }

    private func save(_ next: PersonaSnapshot) {
        do {
            try Preferences.PromptInjection.save(next)
            snapshot = next
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
        }
        load()
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row {
        case .enabled:
            let cell = tableView.dequeueReusableCell(withIdentifier: "switch")
                ?? UITableViewCell(style: .default, reuseIdentifier: "switch")
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Enabled")
            cell.contentConfiguration = content
            cell.accessoryView = switchView
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
            return cell
        case let .active(name):
            let cell = tableView.dequeueReusableCell(withIdentifier: "active")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "active")
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Active")
            content.secondaryText = name
            content.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        case let .persona(_, name, pinned, detail, inUse):
            let cell = tableView.dequeueReusableCell(withIdentifier: "persona")
                ?? UITableViewCell(style: .subtitle, reuseIdentifier: "persona")
            var content = UIListContentConfiguration.explanatoryCell()
            content.text = name + (pinned ? " 📌" : "")
            content.textProperties.numberOfLines = 1
            content.secondaryText = inUse ? detail + " · " + String(localized: "In Use") : detail
            content.secondaryTextProperties.numberOfLines = 2
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            cell.isAccessibilityElement = false
            return cell
        case .empty:
            let cell = tableView.dequeueReusableCell(withIdentifier: "empty")
                ?? UITableViewCell(style: .default, reuseIdentifier: "empty")
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "No personas yet")
            content.textProperties.color = .secondaryLabel
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
    }

    @objc private dynamic func switchChanged() {
        var next = snapshot
        next.enabled = switchView.isOn
        save(next)
    }

    private func persona(at indexPath: IndexPath) -> Persona? {
        guard case let .persona(id, _, _, _, _)? = dataSource.value(at: indexPath) else { return nil }
        return snapshot.personas.first { $0.id == id }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath) {
        case .active, .persona: true
        default: false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath) {
        case .active:
            pickActive()
        case .persona:
            guard let persona = persona(at: indexPath) else { return }
            navigationController?.pushViewController(
                PersonaEditorController(persona: persona, snapshot: snapshot),
                animated: true,
            )
        default:
            break
        }
    }

    private func pickActive() {
        let manual = snapshot.personas.filter { $0.matchMode == .manual }
        guard !manual.isEmpty else {
            presentNotice(
                title: "No Manual Persona",
                message: "Add a persona whose matching is Manual first.",
            )
            return
        }
        let sheet = UIAlertController(title: String(localized: "Active"), message: nil, preferredStyle: .actionSheet)
        for persona in manual {
            let title = persona.name + (snapshot.activeID == persona.id ? " ✓" : "")
            sheet.addAction(UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                var next = snapshot
                next.activeID = persona.id
                save(next)
            })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    @objc private dynamic func add() {
        let persona = Persona(name: "", body: "")
        navigationController?.pushViewController(
            PersonaEditorController(persona: persona, snapshot: snapshot, isNew: true),
            animated: true,
        )
    }

    override func tableView(_: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        persona(at: indexPath) == nil ? .none : .delete
    }

    override func tableView(
        _: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath,
    ) -> UISwipeActionsConfiguration? {
        guard let persona = persona(at: indexPath) else { return nil }
        let remove = UIContextualAction(style: .destructive, title: String(localized: "Remove")) {
            [weak self] _, _, completion in
            completion(true)
            self?.confirmRemoval(persona)
        }
        remove.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [remove])
    }

    private func confirmRemoval(_ persona: Persona) {
        presentConfirmation(
            title: "Remove \(persona.name)?",
            message: "This persona and its injected text are removed.",
            confirmTitle: "Remove",
            destructive: true,
        ) { [weak self] in
            guard let self else { return }
            var next = snapshot
            next.personas.removeAll { $0.id == persona.id }
            if next.activeID == persona.id { next.activeID = next.personas.first?.id }
            save(next)
        }
    }
}
