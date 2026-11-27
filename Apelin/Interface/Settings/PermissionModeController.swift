import ApelinProtocol
import UIKit

/// 权限模式、逐次屏幕询问和独立解锁授权；保存密码本身不授予解锁权限。
final class PermissionModeController: TableController {
    private let modes: [ApprovalMode] = [.confirm, .relaxed, .full]

    private enum Section: Hashable {
        case modes
        case screen
        case unlock
    }

    private enum RowID: Hashable {
        case mode(ApprovalMode)
        case asksBeforeScreen
        case allowsUnlock
        case passcode
    }

    private struct Row: Equatable {
        let id: RowID
        var selected = false
        var enabled = true
    }

    private lazy var dataSource = TableDataSource<Section, RowID, Row>(
        tableView: tableView,
        identifier: { $0.id },
    ) { [weak self] table, _, row in
        self?.cell(in: table, row: row)
    }

    private var passcodeState: DevicePasscodeState?
    @objc private dynamic var isResolvingUnlock = false

    @objc private dynamic func updateRows() {
        dataSource.footerTitle = { section in
            switch section {
            case .modes: AgentPermissions.explanation
            case .screen: String(localized: "While this is on, the agent asks you before it opens an app or a link, reads what is on the screen or acts on it, through Apelin’s screen tools or icli, in every permission mode. Before a screenshot it always asks in the conversation. Each chat follows a change when you send its next message.")
            case .unlock: "开启后，智能体可使用在此保存并测试过的密码自行解锁设备，让需要屏幕的任务继续进行。无密码设备无需保存密码。密码只保存在本机钥匙串，智能体无法看到。每个会话在你发送下一条消息时采用新设置。"
            }
        }
        var sections: [(Section, [Row])] = [
            (.modes, modes.map { Row(id: .mode($0), selected: $0 == AgentPermissions.mode) }),
            (.screen, [Row(id: .asksBeforeScreen, selected: AgentPermissions.asksBeforeScreen)]),
        ]
        if !AgentPermissions.asksBeforeScreen {
            var rows = [Row(id: .allowsUnlock, selected: AgentPermissions.allowsUnlock, enabled: !isResolvingUnlock)]
            if AgentPermissions.allowsUnlock, passcodeState?.saved == true {
                rows.append(Row(id: .passcode))
            }
            sections.append((.unlock, rows))
        }
        dataSource.update(sections, reconfigure: true)
    }

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Permission Mode")
        updateRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadPasscodeState()
    }

    /// 这里只读取保存状态，不读取密码；从密码页返回后刷新管理入口。
    @objc private dynamic func reloadPasscodeState() {
        Task { [weak self] in
            let answer = try? await ApelinService.app.devicePasscodeState()
            guard let self else { return }
            passcodeState = answer
            updateRows()
        }
    }

    /// 每次开启都重新查询，不能把页面打开时的旧缓存当作密码仍有效。
    @objc private dynamic func resolvePasscode() {
        isResolvingUnlock = true
        updateRows()
        Task { [weak self] in
            do {
                let answer = try await ApelinService.app.devicePasscodeState()
                guard let self else { return }
                isResolvingUnlock = false
                passcodeState = answer
                guard !AgentPermissions.asksBeforeScreen else {
                    updateRows()
                    return
                }
                if answer.saved || answer.device == .noPasscode {
                    AgentPermissions.allowsUnlock = true
                    updateRows()
                } else {
                    updateRows()
                    presentPasscodePage()
                }
            } catch {
                guard let self else { return }
                isResolvingUnlock = false
                updateRows()
                presentNotice(title: "无法确认解锁条件", message: error.readableMessage)
            }
        }
    }

    @objc private dynamic func presentPasscodePage() {
        let page = DevicePasscodeController()
        page.onSaved = { [weak self] in
            guard let self, !AgentPermissions.asksBeforeScreen else { return }
            AgentPermissions.allowsUnlock = true
            reloadPasscodeState()
        }
        navigationController?.pushViewController(page, animated: true)
    }

    private func cell(in tableView: UITableView, row: Row) -> UITableViewCell {
        switch row.id {
        case let .mode(mode):
            let cell = tableView.dequeueReusableCell(withIdentifier: "mode")
                ?? UITableViewCell(style: .default, reuseIdentifier: "mode")
            var content = cell.defaultContentConfiguration()
            content.text = AgentPermissions.title(for: mode)
            cell.contentConfiguration = content
            cell.accessoryType = row.selected ? .checkmark : .none
            cell.accessibilityTraits = row.selected ? [.button, .selected] : [.button]
            return cell
        case .asksBeforeScreen, .allowsUnlock:
            let asks = row.id == .asksBeforeScreen
            let identifier = asks ? "screen" : "unlock"
            let cell = tableView.dequeueReusableCell(withIdentifier: identifier)
                ?? UITableViewCell(style: .default, reuseIdentifier: identifier)
            var content = cell.defaultContentConfiguration()
            content.text = asks ? String(localized: "Ask Before Using the Screen") : "让智能体自行解锁设备"
            cell.contentConfiguration = content
            cell.selectionStyle = .none
            let toggle = (cell.accessoryView as? UISwitch) ?? UISwitch()
            toggle.isOn = row.selected
            toggle.isEnabled = row.enabled
            toggle.accessibilityLabel = content.text
            toggle.removeTarget(nil, action: nil, for: .valueChanged)
            toggle.addTarget(
                self,
                action: asks ? #selector(asksBeforeScreenChanged(_:)) : #selector(allowsUnlockChanged(_:)),
                for: .valueChanged,
            )
            cell.accessoryView = toggle
            return cell
        case .passcode:
            let cell = tableView.dequeueReusableCell(withIdentifier: "passcode")
                ?? UITableViewCell(style: .value1, reuseIdentifier: "passcode")
            var content = UIListContentConfiguration.valueCell()
            content.text = String(localized: "Device Passcode")
            content.secondaryText = String(localized: "Saved")
            cell.contentConfiguration = content
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    override func tableView(_: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
        switch dataSource.value(at: indexPath)?.id {
        case .mode, .passcode: true
        default: false
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        switch dataSource.value(at: indexPath)?.id {
        case .passcode: presentPasscodePage()
        case let .mode(mode): select(mode)
        default: break
        }
    }

    @objc private dynamic func asksBeforeScreenChanged(_ toggle: UISwitch) {
        AgentPermissions.asksBeforeScreen = toggle.isOn
        updateRows()
    }

    @objc private dynamic func allowsUnlockChanged(_ toggle: UISwitch) {
        guard toggle.isOn else {
            AgentPermissions.allowsUnlock = false
            updateRows()
            return
        }
        // 只有确认无密码或已有实测通过的密码，开关才真正变为开启。
        toggle.isOn = false
        resolvePasscode()
    }

    private func select(_ mode: ApprovalMode) {
        let current = AgentPermissions.mode
        guard mode != current else { return }
        switch mode {
        case .full:
            presentConfirmation(
                title: "Enable Full Mode?",
                message: "The agent can run commands as root without asking, with full control of this device. Each chat switches when you send its next message.",
                confirmTitle: "Enable Full Mode",
                destructive: true,
            ) { [weak self] in
                Task { @MainActor in
                    guard await DeviceOwnerCheck.confirm(
                        reason: String(localized: "Let the agent run commands as root without asking."),
                    ) else { return }
                    self?.save(mode)
                }
            }
        case .relaxed where current == .confirm:
            presentConfirmation(
                title: "Enable Relaxed Mode?",
                message: "The agent can run commands and make changes without asking, within the app’s permissions. Each chat switches when you send its next message.",
                confirmTitle: "Enable Relaxed Mode",
            ) { [weak self] in self?.save(mode) }
        default:
            save(mode)
        }
    }

    private func save(_ mode: ApprovalMode) {
        AgentPermissions.mode = mode
        updateRows()
    }
}
