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

    override func numberOfSections(in _: UITableView) -> Int { Row.allCases.count }
    override func tableView(_: UITableView, numberOfRowsInSection _: Int) -> Int { 1 }

    override func tableView(_: UITableView, titleForFooterInSection section: Int) -> String? {
        switch Row(rawValue: section)! {
        case .enabled:
            return "未开启后台保活时，应用退到后台后无法持续使用任务进度实时活动与灵动岛实时显示功能。开启后可能增加耗电；首次安装或更新模块后需注销（重新加载 SpringBoard）才能生效。灵动岛需设备支持。"
        case .notifications:
            return "允许保活期间正常递送通知；正在查看的当前会话不弹通知。不绕过系统通知授权、专注模式或静音。"
        case .locked:
            return "仅防止从应用切换器划掉本应用，不阻止系统终止或崩溃。与后台保活开关独立。"
        case .indicators:
            return "在本应用图标名称旁显示运行或停止标记。运行只表示进程存在，不代表持续执行或保活成功；关闭后恢复系统原样。"
        case .lockIndicator:
            return "锁定后台卡片后，在本应用名称旁显示 🔒 图标；关闭后恢复原名称。"
        case .status:
            return "模块状态仅用于核对连接和场景保持；持续运行效果仍需实测。"
        case .protectionStatus:
            return "核对卡片锁定及标记接口状态；修改开关无需再次注销。"
        }
    }

    override func tableView(_: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let row = Row(rawValue: indexPath.section)!
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
        tableView.reloadRows(at: [Row.status, .protectionStatus].map { IndexPath(row: 0, section: $0.rawValue) }, with: .none)
    }
}
