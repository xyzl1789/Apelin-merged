import ApelinProtocol
import UIKit

/// 输入框上下文圆环旁的余额徽章：一个柔和的圆角胶囊底，中心只显示余额
/// 数字本身（不带币种等任何后缀），数字颜色随状态（过期橙色、正常次要
/// 色）。不再画外框弧线——椭圆环读作一只眼睛，不好看。胶囊常显：当前
/// 连接不支持查询或还没查到时显示灰色的「--」，本来支持但本次失败时
/// 显示上次缓存或「--」；只有不在线布局时才隐藏。
final class ProviderBalanceButton: UIControl {
    /// 与上下文圆环同高，宽度按金额撑开。
    static let height: CGFloat = 24
    /// 数字两侧的内边距。
    private static let padding: CGFloat = 8

    private let background = UIView()
    private let label = UILabel()
    private(set) var balance: ProviderBalance?
    var tapAction: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        background.isUserInteractionEnabled = false
        background.backgroundColor = UIColor.tertiarySystemFill
        background.layer.cornerRadius = Self.height / 2
        background.layer.cornerCurve = .continuous
        addSubview(background)

        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        label.textAlignment = .center
        label.textColor = .secondaryLabel
        label.isUserInteractionEnabled = false
        addSubview(label)

        addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Provider Balances")
        accessibilityHint = String(localized: "Opens the provider balances.")
        isHidden = true
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.minimumWidth, height: Self.height)
    }

    /// 一个数字位的最小宽度，与上下文圆环的视觉重量相近。
    static var minimumWidth: CGFloat { 30 }

    /// 按当前金额文字算出的胶囊宽度，布局时用。
    func preferredWidth() -> CGFloat {
        guard let balance else { return Self.minimumWidth }
        let text = Self.amountText(balance) as NSString
        let size = text.size(withAttributes: [.font: label.font as Any])
        return max(Self.minimumWidth, ceil(size.width) + Self.padding * 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        background.frame = bounds
        label.frame = bounds.insetBy(dx: Self.padding, dy: 0)
    }

    func set(_ balance: ProviderBalance?) {
        self.balance = balance
        // 常显：只要控件在布局里就显示，查询不到时显示灰色的「--」，
        // 不再整块消失。
        isHidden = false
        guard let balance else {
            tintColor = .tertiaryLabel
            label.textColor = .tertiaryLabel
            label.text = "--"
            invalidateIntrinsicContentSize()
            setNeedsLayout()
            accessibilityValue = String(localized: "Balance unavailable")
            return
        }
        let color: UIColor = balance.stale ? .systemOrange : .secondaryLabel
        label.textColor = color
        tintColor = color
        label.text = Self.amountText(balance)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        accessibilityValue = Self.spoken(balance)
    }

    /// 徽章只显示数字本身：不带币种、不带单位、不带百分号。金额类照原样，
    /// token 类压成短单位（如 80.9M），完整数字留给详情页。
    static func amountText(_ balance: ProviderBalance) -> String {
        guard balance.currency == "tokens" else { return balance.amount }
        return shortTokens(balance.amount)
    }

    /// 把 token 数压成紧凑显示：1034 → 1.0K，80852458 → 80.9M，
    /// 12.3M → 12.3M，负值或非数字照原样返回，不让徽章画出假数字。
    private static func shortTokens(_ text: String) -> String {
        guard let value = Double(text), value.isFinite else { return text }
        let sign = value < 0 ? "-" : ""
        let magnitude = abs(value)
        let units: [(Double, String)] = [(1e9, "B"), (1e6, "M"), (1e3, "K")]
        for (scale, suffix) in units where magnitude >= scale {
            let scaled = magnitude / scale
            // 小于 100 留一位小数（80.9M、12.3M），再大就不拖小数（100M）。
            let digits = scaled < 100 ? 1 : 0
            return "\(sign)\(String(format: "%.\(digits)f", scaled))\(suffix)"
        }
        return "\(sign)\(Int(magnitude))"
    }

    private static func spoken(_ balance: ProviderBalance) -> String {
        let figure = amountText(balance)
        return balance.stale ? "\(figure)，\(balance.problem ?? String(localized: "Balance unavailable"))" : figure
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
