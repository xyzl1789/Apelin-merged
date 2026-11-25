import UIKit

/// 设置 ▸ 后台运行。只控制本应用，不提供其他 App 的保活名单。
final class ForegroundBackgroundController: TableController {
    private enum Row: Int, CaseIterable {
        case enabled, notifications, locked, indicators, lockIndicator, status, protectionStatus
    }

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
        "后台保活可能增加耗电；首次安装模块需重新加载 SpringBoard。锁定仅防止从应用切换器划掉本应用，不阻止系统终止或崩溃。运行状态表示进程存在，不代表持续执行或保活成功。各开关独立；关闭标记后恢复系统原样。前台通知不绕过通知授权、专注模式或静音。开源许可见设置 → 关于 → 许可证。"
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = Row(rawValue: indexPath.row)!
        let cell = UITableViewCell(style: .subtitle, reuseIdentifier: nil)
        var content = UIListContentConfiguration.subtitleCell()
        cell.selectionStyle = .none
        switch row {
        case .enabled:
            content.text = "启用后台保活"
            cell.accessoryView = toggle("启用后台保活", ForegroundBackground.enabled, #selector(changeEnabled(_:)))
        case .notifications:
            content.text = "启用前台通知"
            cell.accessoryView = toggle("启用前台通知", ForegroundBackground.foregroundNotifications, #selector(changeNotifications(_:)))
        case .locked:
            content.text = "锁定后台卡片"
            cell.accessoryView = toggle("锁定后台卡片", ForegroundBackground.locked, #selector(changeLocked(_:)))
        case .indicators:
            content.text = "显示运行状态"
            content.secondaryText = "在本应用图标名称旁显示运行或停止标记"
            cell.accessoryView = toggle("显示运行状态", ForegroundBackground.indicators, #selector(changeIndicators(_:)))
        case .lockIndicator:
            content.text = "显示锁定标记"
            cell.accessoryView = toggle("显示锁定标记", ForegroundBackground.lockIndicator, #selector(changeLockIndicator(_:)))
        case .status:
            content.text = "保活模块状态"
            content.secondaryText = ForegroundBackground.summary
        case .protectionStatus:
            content.text = "锁定与标记状态"
            content.secondaryText = ForegroundBackground.protectionSummary
        }
        content.secondaryTextProperties.numberOfLines = 0
        cell.contentConfiguration = content
        return cell
    }

    private func toggle(_ label: String, _ value: Bool, _ action: Selector) -> UISwitch {
        let toggle = UISwitch()
        toggle.isOn = value
        toggle.accessibilityLabel = label
        toggle.addTarget(self, action: action, for: .valueChanged)
        return toggle
    }

    @objc private dynamic func changeEnabled(_ toggle: UISwitch) { ForegroundBackground.enabled = toggle.isOn }
    @objc private dynamic func changeNotifications(_ toggle: UISwitch) { ForegroundBackground.foregroundNotifications = toggle.isOn }
    @objc private dynamic func changeLocked(_ toggle: UISwitch) { ForegroundBackground.locked = toggle.isOn }
    @objc private dynamic func changeIndicators(_ toggle: UISwitch) { ForegroundBackground.indicators = toggle.isOn }
    @objc private dynamic func changeLockIndicator(_ toggle: UISwitch) { ForegroundBackground.lockIndicator = toggle.isOn }
    @objc private dynamic func reloadStatus() {
        tableView.reloadRows(at: [Row.status, .protectionStatus].map { IndexPath(row: $0.rawValue, section: 0) }, with: .none)
    }
}
