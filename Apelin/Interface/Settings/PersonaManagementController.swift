import ApelinCore
import UIKit

/// Dylix-style management page. The repo's persona model has no separate
/// matching-mode flag: an item is manual or automatic by its own setting, so
/// this page explains the matching rule and owns the one app-wide switch the
/// model does have — whether any persona body is injected at all.
final class PersonaManagementController: UITableViewController {
    var snapshot = PersonaSnapshot()

    private enum Row: Int {
        case enabled
        case automatic
        case rule
        case pinning
    }

    override init(style: UITableView.Style) {
        super.init(style: style)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(style:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Configuration Management")
        view.tintColor = PromptInjectionController.accent
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 72
    }

    override func numberOfSections(in _: UITableView) -> Int { 1 }

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { 4 }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        String(localized: "自动模式按实际请求的模型匹配配置；手动模式由配置库右侧的圆形按钮选定。置顶只影响列表顺序，不影响注入效果。")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let row = Row(rawValue: indexPath.row) else { return UITableViewCell() }
        if row == .rule || row == .pinning {
            let cell = tableView.dequeueReusableCell(withIdentifier: "footnote")
                ?? UITableViewCell(style: .default, reuseIdentifier: "footnote")
            var content = UIListContentConfiguration.explanatoryCell()
            if row == .rule {
                content.text = String(localized: "匹配规则")
                content.secondaryText = String(localized: "自动配置按模型匹配；多个命中取优先级最高的，再按名称、标识排序。手动配置在没有自动命中时生效。")
            } else {
                content.text = String(localized: "置顶与排序")
                content.secondaryText = String(localized: "置顶配置排在配置库最前，不影响注入效果。向左轻扫配置卡片可置顶或删除。")
            }
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "switch")
            ?? UITableViewCell(style: .subtitle, reuseIdentifier: "switch")
        let toggle = UISwitch()
        toggle.addAction(UIAction { [weak self] _ in
            self?.changed(row: row, on: toggle.isOn)
        }, for: .valueChanged)
        toggle.accessibilityLabel = row == .enabled
            ? String(localized: "Inject Persona Body")
            : String(localized: "Automatic Matching")
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.explanatoryCell()
        if row == .enabled {
            toggle.isOn = snapshot.enabled
            content.text = String(localized: "注入人设正文")
            content.secondaryText = String(localized: "关闭后不向对话注入任何配置正文")
        } else {
            let automatic = snapshot.personas.filter { $0.matchMode == .automatic }
            toggle.isOn = !automatic.isEmpty
            content.text = String(localized: "按当前模型自动匹配")
            content.secondaryText = automatic.isEmpty
                ? String(localized: "目前没有自动配置，在配置里切换为「自动」即可")
                : String(localized: "已有 \(automatic.count) 项自动配置，命中时压过手动选择")
        }
        cell.contentConfiguration = content
        cell.isAccessibilityElement = false
        return cell
    }

    private func changed(row: Row, on: Bool) {
        guard row == .enabled else {
            // The persona model stores matching per configuration. A global
            // automatic switch would have to rewrite every item, so this row
            // only reports the current state; the user changes it per card.
            tableView.reloadData()
            presentNotice(
                title: "Matching Is Per Configuration",
                message: "Open a configuration and switch it between Manual and Automatic.",
            )
            return
        }
        var next = snapshot
        next.enabled = on
        do {
            try Preferences.PromptInjection.save(next)
            snapshot = next
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
        }
        tableView.reloadData()
    }
}
