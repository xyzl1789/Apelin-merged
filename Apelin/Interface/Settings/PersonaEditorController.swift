import ApelinCore
import Then
import UIKit

/// One persona's detail page. Every field saves as it changes: the next chat
/// reads the file directly, and a chat already open reads it at its next
/// message. There is no Save button to forget to press.
final class PersonaEditorController: TableController, UITextViewDelegate {
    private enum Row: Equatable {
        case name
        case mode
        case enabled
        case patterns
        case priority
        case pinned
        case body
    }

    private lazy var dataSource = TableDataSource<Int, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case .name: "name"
            case .mode: "mode"
            case .enabled: "enabled"
            case .patterns: "patterns"
            case .priority: "priority"
            case .pinned: "pinned"
            case .body: "body"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private var persona: Persona
    private var snapshot: PersonaSnapshot
    private let isNew: Bool

    private let nameField = UITextField()
    private let patternsField = UITextField()
    private let priorityField = UITextField()
    private let modeControl = UISegmentedControl(items: [
        String(localized: "Manual"), String(localized: "Automatic"),
    ])
    private let enabledSwitch = UISwitch()
    private let pinnedSwitch = UISwitch()
    private let textView = UITextView()
    private let placeholder = UILabel()
    private lazy var bodyCell = fieldCell(textView, minimumHeight: 220)

    init(persona: Persona, snapshot: PersonaSnapshot, isNew: Bool = false) {
        self.persona = persona
        self.snapshot = snapshot
        self.isNew = isNew
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? String(localized: "New Persona") : persona.name
        navigationItem.backButtonDisplayMode = .minimal
        tableView.keyboardDismissMode = .interactive

        nameField.text = persona.name
        nameField.placeholder = String(localized: "Name")
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.accessibilityLabel = String(localized: "Name")
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)

