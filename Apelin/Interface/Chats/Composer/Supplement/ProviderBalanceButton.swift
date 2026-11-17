import ApelinProtocol
import UIKit

/// 输入框上下文圆环旁的同款圆环：中心显示实际余额（带币种/单位），
/// 弧长按「剩余/额度」百分比绘制。确定无法查询的连接根本不会把数据
/// 交给它，也就连占位都不显示；本来支持但本次失败时保留圆环并显示
/// 上次缓存或「--」。
final class ProviderBalanceButton: UIControl {
    /// 与上下文圆环同高，宽度按金额撑开，读作一个椭圆环。
    static let height: CGFloat = 24
    /// 文字两侧的内边距：环贴着文字画。
    private static let padding: CGFloat = 3

    private let ring = ProgressRing()
    private let label = UILabel()
    private(set) var balance: ProviderBalance?
    var tapAction: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        ring.isUserInteractionEnabled = false
        addSubview(ring)
        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.textAlignment = .center
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

    /// 金额文字占位前的最小宽度，与上下文圆环的视觉重量相近。
    static var minimumWidth: CGFloat { height }

    /// 按当前金额文字算出的椭圆宽度，布局时用。
    func preferredWidth() -> CGFloat {
        guard let balance else { return Self.minimumWidth }
        let text = Self.amountText(balance) as NSString
        let size = text.size(
            withAttributes: [.font: label.font as Any],
        )
        return max(Self.minimumWidth, ceil(size.width) + Self.padding * 2 + 2)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        label.frame = bounds.insetBy(dx: Self.padding, dy: 0)
    }

    func set(_ balance: ProviderBalance?) {
        let hadFigure = self.balance != nil
        self.balance = balance
        // 有查到的余额就显示（哪怕不是当前供应商的）；只有全都查不到时
        // 才隐藏，与第一版行为一致。
        isHidden = balance == nil
        guard let balance else { return }
        tintColor = balance.stale ? .systemOrange : .secondaryLabel
        label.textColor = tintColor
        label.text = Self.amountText(balance)
        invalidateIntrinsicContentSize()
        setNeedsLayout()
        accessibilityValue = Self.spoken(balance)
        ring.set(.progress(balance.fraction ?? 1), animated: hadFigure)
    }

    /// 实际金额，不是百分比：币种跟在数字后，单位过长就只留数字。
    static func amountText(_ balance: ProviderBalance) -> String {
        let amount = balance.amount
        guard !balance.currency.isEmpty else { return amount }
        return amount + balance.currency
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
