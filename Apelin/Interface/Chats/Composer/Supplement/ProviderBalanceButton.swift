import ApelinProtocol
import UIKit

/// 输入框上下文圆环旁的余额徽章：一个柔和的圆角胶囊底，中心只显示余额
/// 数字本身（不带币种等任何后缀），数字颜色随状态（过期橙色、正常次要
/// 色）。不再画外框弧线——椭圆环读作一只眼睛，不好看。确定无法查询的
/// 连接根本不会把数据交给它，也就连占位都不显示；本来支持但本次失败时
/// 保留胶囊并显示上次缓存或「--」。
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
        // 有查到的余额就显示（哪怕不是当前供应商的）；只有全都查不到时
        // 才隐藏，与第一版行为一致。
        isHidden = balance == nil
        guard let balance else { return }
        let color: UIColor = balance.stale ? .systemOrange : .secondaryLabel
        label.textColor = color
        tintColor = color
        label.text = Self.amountText(balance)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        accessibilityValue = Self.spoken(balance)
    }

    /// 只显示余额数字本身：不带币种、不带单位、不带百分号。
    static func amountText(_ balance: ProviderBalance) -> String {
        balance.amount
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
