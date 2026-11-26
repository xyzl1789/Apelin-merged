import ApelinProtocol
import UIKit

/// The editable part of an API-key sign-in. The parent owns the sign-in
/// task; this native grouped form owns only the user's unsent field values.
final class ProviderKeyFormController: TableController {
    var onSubmit: (([AgentSignInField: String]) -> Void)?
    var onSwitchMethod: ((AgentSignInMethod) -> Void)?

    @objc dynamic var isSubmitting = false {
        didSet {
            if isViewLoaded {
                updateSubmit()
            }
        }
    }

    private let keys: [SignInProgress.KeyField]
    private let alternatives: [AgentSignInMethod]
    private let initialValues: [String: String]
    /// 添加/编辑服务商时直接填备注：非空提交即保存到本机。
    private let noteProvider: AgentProvider?
    private var noteField: UITextField?
    private var noteCell: UITableViewCell?
    private var fields: [AgentSignInField: UITextField] = [:]
    private var cells: [AgentSignInField: UITableViewCell] = [:]
    /// Minis 的开关（`appendV1`、`azure`）用 UISwitch，值仍是 "true"/"false"，
    /// 与 worker 的校验和凭据 extras 完全一致。
    private var toggles: [AgentSignInField: UISwitch] = [:]
    /// The chosen value of a field whose worker entry carries `options`.
    private var selections: [AgentSignInField: String] = [:]
    private enum Row: Hashable {
        case field(AgentSignInField)
        case note
        case method(AgentSignInMethod)
    }

    private enum Section: Hashable {
        case field(AgentSignInField)
        case note
        case methods
    }

    private lazy var dataSource = TableDataSource<Section, Row, Row>(
        tableView: tableView,
        identifier: { $0 },
    ) { [weak self] _, _, row in
        self?.cell(for: row)
    }

    @objc dynamic lazy var submitItem = UIBarButtonItem(
        title: String(localized: "Fetch Models"),
        primaryAction: UIAction { [weak self] _ in self?.submit() },
    )

