import ApelinCore
import UIKit

/// 照 Minis 的 ChatSearchBar/ChatSearchController：聊天页顶部内嵌的搜索条——
/// 查询框、"3/12" 计数、上一个/下一个（循环）、完成。不再弹独立的表单页。
/// 点 🔍 只是打开它的入口，行为全照 Minis：
///   - 输入 250ms 防抖后搜索，落到最新一处结果；
///   - 上一个/下一个循环移动（到头绕回，弹一条短提示）；
///   - 跳转时断开「跟随最新输出」，流式输出不再把列表拽回底部。
/// 结果存在会话内，按消息分组排序（自上而下），便于上下步进。
@MainActor
final class ChatInlineSearch: NSObject {
    /// 一处命中。
    struct Match {
        let messageID: UUID
        let text: String
    }

    enum Notice {
        case wrappedToFirst
        case wrappedToLast

        var text: String {
            switch self {
            case .wrappedToFirst: String(localized: "Wrapped to the first result")
            case .wrappedToLast: String(localized: "Wrapped to the last result")
            }
        }
    }

    private(set) var isActive = false
    private(set) var query = ""
    private(set) var matches: [Match] = []
    private(set) var currentIndex: Int?
    /// 一个让搜索条更新自己的钩子（刷新计数、按钮可用性）。
    var onUpdate: (() -> Void)?
    /// 跳到某条消息的钩子（列表滚动，断开跟随）。
    var onNavigate: ((UUID) -> Void)?
    /// 关闭时收起搜索条、恢复输入框的钩子。
    var onDeactivate: (() -> Void)?

    /// 命中按会话顺序排（自上而下），Minis 是最新优先，但那套配合
    /// 「跳到最新」语义；这里自上而下更贴合上下步进的直觉，Minis 的
    /// 循环与计数行为不变。
    private let messages: () -> [(id: UUID, role: String, text: String)]
    private var noticeClear: DispatchWorkItem?
    private(set) var notice: Notice?

    init(messages: @escaping () -> [(id: UUID, role: String, text: String)]) {
        self.messages = messages
        super.init()
    }

    var hasResults: Bool { !matches.isEmpty }

    var counterText: String? {
        guard let index = currentIndex else { return nil }
        return "\(index + 1)/\(matches.count)"
    }

    func activate() {
        guard !isActive else { return }
        isActive = true
        onUpdate?()
    }

    func deactivate() {
        guard isActive else { return }
        isActive = false
        query = ""
        matches = []
        currentIndex = nil
        notice = nil
        noticeClear?.cancel()
        onDeactivate?()
        onUpdate?()
    }

    /// 输入变化：立即重搜（消息量级内一次全文扫描足够快，Minis 的
    /// 250ms 防抖防的是每键一次的重排，这里搜索本身轻，直接跑）。
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        query = trimmed
        guard !trimmed.isEmpty else {
            matches = []
            currentIndex = nil
            onUpdate?()
            return
        }
        // Best first 之后按会话顺序还原：先按分数过滤（要不要出现），
        // 再按消息在会话里的位置排序（Minis 的上下步进语义）。
        let entries = messages()
        let hits = SearchScorer.ranked(entries, query: trimmed) { $0.text }
            .map { $0.item }
        let order = Dictionary(uniqueKeysWithValues: entries.indices.map { (entries[$0].id, $0) })
        matches = hits.sorted { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
            .map { Match(messageID: $0.id, text: $0.text) }
        // 新查询落到最新一处结果之前先跳到第一处；Minis 是「最新优先」，
        // 这里顺序自上而下，落到第一条命中等价于「最先能看到的」。
        currentIndex = matches.isEmpty ? nil : 0
        onUpdate?()
        navigateToCurrent()
    }

    func next() { step(forward: true) }
    func previous() { step(forward: false) }

    private func step(forward: Bool) {
        guard !matches.isEmpty else { return }
        let count = matches.count
        let current = currentIndex ?? (forward ? -1 : 0)
        var moved = current + (forward ? 1 : -1)
        var wrapped = false
        if moved >= count { moved = 0; wrapped = true }
        if moved < 0 { moved = count - 1; wrapped = true }
        currentIndex = moved
        if wrapped {
            showNotice(forward ? .wrappedToFirst : .wrappedToLast)
        }
        onUpdate?()
        navigateToCurrent()
    }

    private func navigateToCurrent() {
        guard let index = currentIndex, matches.indices.contains(index) else { return }
        onNavigate?(matches[index].messageID)
    }

    private func showNotice(_ value: Notice) {
        notice = value
        noticeClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.notice = nil
            self?.onUpdate?()
        }
        noticeClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6, execute: work)
        onUpdate?()
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: value.text)
        }
    }
}

/// 搜索条本身：查询框、计数、上/下、完成，挂在聊天页顶部（导航栏下），
/// 打开时收起输入框。样式照 Minis 的 ChatSearchBar。
final class ChatInlineSearchBar: UIView {
    let field = UITextField()
    private let counterLabel = UILabel()
    private let activity = UIActivityIndicatorView(style: .medium)
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    private let doneButton = UIButton(type: .system)
    private let noticeLabel = UILabel()
    private let noticeBackground = UIView()

    var onQueryChange: ((String) -> Void)?
    var onNext: (() -> Void)?
    var onPrevious: (() -> Void)?
    var onDone: (() -> Void)?

