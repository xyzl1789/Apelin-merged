import UIKit

/// 当前活动行：工具图标、调用原因及独立计数，或正在生成的滚动思考。
final class ToolCallBannerView: UIView {
    typealias Content = ToolCallBanner.ActivityLine

    static let height: CGFloat = 32
    static let iconSize: CGFloat = 15
    private static let iconSpacing: CGFloat = 8
    private static let figuresSpacing: CGFloat = 8

    private let icon = UIImageView()
    private let reasonLabel = UILabel()
    private let figuresLabel = UILabel()
    private let thought = ChatRollingLine()
    private let ground = UIView()
    private let topRule = UIView()
    private let bottomRule = UIView()
    private var shownContent: Content?

    @objc dynamic var groundBleed = UIEdgeInsets.zero {
        didSet {
            if groundBleed != oldValue { setNeedsLayout() }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        ground.backgroundColor = UIColor.systemGray.withAlphaComponent(0.05)
        addSubview(ground)
        for rule in [topRule, bottomRule] {
            rule.backgroundColor = .separator
            ground.addSubview(rule)
        }
        icon.contentMode = .scaleAspectFit
        icon.tintColor = .secondaryLabel
        icon.isAccessibilityElement = false
        addSubview(icon)
        reasonLabel.numberOfLines = 1
        reasonLabel.lineBreakMode = .byTruncatingTail
        addSubview(reasonLabel)
        figuresLabel.numberOfLines = 1
        figuresLabel.setContentHuggingPriority(.required, for: .horizontal)
        figuresLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(figuresLabel)
        thought.font = .preferredFont(forTextStyle: .footnote)
        thought.textColor = .secondaryLabel
        thought.isHidden = true
        addSubview(thought)
        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    func show(_ content: Content, animated: Bool) {
        guard content != shownContent else { return }
        let previous = shownContent
        shownContent = content
        reasonLabel.layer.removeAllAnimations()
        reasonLabel.font = .preferredFont(forTextStyle: .footnote)
        figuresLabel.font = .monospacedDigitSystemFont(ofSize: reasonLabel.font.pointSize, weight: .medium)
        switch content {
        case let .call(banner, _):
            thought.isHidden = true
            thought.text = nil
            reasonLabel.isHidden = false
            icon.image = UIImage(systemName: ToolSymbol.name(for: banner.tool))
            reasonLabel.attributedText = Self.reasonLine(banner.reason, font: reasonLabel.font)
            let figures = Self.figuresLine(banner.change, font: figuresLabel.font)
            figuresLabel.attributedText = figures
            figuresLabel.isHidden = figures == nil
            accessibilityLabel = banner.reason
            accessibilityValue = Self.spokenCounts(banner.change)
        case let .thought(text):
            reasonLabel.isHidden = true
            reasonLabel.attributedText = nil
            figuresLabel.isHidden = true
            figuresLabel.attributedText = nil
            thought.isHidden = false
            thought.running = true
            thought.text = text
            icon.image = UIImage(systemName: "brain.head.profile")
            accessibilityLabel = String(localized: "Thoughts")
            accessibilityValue = thought.shownText
        }
        setNeedsLayout()
        guard animated, previous != nil, window != nil,
              !UIAccessibility.isReduceMotionEnabled else { return }
        let fadeIn = CATransition()
        fadeIn.type = .fade
        fadeIn.duration = 0.2
        let changing: UIView = thought.isHidden ? reasonLabel : thought
        changing.layer.add(fadeIn, forKey: "content")
    }

    @objc dynamic func reset() {
        shownContent = nil
        reasonLabel.layer.removeAllAnimations()
        reasonLabel.attributedText = nil
        reasonLabel.isHidden = false
        figuresLabel.attributedText = nil
        figuresLabel.isHidden = true
        thought.text = nil
        thought.isHidden = true
        icon.image = nil
        accessibilityLabel = nil
        accessibilityValue = nil
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let rule = 1 / max(traitCollection.displayScale, 1)
        ground.frame = bounds.inset(
            by: UIEdgeInsets(top: 0, left: -groundBleed.left, bottom: 0, right: -groundBleed.right),
        )
        topRule.frame = CGRect(x: 0, y: 0, width: ground.bounds.width, height: rule)
        bottomRule.frame = CGRect(x: 0, y: ground.bounds.height - rule, width: ground.bounds.width, height: rule)

        let padding = ChatMessageRow.horizontalPadding
        let rightToLeft = effectiveUserInterfaceLayoutDirection == .rightToLeft
        icon.frame = CGRect(
            x: rightToLeft ? bounds.width - padding - Self.iconSize : padding,
            y: ((bounds.height - Self.iconSize) / 2).rounded(),
            width: Self.iconSize,
            height: Self.iconSize,
        )
        let textStart = padding + Self.iconSize + Self.iconSpacing
        let textWidth = max(1, bounds.width - textStart - padding)
        let textArea = CGRect(x: rightToLeft ? padding : textStart, y: 0, width: textWidth, height: bounds.height)
        let figuresWidth = figuresLabel.isHidden ? 0 : ceil(figuresLabel.intrinsicContentSize.width)
        let gap = figuresWidth > 0 ? Self.figuresSpacing : 0
        let reasonsWidth = max(1, textArea.width - figuresWidth - gap)
        if rightToLeft {
            figuresLabel.frame = CGRect(x: textArea.minX, y: 0, width: figuresWidth, height: textArea.height)
            reasonLabel.frame = CGRect(
                x: textArea.minX + figuresWidth + gap, y: 0, width: reasonsWidth, height: textArea.height,
            )
        } else {
            figuresLabel.frame = CGRect(
                x: textArea.maxX - figuresWidth, y: 0, width: figuresWidth, height: textArea.height,
            )
            reasonLabel.frame = CGRect(x: textArea.minX, y: 0, width: reasonsWidth, height: textArea.height)
        }
        let line = thought.lineHeight
        thought.frame = CGRect(x: textArea.minX, y: ((bounds.height - line) / 2).rounded(), width: textArea.width, height: line)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.preferredContentSizeCategory != traitCollection.preferredContentSizeCategory else { return }
        thought.font = .preferredFont(forTextStyle: .footnote)
        if case let .call(banner, _)? = shownContent {
            reasonLabel.font = .preferredFont(forTextStyle: .footnote)
            figuresLabel.font = .monospacedDigitSystemFont(ofSize: reasonLabel.font.pointSize, weight: .medium)
            reasonLabel.attributedText = Self.reasonLine(banner.reason, font: reasonLabel.font)
            figuresLabel.attributedText = Self.figuresLine(banner.change, font: figuresLabel.font)
        }
        setNeedsLayout()
    }

    private static func reasonLine(_ reason: String, font: UIFont) -> NSAttributedString {
        let line = reason.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return NSAttributedString(string: line, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
    }

    private static func figuresLine(_ change: ToolCallBanner.LineChange?, font: UIFont) -> NSAttributedString? {
        guard let change else { return nil }
        let figures = NSMutableAttributedString()
        figures.append(NSAttributedString(
            string: "+\(change.added)",
            attributes: [.font: font, .foregroundColor: UIColor.systemGreen],
        ))
        figures.append(NSAttributedString(
            string: " −\(change.removed)",
            attributes: [.font: font, .foregroundColor: UIColor.systemRed],
        ))
        return figures
    }

    private static func spokenCounts(_ change: ToolCallBanner.LineChange?) -> String? {
        guard let change else { return nil }
        let added = change.added == 1
            ? String(localized: "1 line added")
            : String(localized: "\(change.added) lines added")
        let removed = change.removed == 1
            ? String(localized: "1 line removed")
            : String(localized: "\(change.removed) lines removed")
        return ListFormatter.localizedString(byJoining: [added, removed])
    }
}
