import os
import SnapKit
import UIKit

/// 转录中展开的思考和工具步骤；每一步独立测高，不再拟合整叠视图。
@MainActor
final class ChatTraceSteps: UIView {
    @objc dynamic var onExpansionChange: (() -> Void)?

    private let stack = UIStackView()
    var hasSteps: Bool { !order.isEmpty }
    private var order: [UUID] = []
    private var views: [UUID: UIView] = [:]
    private var shown: [UUID: ChatMessageShape] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        stack.axis = .vertical
        stack.spacing = Self.spacing
        stack.translatesAutoresizingMaskIntoConstraints = true
        addSubview(stack)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ summary: ChatMessage) {
        let steps = Self.drawn(summary).map { Self.paced($0) }
        guard steps.map(\.id) == order else {
            rebuild(with: steps)
            return
        }
        for step in steps {
            let shape = ChatMessageShape(step)
            if shown[step.id] != shape {
                if let row = views[step.id] as? ChatToolCallRow {
                    row.show(step)
                } else if let row = views[step.id] as? ChatThoughtRow {
                    row.show(step)
                }
                shown[step.id] = shape
            }
            if let row = views[step.id] as? ChatToolCallRow {
                row.applyExpansion()
            } else if let row = views[step.id] as? ChatThoughtRow {
                row.applyExpansion()
            }
        }
    }

    private func rebuild(with steps: [ChatMessage]) {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        views.removeAll(keepingCapacity: true)
        shown.removeAll(keepingCapacity: true)
        order = steps.map(\.id)
        for step in steps {
            let view: UIView
            switch step.role {
            case .thinking:
                let row = ChatThoughtRow(step: step)
                row.onToggle = { [weak self] in self?.onExpansionChange?() }
                view = row
            default:
                let row = ChatToolCallRow(step: step)
                row.onToggle = { [weak self] in self?.onExpansionChange?() }
                view = row
            }
            stack.addArrangedSubview(view)
            views[step.id] = view
            shown[step.id] = ChatMessageShape(step)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        stack.frame = bounds
    }

    static func height(for summary: ChatMessage, width: CGFloat) -> CGFloat {
        guard width > 1 else { return 0 }
        let steps = drawn(summary).map { paced($0) }
        guard !steps.isEmpty else { return 0 }
        var total: CGFloat = 0
        for (index, step) in steps.enumerated() {
            if index > 0 { total += spacing }
            total += measuredHeight(of: step, width: width)
        }
        return ceil(total)
    }

    private static let spacing: CGFloat = 4

    private struct StepStamp: Equatable {
        var shape: ChatMessageShape
        var opened: Bool
        var width: CGFloat
        var size: UIContentSizeCategory
    }

    private static var heights = ChatStepHeights<StepStamp>()
    private static var sizingCall: ChatToolCallRow?
    private static var sizingThought: ChatThoughtRow?
    private static var sizingTextSize: UIContentSizeCategory?
    private static let slowStep: CFTimeInterval = 0.004
    private static let log = Logger(subsystem: "wiki.qaq.apelin", category: "ChatTranscript")

    private static func measuredHeight(of step: ChatMessage, width: CGFloat) -> CGFloat {
        let stamp = StepStamp(
            shape: ChatMessageShape(step),
            opened: isOpened(step),
            width: width,
            size: UIApplication.shared.preferredContentSizeCategory,
        )
        return heights.height(for: step.id, stamp: stamp) {
            let started = CACurrentMediaTime()
            let height = fittedHeight(of: step, width: width)
            let elapsed = CACurrentMediaTime() - started
            if elapsed > slowStep {
                log.notice("步骤测高耗时 \(elapsed * 1000, privacy: .public) 毫秒，宽度 \(width, privacy: .public) 点，正文 \(step.text.utf8.count, privacy: .public) 字节")
            }
            return height
        }
    }

    private static func fittedHeight(of step: ChatMessage, width: CGFloat) -> CGFloat {
        // 测量视图不在窗口中，动态字体变更时重建，避免旧字体写入新缓存键。
        let size = UIApplication.shared.preferredContentSizeCategory
        if sizingTextSize != size {
            sizingTextSize = size
            sizingCall = nil
            sizingThought = nil
        }
        let row: UIView
        if case .thinking = step.role {
            let thought = sizingThought ?? ChatThoughtRow(step: step)
            sizingThought = thought
            thought.show(step)
            thought.applyExpansion()
            row = thought
        } else {
            let call = sizingCall ?? ChatToolCallRow(step: step)
            sizingCall = call
            call.show(step)
            call.applyExpansion()
            row = call
        }
        row.frame = CGRect(x: 0, y: 0, width: width, height: 1)
        row.setNeedsLayout()
        row.layoutIfNeeded()
        return row.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel,
        ).height
    }

    static func drawn(_ summary: ChatMessage) -> [ChatMessage] {
        ChatActivityContent.steps(summary)
    }

    private static func paced(_ step: ChatMessage) -> ChatMessage {
        guard case .thinking = step.role else { return step }
        var paced = step
        paced.text = ChatStreamPacing.text(of: step.id, newest: step.text, streaming: step.role.isThinking)
        return paced
    }

    private static func isOpened(_ step: ChatMessage) -> Bool {
        if case .thinking = step.role {
            return ChatTraceExpansion.isExpanded(thought: step.id)
        }
        return ChatTraceExpansion.isExpanded(call: step.id)
    }
}

