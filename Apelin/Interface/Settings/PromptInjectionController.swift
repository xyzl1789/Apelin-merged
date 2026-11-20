import ApelinCore
import Then
import UIKit

/// Settings ▸ Agent ▸ Prompt Injection. The page is laid out after Dylix's
/// persona workbench: a status card on top, a 「配置库」 section whose header
/// carries the item count, and one card per configuration. Tapping a card
/// opens its editor; the circular button on its right switches to manual and
/// selects it. Search, preview and management actions sit in the toolbar.
final class PromptInjectionController: TableController, UISearchResultsUpdating {
    private enum Section: Hashable { case status, library, empty }
    private enum Row: Equatable {
        // 状态文本进关联值：开关或匹配变化后，Equatable 检出差异，卡片才会重绘。
        case status(text: String)
        // Every visible value is part of the row: a rename or a selection
        // change must reconfigure the mounted card, an id-only value would not.
        case persona(
            id: String,
            name: String,
            mode: String,
            detail: String,
            info: String,
            selected: Bool,
            recommended: Bool,
        )
        case empty(query: Bool)
    }

    private lazy var dataSource = TableDataSource<Section, String, Row>(
        tableView: tableView,
        identifier: { row in
            switch row {
            case .status: "status"
            case let .persona(id, _, _, _, _, _, _): "persona:" + id
            case .empty: "empty"
            }
        },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private let switchView = UISwitch()
    private let search = UISearchController(searchResultsController: nil)
    private var snapshot = PersonaSnapshot()
    private var items: [Persona] = []
    private var query = ""

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
        view.tintColor = Self.accent

        let add = UIBarButtonItem(
            systemItem: .add,
            primaryAction: UIAction { [weak self] _ in self?.add() },
        )
        add.accessibilityLabel = String(localized: "Add Persona")
        let more = UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: [
                UIAction(
                    title: String(localized: "Preview Injection"),
                    image: UIImage(systemName: "doc.text.magnifyingglass"),
                ) { [weak self] _ in self?.preview() },
                UIAction(
                    title: String(localized: "Configuration Management"),
                    image: UIImage(systemName: "slider.horizontal.3"),
                ) { [weak self] _ in self?.manage() },
            ]),
        )
        more.accessibilityLabel = String(localized: "More Options")
        navigationItem.rightBarButtonItems = [add, more]

        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = true
        definesPresentationContext = true

        switchView.addAction(UIAction { [weak self] _ in self?.switchChanged() }, for: .valueChanged)
        switchView.accessibilityLabel = String(localized: "Enable Injection")

        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 116
        tableView.separatorStyle = .none
        // Card surfaces own a 20pt inset; suppress the grouped table's own.
        tableView.contentInset = UIEdgeInsets(top: 0, left: 0, bottom: 16, right: 0)
        dataSource.headerTitle = { _ in nil }
        dataSource.footerTitle = { [weak self] section in
            guard section == .library else { return nil }
            return String(localized: "Automatic configurations are matched against the model at send time. Tap the round button on a card to select it manually.")
        }
        load()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        load()
    }

    // MARK: - Data

    private func load() {
        snapshot = Preferences.PromptInjection.snapshot
        switchView.isOn = snapshot.enabled
        let currentModel = Self.currentModel
        let sorted = snapshot.personas.sorted { lhs, rhs in
            if lhs.pinned != rhs.pinned { return lhs.pinned }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
        items = sorted.filter { persona in
            query.isEmpty
                || persona.name.localizedCaseInsensitiveContains(query)
                || persona.body.localizedCaseInsensitiveContains(query)
        }
        let effective = PersonaResolver.resolve(snapshot, model: currentModel)
        var sections: [(Section, [Row])] = [
            (.status, [.status(text: Self.statusText(snapshot: snapshot))]),
        ]
        if items.isEmpty {
            sections.append((.empty, [.empty(query: !query.isEmpty)]))
        } else {
            sections.append((.library, items.map { persona in
                let selected = snapshot.activeID == persona.id && persona.matchMode == .manual
                let recommended = effective?.id == persona.id && persona.matchMode == .automatic
                return .persona(
                    id: persona.id,
                    name: persona.name,
                    mode: persona.matchMode == .automatic
                        ? String(localized: "Automatic") : String(localized: "Manual"),
                    detail: persona.matchMode == .automatic && !persona.modelPatterns.isEmpty
                        ? persona.modelPatterns.joined(separator: ", ")
                        : String(persona.body.utf8.count) + " B",
                    info: Self.info(for: persona, snapshot: snapshot, currentModel: currentModel),
                    selected: selected,
                    recommended: recommended,
                )
            }))
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

    private static var currentModel: String? {
        Preferences.DefaultModels.selection(for: .derivedConversation)?.model
    }

    private static func info(for persona: Persona, snapshot: PersonaSnapshot, currentModel: String?) -> String {
        let effective = PersonaResolver.resolve(snapshot, model: currentModel)
        var parts: [String] = [
            persona.pinned ? String(localized: "Pin") : String(localized: "Self-created"),
            String(persona.body.utf8.count) + " B",
        ]
        if effective?.id == persona.id && persona.matchMode == .automatic {
            parts.append(String(localized: "Recommended for current model"))
        }
        if snapshot.activeID == persona.id && persona.matchMode == .manual {
            parts.append(String(localized: "Active"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Cells

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row {
        case let .status(text):
            return statusCell(in: tableView, text: text)
        case let .persona(id, name, mode, detail, info, selected, recommended):
            return personaCell(
                in: tableView,
                id: id,
                name: name,
                mode: mode,
                detail: detail,
                info: info,
                selected: selected,
                recommended: recommended,
            )
        case let .empty(query):
            let cell = cardCell(in: tableView, identifier: "empty")
            let label = Self.label(
                query
                    ? String(localized: "没有匹配的配置\n换个关键词试试")
                    : String(localized: "还没有配置\n点击右上角 + 创建"),
                style: .subheadline, color: .secondaryLabel,
            )
            label.textAlignment = .center
            cell.surface.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.surface.leadingAnchor, constant: 20),
                label.trailingAnchor.constraint(equalTo: cell.surface.trailingAnchor, constant: -20),
                label.topAnchor.constraint(equalTo: cell.surface.topAnchor, constant: 36),
                label.bottomAnchor.constraint(equalTo: cell.surface.bottomAnchor, constant: -36),
            ])
            return cell
        }
    }

    private func statusCell(in tableView: UITableView, text: String) -> UITableViewCell {
        let cell = cardCell(in: tableView, identifier: "status")
        let title = Self.label(String(localized: "Prompt Injection"), style: .headline, color: .label)
        let status = Self.label(text, style: .subheadline, color: .secondaryLabel)
        status.accessibilityIdentifier = "persona-status"

        let preview = Self.button(
            title: String(localized: "Preview Injection"),
            symbol: "doc.text.magnifyingglass",
            identifier: "persona-preview",
        ) { [weak self] in self?.preview() }
        let manage = Self.button(
            title: String(localized: "Configuration Management"),
            symbol: "slider.horizontal.3",
            identifier: "persona-management",
        ) { [weak self] in self?.manage() }
        let actions = UIStackView(arrangedSubviews: [preview, manage])
        actions.axis = UITraitCollection.current.preferredContentSizeCategory.isAccessibilityCategory
            ? .vertical : .horizontal
        actions.distribution = .fillEqually
        actions.spacing = 9

        let top = UIStackView(arrangedSubviews: [title, switchView])
        top.axis = .horizontal
        top.alignment = .center
        top.spacing = 12
        let stack = UIStackView(arrangedSubviews: [top, status, actions])
        stack.axis = .vertical
        stack.spacing = 10
        stack.setCustomSpacing(14, after: status)
        stack.translatesAutoresizingMaskIntoConstraints = false
        cell.surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: cell.surface.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: cell.surface.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: cell.surface.leadingAnchor, constant: 17),
            stack.trailingAnchor.constraint(equalTo: cell.surface.trailingAnchor, constant: -17),
        ])
        return cell
    }

    private func personaCell(
        in tableView: UITableView,
        id: String,
        name: String,
        mode: String,
        detail: String,
        info: String,
        selected: Bool,
        recommended: Bool,
    ) -> UITableViewCell {
        let cell = cardCell(in: tableView, identifier: "persona")
        let chosen = selected || recommended
        cell.chosen = chosen
        let title = Self.label(name, style: .headline, color: .label)
        let summary = Self.label(detail, style: .subheadline, color: .secondaryLabel)
        summary.numberOfLines = 2
        let pill = Self.modePill(mode, chosen: chosen)
        let metadata = Self.label(info, style: .caption1, color: .secondaryLabel)
        let tags = UIStackView(arrangedSubviews: [pill, metadata])
        tags.axis = UITraitCollection.current.preferredContentSizeCategory.isAccessibilityCategory
            ? .vertical : .horizontal
        tags.spacing = 8
        tags.alignment = tags.axis == .vertical ? .leading : .center
        pill.setContentHuggingPriority(.required, for: .horizontal)
        metadata.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let text = UIStackView(arrangedSubviews: [title, summary, tags])
        text.axis = .vertical
        text.spacing = 7
        text.translatesAutoresizingMaskIntoConstraints = false

        let choose = UIButton(type: .system)
        let symbol = selected ? "checkmark.circle.fill" : "circle"
        choose.setImage(
            UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 25, weight: .regular)),
            for: .normal,
        )
        choose.tintColor = selected ? Self.accent : .tertiaryLabel
        choose.translatesAutoresizingMaskIntoConstraints = false
        choose.accessibilityLabel = (selected ? String(localized: "Deselect ") : String(localized: "Select ")) + name
        choose.accessibilityIdentifier = "persona-select-" + id
        choose.addAction(UIAction { [weak self] _ in self?.select(id) }, for: .touchUpInside)

        cell.surface.addSubview(text)
        cell.surface.addSubview(choose)
        NSLayoutConstraint.activate([
            text.topAnchor.constraint(equalTo: cell.surface.topAnchor, constant: 16),
            text.bottomAnchor.constraint(equalTo: cell.surface.bottomAnchor, constant: -16),
            text.leadingAnchor.constraint(equalTo: cell.surface.leadingAnchor, constant: 17),
            text.trailingAnchor.constraint(equalTo: choose.leadingAnchor, constant: -8),
            choose.trailingAnchor.constraint(equalTo: cell.surface.trailingAnchor, constant: -9),
            choose.widthAnchor.constraint(equalToConstant: 44),
            choose.heightAnchor.constraint(equalToConstant: 44),
            choose.centerYAnchor.constraint(equalTo: cell.surface.centerYAnchor),
        ])
        cell.accessibilityLabel = [name, detail, mode, info].joined(separator: "，")
        cell.accessibilityHint = String(localized: "Tap to edit; the round button selects manually")
        cell.accessibilityIdentifier = "persona-row-" + id
        return cell
    }

    private func cardCell(in tableView: UITableView, identifier: String) -> CardCell {
        let cell = CardCell(style: .default, reuseIdentifier: identifier)
        cell.selectionStyle = .none
        return cell
    }

    private static func label(_ text: String, style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    private static func modePill(_ text: String, chosen: Bool) -> UIView {
        let pill = UIView()
        let label = Self.label(text, style: .caption1, color: chosen ? Self.accent : .secondaryLabel)
        label.textAlignment = .center
        pill.backgroundColor = chosen ? Self.accent.withAlphaComponent(0.10) : .tertiarySystemFill
        pill.layer.cornerRadius = 5
        pill.translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: pill.topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -3),
        ])
        return pill
    }

    private static func button(
        title: String,
        symbol: String,
        identifier: String,
        action: @escaping () -> Void,
    ) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.title = title
        config.image = UIImage(systemName: symbol)
        config.imagePadding = 6
        config.baseForegroundColor = .label
        config.background.backgroundColor = .tertiarySystemGroupedBackground
        config.background.cornerRadius = 10
        config.contentInsets = NSDirectionalEdgeInsets(top: 9, leading: 10, bottom: 9, trailing: 10)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { incoming in
            var outgoing = incoming
            outgoing.font = .preferredFont(forTextStyle: .subheadline)
            return outgoing
        }
        let button = UIButton(configuration: config)
        button.accessibilityIdentifier = identifier
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }

    static var accent: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.93, green: 0.77, blue: 0.52, alpha: 1)
                : UIColor(red: 0.43, green: 0.31, blue: 0.13, alpha: 1)
        }
    }

    private static func statusText(snapshot: PersonaSnapshot) -> String {
        guard snapshot.enabled else { return String(localized: "已关闭，使用默认提示") }
        let effective = PersonaResolver.resolve(snapshot, model: currentModel)
        if let currentModel, effective?.matchMode == .automatic {
            return String(localized: "自动：\(currentModel) → \(effective?.name ?? String(localized: "未匹配配置"))")
        }
        if effective?.matchMode == .manual {
            return String(localized: "手动：\(effective?.name ?? "")")
        }
        return String(localized: "手动模式 · 尚未选择配置")
    }

    // MARK: - Actions

    @objc private dynamic func switchChanged() {
        var next = snapshot
        next.enabled = switchView.isOn
        save(next)
    }

    private func persona(at indexPath: IndexPath) -> Persona? {
        guard case let .persona(id, _, _, _, _, _, _)? = dataSource.value(at: indexPath) else { return nil }
        return snapshot.personas.first { $0.id == id }
    }

    private func select(_ id: String) {
        guard let persona = snapshot.personas.first(where: { $0.id == id }) else { return }
        if persona.matchMode == .automatic && snapshot.activeID != id {
            presentConfirmation(
                title: "Switch to Manual?",
                message: "Selecting a configuration manually disables automatic matching.",
                confirmTitle: "Switch",
            ) { [weak self] in
                guard let self else { return }
                var next = snapshot
                next.activeID = id
                next.personas = next.personas.map { p in
                    var p = p
                    if p.id == id { p.matchMode = .manual }
                    return p
                }
                save(next)
            }
            return
        }
        var next = snapshot
        next.activeID = snapshot.activeID == id ? nil : id
        save(next)
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        persona(at: indexPath) != nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let persona = persona(at: indexPath) else { return }
        navigationController?.pushViewController(
            PersonaEditorController(persona: persona, snapshot: snapshot),
            animated: true,
        )
    }

    @objc private dynamic func add() {
        let persona = Persona(name: "", body: "")
        navigationController?.pushViewController(
            PersonaEditorController(persona: persona, snapshot: snapshot, isNew: true),
            animated: true,
        )
    }

    private func preview() {
        let controller = PersonaPreviewController(snapshot: snapshot)
        navigationController?.pushViewController(controller, animated: true)
    }

    private func manage() {
        let controller = PersonaManagementController(style: .insetGrouped)
        controller.snapshot = snapshot
        navigationController?.pushViewController(controller, animated: true)
    }

    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text ?? ""
        load()
    }

    override func tableView(
        _ tableView: UITableView,
        viewForHeaderInSection section: Int,
    ) -> UIView? {
        guard dataSource.sectionIdentifier(for: section) == .library else { return nil }
        let header = LibraryHeaderView()
        header.configure(
            title: String(localized: "Configuration Library"),
            count: String(localized: "\(items.count) 项"),
        )
        return header
    }

    override func tableView(_: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        dataSource.sectionIdentifier(for: section) == .library ? 34 : .leastNormalMagnitude
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
        let pin = UIContextualAction(style: .normal, title: String(localized: persona.pinned ? "Unpin" : "Pin")) {
            [weak self] _, _, completion in
            guard let self else { completion(false); return }
            var next = snapshot
            next.personas = next.personas.map { p in
                var p = p
                if p.id == persona.id { p.pinned.toggle() }
                return p
            }
            save(next)
            completion(true)
        }
        pin.image = UIImage(systemName: persona.pinned ? "pin.slash" : "pin.fill")
        pin.backgroundColor = .systemGray
        let config = UISwipeActionsConfiguration(actions: [remove, pin])
        config.performsFirstActionWithFullSwipe = false
        return config
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

/// 配置库区头：左侧「配置库」，右侧当前条目数，和 Dylix 的分区头一致。
private final class LibraryHeaderView: UITableViewHeaderFooterView {
    private let titleLabel = Self.label(style: .footnote, color: .secondaryLabel)
    private let countLabel = Self.label(style: .footnote, color: .secondaryLabel)

    override init(reuseIdentifier: String?) {
        super.init(reuseIdentifier: reuseIdentifier)
        countLabel.textAlignment = .right
        let row = UIStackView(arrangedSubviews: [titleLabel, countLabel])
        row.axis = .horizontal
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(reuseIdentifier:)") }

    func configure(title: String, count: String) {
        titleLabel.text = title
        countLabel.text = count
    }

    private static func label(style: UIFont.TextStyle, color: UIColor) -> UILabel {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }
}

/// A card surface with the Dylix 18pt continuous corner and a selection
/// border. Only the surface is inset; the table's own inset is removed by the
/// content insets below so cards are not inset twice.
private final class CardCell: UITableViewCell {
    let surface = UIView()
    var chosen = false {
        didSet { updateSurface() }
    }

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        backgroundColor = .clear
        surface.translatesAutoresizingMaskIntoConstraints = false
        surface.layer.cornerRadius = 18
        surface.layer.cornerCurve = .continuous
        contentView.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),
            surface.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 5),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -5),
        ])
        updateSurface()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(style:reuseIdentifier:)") }

    private func updateSurface() {
        surface.backgroundColor = .secondarySystemGroupedBackground
        surface.layer.borderWidth = chosen ? 1.2 : 0.5
        let color: UIColor = chosen
            ? PromptInjectionController.accent.withAlphaComponent(0.55)
            : UIColor.separator.withAlphaComponent(0.24)
        surface.layer.borderColor = color.resolvedColor(with: traitCollection).cgColor
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        updateSurface()
    }

    override func setHighlighted(_ highlighted: Bool, animated: Bool) {
        super.setHighlighted(highlighted, animated: animated)
        surface.alpha = highlighted ? 0.72 : 1
    }
}
