import UIKit

/// 聊天页输入框上方的紧凑上下文占用条，样式对齐 TrollAgent 的
/// `ContextUsageBar`：左侧「上下文占用」，右侧「已用 / 窗口」（K 缩写），
/// 下方一条胶囊进度条，按占用分级着色（≥75% 橙、≥90% 红）。
/// 点击打开会话用量详情。还没有用量时不显示。
final class ContextUsageBarView: UIControl {
    private let titleLabel = UILabel()
    private let valueLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()

    /// 点击时询问，无论条上画着什么。
    var tapAction: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        backgroundColor = .secondarySystemGroupedBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        titleLabel.text = String(localized: "上下文占用")
        titleLabel.font = .preferredFont(forTextStyle: .caption1)
        titleLabel.textColor = .label
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.isUserInteractionEnabled = false
        addSubview(titleLabel)

        valueLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabel
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.minimumScaleFactor = 0.8
        valueLabel.isUserInteractionEnabled = false
        addSubview(valueLabel)

        track.backgroundColor = .systemGray5
        track.layer.cornerRadius = 3
        track.layer.cornerCurve = .continuous
        track.clipsToBounds = true
        track.isUserInteractionEnabled = false
        addSubview(track)
        addSubview(fill)

        addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "上下文占用")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 52)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let inset: CGFloat = 12
        let width = bounds.width - inset * 2
        titleLabel.frame = CGRect(x: inset, y: 8, width: width * 0.5, height: 16)
        valueLabel.frame = CGRect(x: inset + width * 0.5, y: 8, width: width * 0.5, height: 16)
        valueLabel.textAlignment = .right
        track.frame = CGRect(x: inset, y: bounds.height - 16, width: width, height: 6)
        fill.frame = CGRect(x: 0, y: 0, width: track.bounds.width * lastFraction, height: 6)
    }

    private var lastFraction: CGFloat = 0

    /// 已用与窗口 token 数；窗口为 0 时按没有用量处理。
    func set(usedTokens: Int, windowTokens: Int) {
        let hasFigure = windowTokens > 0 || usedTokens > 0
        isHidden = !hasFigure
        guard hasFigure else { return }
        let fraction = windowTokens > 0
            ? min(1, max(0, Double(usedTokens) / Double(windowTokens)))
            : 0
        let levelColor: UIColor = switch fraction {
        case 0.9...: .systemRed
        case 0.75...: .systemOrange
        default: .systemBlue
        }
        valueLabel.textColor = fraction > 0.75 ? levelColor : .secondaryLabel
        valueLabel.text = String(
            localized: "\(Self.kText(usedTokens)) / \(windowTokens > 0 ? Self.kText(windowTokens) : "—")"
        )
        accessibilityValue = String(localized: "已使用 \(Self.kText(usedTokens))，窗口 \(Self.kText(windowTokens))，占 \(Int(fraction * 100))%")
        lastFraction = CGFloat(fraction)
        fill.backgroundColor = levelColor
        fill.frame.size.width = track.bounds.width * lastFraction
    }

    /// K 缩写，与 TrollAgent 的 `\(tokens / 1000)K` 同口径。
    private static func kText(_ tokens: Int) -> String {
        "\(tokens / 1000)K"
    }

    @objc private func tapped() {
        guard !isHidden, !isTrackingTap else { return }
        isTrackingTap = true
        DispatchQueue.main.async { [weak self] in self?.isTrackingTap = false }
        tapAction()
    }

    private var isTrackingTap = false

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.4 : 1 }
    }

    override func accessibilityActivate() -> Bool {
        guard !isHidden else { return false }
        tapAction()
        return true
    }
}
