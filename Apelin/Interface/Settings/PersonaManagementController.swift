import ApelinCore
import UIKit

/// 配置管理：自动匹配由每项配置决定，这里只管理全局注入开关并说明匹配规则。
final class PersonaManagementController: UITableViewController {
    var snapshot = PersonaSnapshot()

    private enum Row: Int {
        case enabled
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

    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { 3 }

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
        toggle.isOn = snapshot.enabled
        toggle.addAction(UIAction { [weak self] _ in
            self?.changed(on: toggle.isOn)
        }, for: .valueChanged)
        toggle.accessibilityLabel = String(localized: "Inject Persona Body")
        cell.accessoryView = toggle
        cell.selectionStyle = .none
        var content = UIListContentConfiguration.explanatoryCell()
        content.text = String(localized: "注入人设正文")
        content.secondaryText = String(localized: "关闭后不向对话注入任何配置正文")
        cell.contentConfiguration = content
        cell.isAccessibilityElement = false
        return cell
    }

    private func changed(on: Bool) {
        var next = snapshot
        next.enabled = on
        do {
            try Preferences.PromptInjection.save(next, replacing: snapshot)
            snapshot = next
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
        }
        tableView.reloadData()
    }
}
