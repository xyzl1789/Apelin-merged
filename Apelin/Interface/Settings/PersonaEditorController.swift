import ApelinCore
import Then
import UIKit

/// A persona's detail page, laid out after Dylix's editor: a vertical form
/// (name, mode, rules, pin), a byte counter, then a large body card. An
/// existing persona saves every field as it changes; a chat already open reads
/// the file at its next message. A new persona is kept only when 「保存」 is
/// tapped — going back discards it.
final class PersonaEditorController: UIViewController, UITextViewDelegate, UIAdaptivePresentationControllerDelegate {
    private var persona: Persona
    private var snapshot: PersonaSnapshot
    private let isNew: Bool

    private let nameField = UITextField()
    private let patternsField = UITextField()
    private let priorityField = UITextField()
    private let modeControl = UISegmentedControl(items: [
        String(localized: "Manual"), String(localized: "Automatic"),
    ])
    private let modeHint = UILabel()
    private let pinnedSwitch = UISwitch()
    private let enabledSwitch = UISwitch()
    private let counter = UILabel()
    private let textView = UITextView()
    private let rulesStack = UIStackView()
    private let scroll = UIScrollView()
    private var original: Persona
    private var originalEnabled = false

    init(persona: Persona, snapshot: PersonaSnapshot, isNew: Bool = false) {
        self.persona = persona
        self.snapshot = snapshot
        self.isNew = isNew
        original = persona
        originalEnabled = snapshot.enabled
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init()") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = isNew ? String(localized: "New Persona") : persona.name
        view.backgroundColor = .systemGroupedBackground
        view.tintColor = PromptInjectionController.accent
        navigationItem.backButtonDisplayMode = .minimal

        nameField.text = persona.name
        nameField.placeholder = String(localized: "Name")
        nameField.font = .preferredFont(forTextStyle: .body)
        nameField.adjustsFontForContentSizeCategory = true
        nameField.borderStyle = .roundedRect
        nameField.accessibilityLabel = String(localized: "Name")
        nameField.addTarget(self, action: #selector(nameChanged), for: .editingChanged)

        patternsField.text = persona.modelPatterns.joined(separator: ", ")
        patternsField.placeholder = String(localized: "e.g. gpt, claude")
        patternsField.font = .preferredFont(forTextStyle: .body)
        patternsField.adjustsFontForContentSizeCategory = true
        patternsField.borderStyle = .roundedRect
        patternsField.accessibilityLabel = String(localized: "Model Patterns")
        patternsField.addTarget(self, action: #selector(patternsChanged), for: .editingChanged)

        priorityField.text = String(persona.priority)
        priorityField.placeholder = String(localized: "Priority")
        priorityField.font = .preferredFont(forTextStyle: .body)
        priorityField.adjustsFontForContentSizeCategory = true
        priorityField.keyboardType = .numberPad
        priorityField.borderStyle = .roundedRect
        priorityField.accessibilityLabel = String(localized: "Priority")
        priorityField.addTarget(self, action: #selector(priorityChanged), for: .editingChanged)

        modeControl.selectedSegmentIndex = persona.matchMode == .automatic ? 1 : 0
        modeControl.accessibilityLabel = String(localized: "Matching")
        modeControl.addAction(UIAction { [weak self] _ in self?.modeChanged() }, for: .valueChanged)
        modeHint.font = .preferredFont(forTextStyle: .footnote)
        modeHint.adjustsFontForContentSizeCategory = true
        modeHint.textColor = .secondaryLabel
        modeHint.numberOfLines = 0

        pinnedSwitch.isOn = persona.pinned
        pinnedSwitch.accessibilityLabel = String(localized: "Pin")
        pinnedSwitch.addAction(UIAction { [weak self] _ in self?.pinnedChanged() }, for: .valueChanged)

        enabledSwitch.isOn = snapshot.enabled
        enabledSwitch.accessibilityLabel = String(localized: "Enable Injection")
        enabledSwitch.addAction(UIAction { [weak self] _ in self?.enabledChanged() }, for: .valueChanged)

        textView.text = persona.body
        textView.accessibilityLabel = String(localized: "Injected Prompt")
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        textView.delegate = self
        textView.autocorrectionType = .no
        textView.translatesAutoresizingMaskIntoConstraints = false

        configureRules()
        configureStack()
        updateHint()
        updateCounter()

        if isNew {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: String(localized: "Cancel"),
                style: .plain,
                target: self,
                action: #selector(cancelNew),
            )
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                title: String(localized: "Save"),
                style: .done,
                target: self,
                action: #selector(saveNew),
            ).then { $0.accessibilityLabel = String(localized: "Save") }
            navigationItem.rightBarButtonItem?.accessibilityIdentifier = "persona-save"
        }
    }

    private func configureRules() {
        rulesStack.axis = .vertical
        rulesStack.spacing = 12
        rulesStack.addArrangedSubview(Self.label(String(localized: "Model Patterns"), style: .subheadline))
        rulesStack.addArrangedSubview(patternsField)
        rulesStack.addArrangedSubview(Self.label(String(localized: "Priority"), style: .subheadline))
        rulesStack.addArrangedSubview(priorityField)
        patternsField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        priorityField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
    }

    private func configureStack() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        let nameTitle = Self.label(String(localized: "Name"), style: .subheadline)
        let modeTitle = Self.label(String(localized: "Matching"), style: .subheadline)
        let bodyTitle = Self.label(String(localized: "Injected Prompt"), style: .subheadline)
        let note = Self.label(
            String(localized: "正文会在本配置生效时置于每次对话的系统提示最前；手动与自动的区别见下方说明，修改从下一条消息起生效。"),
            style: .footnote, color: .secondaryLabel,
        )

        let pinRow = Self.switchRow(title: String(localized: "Pin to top"), control: pinnedSwitch)
        let enableRow = Self.switchRow(title: String(localized: "Enable Injection"), control: enabledSwitch)

        let stack = UIStackView(arrangedSubviews: [
            nameTitle, nameField, modeTitle, modeControl, modeHint,
            rulesStack, pinRow, enableRow, bodyTitle, counter, note, textView,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        nameField.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        modeControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 36).isActive = true
        textView.heightAnchor.constraint(greaterThanOrEqualToConstant: 240).isActive = true

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -16),
            stack.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor, constant: -32),
        ])
    }

    private static func label(_ text: String, style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private static func switchRow(title: String, control: UISwitch) -> UIView {
        let row = UIView()
        let label = Self.label(title, style: .body)
        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private var isDirty: Bool {
        guard persona == original, snapshot.enabled == originalEnabled else { return false }
        let name = nameField.text ?? ""
        let patterns = (patternsField.text ?? "")
            .split(separator: ",")
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return name != original.name
            || textView.text != original.body
            || patterns != original.modelPatterns
            || modeControl.selectedSegmentIndex != (original.matchMode == .automatic ? 1 : 0)
            || pinnedSwitch.isOn != original.pinned
    }

    private func updateHint() {
        let automatic = modeControl.selectedSegmentIndex == 1
        modeHint.text = automatic
            ? String(localized: "自动：模型命中匹配规则时生效，压过手动；多个命中取优先级最高的。")
            : String(localized: "手动：由配置库右侧的圆形按钮选定，没有自动配置命中时生效。")
        rulesStack.isHidden = !automatic
    }

    private func updateCounter() {
        counter.text = String(localized: "正文 · \(textView.text.utf8.count) B（UTF-8）")
        counter.accessibilityIdentifier = "persona-byte-count"
    }

    @discardableResult
    private func commit() -> Bool {
        var next = snapshot
        if let index = next.personas.firstIndex(where: { $0.id == persona.id }) {
            next.personas[index] = persona
        } else {
            next.personas.append(persona)
        }
        do {
            try Preferences.PromptInjection.save(next)
            snapshot = next
            original = persona
            originalEnabled = next.enabled
            return true
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
            return false
        }
    }

    /// An existing persona saves as it changes; a new one stays in this editor
    /// until 「保存」 is tapped.
    private func change(_ apply: () -> Void) {
        apply()
        if !isNew { commit() }
    }

    @objc private dynamic func nameChanged() {
        change { [weak self] in
            guard let self else { return }
            persona.name = nameField.text ?? ""
            if !isNew { title = persona.name }
        }
    }

    @objc private dynamic func modeChanged() {
        change { [weak self] in
            guard let self else { return }
            persona.matchMode = modeControl.selectedSegmentIndex == 1 ? .automatic : .manual
            if !isNew, persona.matchMode == .manual, snapshot.activeID == nil {
                snapshot.activeID = persona.id
            }
            updateHint()
        }
    }

    @objc private dynamic func patternsChanged() {
        change { [weak self] in
            guard let self else { return }
            persona.modelPatterns = (patternsField.text ?? "")
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    @objc private dynamic func priorityChanged() {
        change { [weak self] in
            guard let self else { return }
            persona.priority = Int(priorityField.text ?? "") ?? 0
        }
    }

    @objc private dynamic func pinnedChanged() {
        change { [weak self] in
            guard let self else { return }
            persona.pinned = pinnedSwitch.isOn
        }
    }

    @objc private dynamic func enabledChanged() {
        change { [weak self] in
            guard let self else { return }
            snapshot.enabled = enabledSwitch.isOn
        }
    }

    @objc dynamic func textViewDidChange(_: UITextView) {
        change { [weak self] in
            guard let self else { return }
            persona.body = String(textView.text.prefix(Preferences.PromptInjection.maximumCharacters))
            updateCounter()
        }
    }

    @objc private dynamic func saveNew() {
        persona.name = persona.name.trimmingCharacters(in: .whitespacesAndNewlines)
        nameField.text = persona.name
        guard !persona.name.isEmpty else {
            presentNotice(title: "Error", message: String(localized: "请先填写名称"))
            nameField.becomeFirstResponder()
            return
        }
        if persona.matchMode == .manual, snapshot.activeID == nil {
            snapshot.activeID = persona.id
        }
        guard commit() else { return }
        navigationController?.popViewController(animated: true)
    }

    @objc private dynamic func cancelNew() {
        guard isDirty else { navigationController?.popViewController(animated: true); return }
        presentConfirmation(
            title: "Discard Changes?",
            message: "This configuration has not been saved yet.",
            cancelTitle: "Keep Editing",
            confirmTitle: "Discard",
            destructive: true,
        ) { [weak self] in
            self?.navigationController?.popViewController(animated: true)
        }
    }

    func presentationControllerShouldDismiss(_: UIPresentationController) -> Bool { !isDirty }

    func presentationControllerDidAttemptToDismiss(_: UIPresentationController) { cancelNew() }
}