        patternsField.text = persona.modelPatterns.joined(separator: ", ")
        patternsField.placeholder = String(localized: "e.g. gpt, claude")
        patternsField.font = .preferredFont(forTextStyle: .body)
        patternsField.adjustsFontForContentSizeCategory = true
        patternsField.accessibilityLabel = String(localized: "Model Patterns")
        patternsField.addTarget(self, action: #selector(patternsChanged), for: .editingChanged)

        priorityField.text = String(persona.priority)
        priorityField.placeholder = String(localized: "Priority")
        priorityField.font = .preferredFont(forTextStyle: .body)
        priorityField.adjustsFontForContentSizeCategory = true
        priorityField.keyboardType = .numberPad
        priorityField.accessibilityLabel = String(localized: "Priority")
        priorityField.addTarget(self, action: #selector(priorityChanged), for: .editingChanged)

        modeControl.selectedSegmentIndex = persona.matchMode == .automatic ? 1 : 0
        modeControl.accessibilityLabel = String(localized: "Matching")
        modeControl.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)

        enabledSwitch.isOn = snapshot.enabled
        enabledSwitch.accessibilityLabel = String(localized: "Enabled")
        enabledSwitch.addAction(UIAction { [weak self] _ in self?.enabledChanged() }, for: .valueChanged)

        pinnedSwitch.isOn = persona.pinned
        pinnedSwitch.accessibilityLabel = String(localized: "Pin")
        pinnedSwitch.addAction(UIAction { [weak self] _ in self?.pinnedChanged() }, for: .valueChanged)

        textView.text = persona.body
        textView.accessibilityLabel = String(localized: "Injected Prompt")
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .clear
        textView.isScrollEnabled = false
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.delegate = self
        placeholder.text = String(localized: "What should every conversation be told first?")
        placeholder.font = .preferredFont(forTextStyle: .body)
        placeholder.adjustsFontForContentSizeCategory = true
        placeholder.textColor = .placeholderText
        placeholder.numberOfLines = 0
        placeholder.isAccessibilityElement = false
        placeholder.isUserInteractionEnabled = false
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        textView.addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: textView.frameLayoutGuide.leadingAnchor),
            placeholder.trailingAnchor.constraint(equalTo: textView.frameLayoutGuide.trailingAnchor),
            placeholder.topAnchor.constraint(equalTo: textView.frameLayoutGuide.topAnchor),
        ])
        updatePlaceholder()

        dataSource.headerTitle = { _ in nil }
        dataSource.footerTitle = { _ in
            String(localized: "This text is prepended to the system prompt. Automatic personas take over for matching models; higher priority wins.")
        }
        refresh()
    }

    private func refresh() {
        var rows: [Row] = [.name, .mode]
        if persona.matchMode == .automatic { rows.append(contentsOf: [.patterns, .priority]) }
        rows.append(contentsOf: [.pinned, .enabled, .body])
        dataSource.update([(0, rows)], reconfigure: true)
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row {
        case .name:
            return fieldCell(nameField, minimumHeight: 44)
        case .patterns:
            return fieldCell(patternsField, minimumHeight: 44)
        case .priority:
            return fieldCell(priorityField, minimumHeight: 44)
        case .mode:
            let cell = tableView.dequeueReusableCell(withIdentifier: "mode") ?? UITableViewCell()
            modeControl.translatesAutoresizingMaskIntoConstraints = false
            cell.contentView.addSubview(modeControl)
            NSLayoutConstraint.activate([
                modeControl.leadingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.leadingAnchor),
                modeControl.trailingAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.trailingAnchor),
                modeControl.topAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.topAnchor),
                modeControl.bottomAnchor.constraint(equalTo: cell.contentView.layoutMarginsGuide.bottomAnchor),
            ])
            cell.selectionStyle = .none
            cell.isAccessibilityElement = false
            return cell
        case .enabled:
            return switchCell(enabledSwitch, title: String(localized: "Enabled"), identifier: "enabled")
        case .pinned:
            return switchCell(pinnedSwitch, title: String(localized: "Pin"), identifier: "pinned")
        case .body:
            return bodyCell
        }
    }

    private func switchCell(_ control: UISwitch, title: String, identifier: String) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
            ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
        var content = UIListContentConfiguration.valueCell()
        content.text = title
        cell.contentConfiguration = content
        cell.accessoryView = control
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        return cell
    }

    private func fieldCell(_ field: UIView, minimumHeight: CGFloat) -> UITableViewCell {
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

    private func commit() {
        var next = snapshot
        if let index = next.personas.firstIndex(where: { $0.id == persona.id }) {
            next.personas[index] = persona
        } else {
            next.personas.append(persona)
        }
        do {
            try Preferences.PromptInjection.save(next)
            snapshot = next
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
        }
    }

    @objc private dynamic func nameChanged() {
        persona.name = nameField.text ?? ""
        title = persona.name
        commit()
    }

    @objc private dynamic func modeChanged() {
        persona.matchMode = modeControl.selectedSegmentIndex == 1 ? .automatic : .manual
        if persona.matchMode == .manual, snapshot.activeID == nil { snapshot.activeID = persona.id }
        commit()
        refresh()
    }

    @objc private dynamic func patternsChanged() {
        persona.modelPatterns = (patternsField.text ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        commit()
    }

    @objc private dynamic func priorityChanged() {
        persona.priority = Int(priorityField.text ?? "") ?? 0
        commit()
    }

    @objc private dynamic func pinnedChanged() {
        persona.pinned = pinnedSwitch.isOn
        commit()
    }

    @objc private dynamic func enabledChanged() {
        snapshot.enabled = enabledSwitch.isOn
        commit()
    }

    @objc dynamic func textViewDidChange(_: UITextView) {
        persona.body = String(textView.text.prefix(Preferences.PromptInjection.maximumCharacters))
        commit()
        updatePlaceholder()
        tableView.beginUpdates()
        tableView.endUpdates()
    }

    @objc private dynamic func updatePlaceholder() {
        placeholder.isHidden = !textView.text.isEmpty
        textView.accessibilityHint = placeholder.isHidden ? nil : placeholder.text
    }
}
