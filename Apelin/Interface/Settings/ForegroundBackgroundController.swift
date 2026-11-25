import UIKit

/// 设置 ▸ 后台运行。只控制本应用，不提供其他 App 的保活名单。
final class ForegroundBackgroundController: TableController {
    private enum Row: Int, CaseIterable { case enabled, notifications, status, license }

    init() { super.init(style: .insetGrouped) }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "后台运行"
        NotificationCenter.default.addObserver(
            self, selector: #selector(reloadStatus), name: ForegroundBackground.changed, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func numberOfSections(in _: UITableView) -> Int { 1 }
    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { Row.allCases.count }

    override func tableView(_: UITableView, titleForFooterInSection _: Int) -> String? {
        "通过保持本应用的前台场景减少后台挂起，可能增加耗电。默认关闭；首次安装模块需重新加载 SpringBoard。启用前台通知可避免场景保持时通知被当作前台消息隐藏，不绕过通知授权或专注模式。"
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = Row(rawValue: indexPath.row)!
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        cell.selectionStyle = .none
        switch row {
        case .enabled:
            content.text = "启用后台保活"
            let toggle = UISwitch()
            toggle.isOn = ForegroundBackground.enabled
            toggle.accessibilityLabel = "启用后台保活"
            toggle.addTarget(self, action: #selector(changeEnabled(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        case .notifications:
            content.text = "启用前台通知"
            let toggle = UISwitch()
            toggle.isOn = ForegroundBackground.foregroundNotifications
            toggle.accessibilityLabel = "启用前台通知"
            toggle.addTarget(self, action: #selector(changeNotifications(_:)), for: .valueChanged)
            cell.accessoryView = toggle
        case .license:
            content.text = "Immortalizer 开源许可"
            content.secondaryText = "Serge Alagon · GPL-3.0-or-later · 不提供担保"
            content.secondaryTextProperties.numberOfLines = 0
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        case .status:
            content.text = "模块状态"
            content.secondaryText = ForegroundBackground.summary
            content.secondaryTextProperties.numberOfLines = 0
        }
        cell.contentConfiguration = content
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Row(rawValue: indexPath.row) == .license else { return }
        let page = UIViewController()
        page.title = "后台模块开源许可"
        let text = UITextView()
        text.isEditable = false
        text.font = .preferredFont(forTextStyle: .body)
        text.adjustsFontForContentSizeCategory = true
        text.backgroundColor = .systemBackground
        if let url = Bundle.main.url(forResource: "ApelinForeground-LICENSE", withExtension: "txt"),
           let license = try? String(contentsOf: url, encoding: .utf8) {
            text.text = "Immortalizer · Copyright (C) 2024 Serge Alagon\n修改日期：2026-11-25\n本模块可按 GPL 第3版或更新版本修改及再分发，不提供任何担保。\n\n" + license
        } else {
            text.text = "许可文件缺失，请重新安装完整软件包。"
        }
        page.view = text
        navigationController?.pushViewController(page, animated: true)
    }

    @objc private dynamic func changeEnabled(_ toggle: UISwitch) { ForegroundBackground.enabled = toggle.isOn }
    @objc private dynamic func changeNotifications(_ toggle: UISwitch) { ForegroundBackground.foregroundNotifications = toggle.isOn }
    @objc private dynamic func reloadStatus() {
        tableView.reloadRows(at: [IndexPath(row: Row.status.rawValue, section: 0)], with: .none)
    }
}