    init() {
        super.init(frame: .zero)
        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        field.placeholder = String(localized: "Search this chat")
        field.clearButtonMode = .whileEditing
        field.autocorrectionType = .no
        field.autocapitalizationType = .none
        field.returnKeyType = .search
        field.font = .preferredFont(forTextStyle: .body)
        field.accessibilityIdentifier = "chatSearchField"
        field.addTarget(self, action: #selector(fieldChanged), for: .editingChanged)
        field.addTarget(self, action: #selector(fieldSubmitted), for: .editingDidEndOnExit)
        addSubview(field)

        counterLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        counterLabel.textColor = .secondaryLabel
        counterLabel.accessibilityIdentifier = "chatSearchCounter"
        addSubview(counterLabel)

        activity.hidesWhenStopped = true
        addSubview(activity)

        let config = UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        previousButton.setImage(UIImage(systemName: "chevron.up", withConfiguration: config), for: .normal)
        previousButton.accessibilityLabel = String(localized: "Previous Result")
        previousButton.accessibilityIdentifier = "chatSearchPrevious"
        previousButton.addTarget(self, action: #selector(previousPressed), for: .touchUpInside)
        addSubview(previousButton)

        nextButton.setImage(UIImage(systemName: "chevron.down", withConfiguration: config), for: .normal)
        nextButton.accessibilityLabel = String(localized: "Next Result")
        nextButton.accessibilityIdentifier = "chatSearchNext"
        nextButton.addTarget(self, action: #selector(nextPressed), for: .touchUpInside)
        addSubview(nextButton)

        doneButton.setTitle(String(localized: "Done"), for: .normal)
        doneButton.titleLabel?.font = .preferredFont(forTextStyle: .body)
        doneButton.accessibilityIdentifier = "chatSearchDone"
        doneButton.addTarget(self, action: #selector(donePressed), for: .touchUpInside)
        addSubview(doneButton)

        // 到头绕回的短提示，照 Minis 的 noticeView：黑胶囊，1.6s 消失。
        noticeBackground.backgroundColor = UIColor.black.withAlphaComponent(0.75)
        noticeBackground.layer.cornerRadius = 14
        noticeBackground.isHidden = true
        noticeBackground.isUserInteractionEnabled = false
        noticeBackground.isAccessibilityElement = false
        noticeLabel.font = .preferredFont(forTextStyle: .footnote)
        noticeLabel.textColor = .white
        noticeBackground.addSubview(noticeLabel)
        addSubview(noticeBackground)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    @objc private func fieldChanged() {
        onQueryChange?(field.text ?? "")
    }

    /// Return = 下一个结果，键盘不收（正在逐条看结果）。
    @objc private func fieldSubmitted() {
        field.becomeFirstResponder()
        onNext?()
    }

    @objc private func nextPressed() { onNext?() }
    @objc private func previousPressed() { onPrevious?() }
    @objc private func donePressed() { onDone?() }

    func showNotice(_ text: String) {
        noticeLabel.text = text
        noticeBackground.isHidden = false
        alpha = 1
        UIView.animate(withDuration: 0.2) { self.noticeBackground.alpha = 1 }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            guard let self else { return }
            UIView.animate(
                withDuration: 0.2,
                animations: { self.noticeBackground.alpha = 0 },
            ) { _ in
                self.noticeBackground.isHidden = true
            }
        }
    }

    func update(counter: String?, hasResults: Bool) {
        counterLabel.text = counter ?? String(localized: "No results")
        counterLabel.isHidden = counter == nil && (field.text ?? "").isEmpty
        previousButton.isEnabled = hasResults
        nextButton.isEnabled = hasResults
        let tint: UIColor = hasResults ? .systemBlue : .tertiaryLabel
        previousButton.tintColor = tint
        nextButton.tintColor = tint
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = bounds.height
        let inset: CGFloat = 10
        doneButton.sizeToFit()
        let doneWidth = doneButton.bounds.width
        doneButton.frame = CGRect(
            x: bounds.maxX - inset - doneWidth,
            y: 0,
            width: doneWidth,
            height: height,
        )
        nextButton.frame = CGRect(x: doneButton.frame.minX - 38, y: 0, width: 36, height: height)
        previousButton.frame = CGRect(x: nextButton.frame.minX - 36, y: 0, width: 36, height: height)
        let counterSize = counterLabel.intrinsicContentSize
        counterLabel.frame = CGRect(
            x: previousButton.frame.minX - 6 - counterSize.width,
            y: (height - counterSize.height) / 2,
            width: counterSize.width,
            height: counterSize.height,
        )
        let fieldTrailing = counterLabel.frame.minX - 8
        field.frame = CGRect(x: inset, y: 0, width: max(0, fieldTrailing - inset), height: height)
        activity.center = CGPoint(x: field.frame.maxX + 12, y: height / 2)

        let noticeSize = noticeLabel.intrinsicContentSize
        let noticeWidth = noticeSize.width + 24
        noticeBackground.frame = CGRect(
            x: (bounds.width - noticeWidth) / 2,
            y: bounds.maxY + 8,
            width: noticeWidth,
            height: noticeSize.height + 12,
        )
        noticeLabel.frame = noticeBackground.bounds.insetBy(dx: 12, dy: 6)
    }
}