    init(
        keys: [SignInProgress.KeyField],
        alternatives: [AgentSignInMethod],
        initialValues: [String: String] = [:],
        noteProvider: AgentProvider? = nil,
    ) {
        self.keys = keys.filter { $0.field != .defaultModel }
        self.alternatives = alternatives
        self.initialValues = initialValues
        let provider = noteProvider?.kind == .openAICompatible ? noteProvider : nil
        self.noteProvider = provider
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(keys:alternatives:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.keyboardDismissMode = .interactive
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 52
        let textKeys = keys.filter { $0.options == nil && !$0.field.isBooleanToggle }
        for (index, key) in textKeys.enumerated() {
            let field = UITextField()
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
            field.spellCheckingType = .no
            field.smartDashesType = .no
            field.smartQuotesType = .no
            field.clearButtonMode = .whileEditing
            field.isSecureTextEntry = key.secure
            field.textContentType = key.field == .baseURL ? .URL : nil
            field.keyboardType = key.field == .baseURL ? .URL : .asciiCapable
            field.returnKeyType = index == textKeys.count - 1 ? .go : .next
            field.accessibilityLabel = key.field.title
            field.text = initialValues[key.field.rawValue] ?? key.defaultValue
            field.placeholder = key.placeholder
                ?? (key.required ? key.field.title : String(localized: "\(key.field.title) (Optional)"))
            field.addAction(UIAction { [weak self] _ in self?.updateSubmit() }, for: .editingChanged)
            field.addAction(UIAction { [weak self] _ in self?.advance(from: key.field) }, for: .editingDidEndOnExit)
            fields[key.field] = field
            cells[key.field] = cell(containing: field)
        }
        // Options are drawn as a menu row: the row itself is the field.
        for key in keys where key.options != nil {
            selections[key.field] = Self.initialSelection(key, initialValues: initialValues)
            cells[key.field] = selectionCell(for: key)
        }
        // Minis 的 `appendV1`/`azure` 是开关，不是文本输入框。
        for key in keys where key.field.isBooleanToggle {
            let initial = initialValues[key.field.rawValue] ?? key.defaultValue ?? "false"
            let toggle = UISwitch()
            toggle.isOn = initial == "true"
            toggle.accessibilityLabel = key.field.title
            toggle.addAction(UIAction { [weak self, weak toggle] _ in
                guard let toggle else { return }
                self?.selections[key.field] = toggle.isOn ? "true" : "false"
                self?.updateSubmit()
            }, for: .valueChanged)
            toggles[key.field] = toggle
            cells[key.field] = toggleCell(for: key, toggle: toggle)
        }
        submitItem.tintColor = .tintColor
        submitItem.accessibilityLabel = String(localized: "Fetch Models")
        updateSubmit()
        if let noteProvider {
            let field = UITextField()
            field.font = .preferredFont(forTextStyle: .body)
            field.adjustsFontForContentSizeCategory = true
            field.clearButtonMode = .whileEditing
            field.returnKeyType = .done
            field.placeholder = String(localized: "Note (Optional)")
            field.text = Preferences.ProviderNotes.note(for: noteProvider)
            field.accessibilityLabel = String(localized: "Provider Note")
            field.addAction(UIAction { [weak self] _ in self?.noteField?.resignFirstResponder() }, for: .editingDidEndOnExit)
            noteField = field
            noteCell = cell(containing: field)
        }

        dataSource.headerTitle = { section in
            if case let .field(field) = section {
                return field.title
            }
            if section == .note {
                return String(localized: "Note")
            }
            return nil
        }
        dataSource.footerTitle = { section in
            guard section == .field(.azure) else { return nil }
            return String(localized: "Use Azure OpenAI authentication (api-key header). Paste the full Azure endpoint above in API Base, including the ?api-version=… query parameter. Both API formats are supported.")
        }
        var sections: [(Section, [Row])] = keys.map { (.field($0.field), [.field($0.field)]) }
        if noteProvider != nil {
            sections.append((.note, [.note]))
        }
        if !alternatives.isEmpty {
            sections.append((.methods, alternatives.map(Row.method)))
        }
        dataSource.update(sections)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !isSubmitting, let first = keys.first(where: {
            $0.options == nil && !$0.field.isBooleanToggle && fields[$0.field] != nil
        }) {
            fields[first.field]?.becomeFirstResponder()
        }
    }

    private static func initialSelection(
        _ key: SignInProgress.KeyField,
        initialValues: [String: String],
    ) -> String? {
        let options = key.options ?? []
        let saved = initialValues[key.field.rawValue] ?? key.defaultValue
        if let saved, options.contains(where: { $0.value == saved }) {
            return saved
        }
        return options.first?.value
    }

    @objc private dynamic func cell(containing input: UIView) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        input.translatesAutoresizingMaskIntoConstraints = false
        cell.contentView.addSubview(input)
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            input.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            input.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            input.topAnchor.constraint(equalTo: margins.topAnchor),
            input.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        return cell
    }