/// One thought of a run, folded into a line: how long it thought, and — once
/// the reader opens it — what it said to itself. aimini's chat keeps a
/// thought to one line for the same reason: the process reads as what the
/// run did, and the monologue is there for whoever asks for it.
final class ChatThoughtRow: UIView {
    /// The line was tapped: the text is open now or it is not.
    @objc dynamic var onToggle: (() -> Void)?
    let stepID: UUID

    private var step: ChatMessage
    /// The line over the text. They are a stack's, so a folded thought's
    /// text takes no room at all — a hidden view of constraints would keep
    /// its height and leave the row as tall as the text it does not show.
    private let stack = UIStackView()
    private let line = UIControl()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    /// 折叠思考与当前步骤活动行共用同一种滚动文本。
    private let preview = ChatRollingLine()
    private let chevron = UIImageView()
    private let textLabel = UILabel()
    private var showsBody = false
    /// What this row was last given, without its strings.
    private var shownShape: ChatMessageShape?

    private enum Style {
        static let lineHeight: CGFloat = 28
        static let iconSize: CGFloat = 15
        static let chevronSize: CGFloat = 11
        static let spacing: CGFloat = 6
        /// Between the line and the text under it.
        static let bodySpacing: CGFloat = 6

        static var titleFont: UIFont {
            UIFontMetrics(forTextStyle: .subheadline).scaledFont(
                for: .systemFont(ofSize: 14, weight: .medium),
            )
        }

        static var bodyFont: UIFont { UIFont.preferredFont(forTextStyle: .subheadline) }
    }

    init(step: ChatMessage) {
        stepID = step.id
        self.step = step
        super.init(frame: .zero)

        line.addTarget(self, action: #selector(toggle), for: .touchUpInside)

        stack.axis = .vertical
        stack.spacing = 0
        addSubview(stack)
        stack.snp.makeConstraints { make in make.edges.equalToSuperview() }
        stack.addArrangedSubview(line)

        icon.image = UIImage(systemName: "brain.head.profile")
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .secondaryLabel
        icon.isAccessibilityElement = false
        icon.setContentHuggingPriority(.required, for: .horizontal)
        icon.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addSubview(icon)

        titleLabel.font = Style.titleFont
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        titleLabel.numberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addSubview(titleLabel)

        // After the title, while the thought is folded: the words it is
        // writing now, the newest at the trailing end.
        preview.font = Style.bodyFont
        preview.textColor = .tertiaryLabel
        preview.isHidden = true
        line.addSubview(preview)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: Style.chevronSize, weight: .semibold),
        )
        chevron.tintColor = .tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.isAccessibilityElement = false
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        line.addSubview(chevron)

        textLabel.font = Style.bodyFont
        textLabel.adjustsFontForContentSizeCategory = true
        textLabel.textColor = .secondaryLabel
        // Opened, a thought is shown whole: it is what the reader asked for.
        textLabel.numberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.isHidden = true
        stack.addArrangedSubview(textLabel)

        line.snp.makeConstraints { make in
            make.height.greaterThanOrEqualTo(Style.lineHeight)
        }
        icon.snp.makeConstraints { make in
            make.leading.centerY.equalToSuperview()
            make.size.equalTo(Style.iconSize)
        }
        chevron.snp.makeConstraints { make in
            make.trailing.centerY.equalToSuperview()
            make.size.equalTo(Style.chevronSize + 4)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.equalTo(icon.snp.trailing).offset(Style.spacing)
            make.centerY.equalToSuperview()
        }
        preview.snp.makeConstraints { make in
            make.leading.equalTo(titleLabel.snp.trailing).offset(Style.spacing)
            make.trailing.equalTo(chevron.snp.leading).offset(-Style.spacing)
            make.centerY.equalToSuperview()
            make.height.equalTo(titleLabel)
        }