    /// A choice row is a titled menu button: VoiceOver reads its name and its
    /// current value, and the menu offers the exact values the worker accepts.
    private func selectionCell(for key: SignInProgress.KeyField) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        cell.isAccessibilityElement = false
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.contentHorizontalAlignment = .leading
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.showsMenuAsPrimaryAction = true
        button.accessibilityLabel = key.field.title
        cell.contentView.addSubview(button)
        button.menu = Self.menu(
            for: key,
            selected: selections[key.field],
            target: self,
            button: button,
        )
        let title = Self.title(for: key, selected: selections[key.field])
        button.setTitle(title, for: .normal)
        button.accessibilityValue = title
        let margins = cell.contentView.layoutMarginsGuide
        NSLayoutConstraint.activate([
            button.leadingAnchor.constraint(equalTo: margins.leadingAnchor),
            button.trailingAnchor.constraint(equalTo: margins.trailingAnchor),
            button.topAnchor.constraint(equalTo: margins.topAnchor),
            button.bottomAnchor.constraint(equalTo: margins.bottomAnchor),
            cell.contentView.heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        return cell
    }

    /// A titled switch row for Minis' boolean toggles (`appendV1`, `azure`).
    /// VoiceOver reads the label and UISwitch supplies its own on/off value.
    private func toggleCell(for key: SignInProgress.KeyField, toggle: UISwitch) -> UITableViewCell {
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        cell.selectionStyle = .none
        var content = cell.defaultContentConfiguration()
        content.text = key.field.title
        content.textProperties.color = .label
        cell.contentConfiguration = content
        cell.accessoryView = toggle
        return cell
    }

    private static func menu(
        for key: SignInProgress.KeyField,
        selected: String?,
        target: ProviderKeyFormController,
        button: UIButton?,
    ) -> UIMenu {
        UIMenu(children: (key.options ?? []).map { option in
            UIAction(title: title(for: option, field: key.field), state: selected == option.value ? .on : .off) { [weak target, weak button] _ in
                guard let target else { return }
                target.selections[key.field] = option.value
                let title = title(for: option, field: key.field)
                button?.setTitle(title, for: .normal)
                button?.accessibilityValue = title
                button?.menu = menu(for: key, selected: option.value, target: target, button: button)
                target.updateSubmit()
            }
        })
    }

    private static func title(
        for option: SignInProgress.KeyOption,
        field: AgentSignInField,
    ) -> String {
        guard field == .apiFormat, let format = AgentAPIFormat(rawValue: option.value) else {
            if field == .imageEndpointMode, let mode = AgentImageEndpointMode(rawValue: option.value) {
                return mode.localizedTitle
            }
            return option.title
        }
        return format.localizedTitle
    }

    private static func title(
        for key: SignInProgress.KeyField,
        selected: String?,
    ) -> String {
        guard let option = key.options?.first(where: { $0.value == selected }) else { return "" }
        return title(for: option, field: key.field)
    }

    private var values: [AgentSignInField: String] {
        // The model selector owns defaultModel; editing a key or endpoint
        // must preserve that saved field even though this form hides it.
        var result: [AgentSignInField: String] = [:]
        if let defaultModel = initialValues[AgentSignInField.defaultModel.rawValue] {
            result[.defaultModel] = defaultModel
        }
        return result
            .merging(fields.mapValues { $0.text ?? "" }) { _, edited in edited }
            .merging(selections) { _, chosen in chosen }
            .merging(toggles.mapValues { $0.isOn ? "true" : "false" }) { _, chosen in chosen }
    }

    private var isReady: Bool {
        keys.allSatisfy { key in
            if key.field.isBooleanToggle {
                return true // A switch always carries a valid true/false value.
            }
            if key.options != nil {
                return !key.required || !(selections[key.field] ?? "").isEmpty
            }
            return !key.required || !(fields[key.field]?.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    @objc private dynamic func updateSubmit() {
        submitItem.isEnabled = isReady && !isSubmitting
        fields.values.forEach { $0.isEnabled = !isSubmitting }
        toggles.values.forEach { $0.isEnabled = !isSubmitting }
        for cell in cells.values {
            for view in cell.contentView.subviews {
                (view as? UIButton)?.isEnabled = !isSubmitting
            }
        }
    }

    private func advance(from field: AgentSignInField) {
        guard let index = keys.firstIndex(where: { $0.field == field }) else {
            submit()
            return
        }
        if let next = keys.dropFirst(index + 1)
            .first(where: { $0.options == nil && !$0.field.isBooleanToggle }),
           let input = fields[next.field]
        {
            input.becomeFirstResponder()
        } else {
            submit()
        }
    }

    @objc private dynamic func submit() {
        guard isReady, !isSubmitting else { return }
        view.endEditing(true)
        // 表单里直接填的备注随提交保存到本机；左滑入口继续可用。
        if let noteProvider {
            Preferences.ProviderNotes.save(noteField?.text ?? "", for: noteProvider)
        }
        onSubmit?(values)
    }

    private func cell(for row: Row) -> UITableViewCell? {
        if row == .note {
            return noteCell
        }
        if case let .field(field) = row {
            return cells[field]
        }
        guard case let .method(method) = row else { return nil }
        let cell = UITableViewCell(style: .default, reuseIdentifier: nil)
        var content = cell.defaultContentConfiguration()
        content.text = method.switchTitle
        content.textProperties.color = .tintColor
        cell.contentConfiguration = content
        cell.accessibilityTraits.insert(.button)
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = dataSource.value(at: indexPath) else { return }
        switch row {
        case .note: noteField?.becomeFirstResponder()
        case let .field(field): fields[field]?.becomeFirstResponder()
        case let .method(method):
            if !isSubmitting {
                onSwitchMethod?(method)
            }
        }
    }
}