        shownShape = ChatMessageShape(step)
        configure(step)
        updateChevron(animated: false)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(step:)")
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        titleLabel.font = Style.titleFont
        textLabel.font = Style.bodyFont
        preview.font = Style.bodyFont
        setNeedsLayout()
    }

    /// The same thought as it grows, or a new one.
    func show(_ step: ChatMessage) {
        let shape = ChatMessageShape(step)
        guard shape != shownShape else { return }
        shownShape = shape
        self.step = step
        configure(step)
    }

    /// The reader folded or unfolded this thought since its step last
    /// changed: the row follows that without reading the step again.
    /// Answers whether anything changed.
    @discardableResult
    func applyExpansion() -> Bool {
        // 测量视图会连续复用给别的步骤，展开状态必须读取当前步骤。
        guard ChatTraceExpansion.isExpanded(thought: step.id) != showsBody else { return false }
        configure(step)
        updateChevron(animated: false)
        return true
    }

    private func configure(_ step: ChatMessage, animated: Bool = false) {
        titleLabel.text = Self.title(for: step)
        showsBody = ChatTraceExpansion.isExpanded(thought: step.id)
        // A folded thought draws one line of it: the whole text is only put
        // into the label when it is open, or a stream copies it on every
        // token for a label nobody is looking at.
        if showsBody {
            textLabel.text = step.text
        }
        textLabel.layer.removeAllAnimations()
        textLabel.alpha = 1
        textLabel.transform = .identity
        textLabel.isHidden = !showsBody
        stack.setCustomSpacing(showsBody ? Style.bodySpacing : 0, after: line)
        if animated, showsBody, window != nil, !UIAccessibility.isReduceMotionEnabled {
            // as aimini unfolds a thought: the text fades in and settles
            textLabel.alpha = 0
            textLabel.transform = CGAffineTransform(translationX: 0, y: -6)
            UIView.animate(withDuration: 0.22, delay: 0, options: [.curveEaseOut]) {
                self.textLabel.alpha = 1
                self.textLabel.transform = .identity
            }
        }
        preview.isHidden = showsBody || step.text.isEmpty
        preview.running = step.role.isThinking
        preview.text = step.text
        updateAccessibility()
    }

    /// "Thinking…" while it thinks, then how long it thought.
    private static func title(for step: ChatMessage) -> String {
        guard case let .thinking(seconds, _) = step.role, let seconds else {
            return String(localized: "Thinking…")
        }
        return ChatMessage.workTitle(seconds: seconds, tools: 0)
    }

    private func updateChevron(animated: Bool) {
        let turn = CGAffineTransform(rotationAngle: showsBody ? .pi / 2 : 0)
        guard animated, window != nil, !UIAccessibility.isReduceMotionEnabled else {
            chevron.transform = turn
            return
        }
        UIView.animate(withDuration: 0.2) { self.chevron.transform = turn }
    }

    /// Folded, the row is one stop that opens the thought; open, the line and
    /// the text are read on their own.
    private func updateAccessibility() {
        if showsBody {
            isAccessibilityElement = false
            line.isAccessibilityElement = true
            line.accessibilityLabel = titleLabel.text
            line.accessibilityTraits = .button
            line.accessibilityCustomActions = [
                UIAccessibilityCustomAction(name: String(localized: "Collapse")) { [weak self] _ in
                    self?.toggle()
                    return true
                },
            ]
            textLabel.isAccessibilityElement = true
            textLabel.accessibilityTraits = .staticText
        } else {
            isAccessibilityElement = true
            accessibilityLabel = titleLabel.text
            accessibilityValue = preview.isHidden ? nil : preview.shownText
            accessibilityTraits = .button
            line.isAccessibilityElement = false
            textLabel.isAccessibilityElement = false
        }
    }

    override func accessibilityActivate() -> Bool {
        guard !showsBody else { return false }
        toggle()
        return true
    }

    @objc dynamic private func toggle() {
        ChatTraceExpansion.setExpanded(thought: step.id, !showsBody)
        configure(step, animated: true)
        updateChevron(animated: true)
        onToggle?()
    }
}
