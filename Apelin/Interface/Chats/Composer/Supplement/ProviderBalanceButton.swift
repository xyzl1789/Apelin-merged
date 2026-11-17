import ApelinProtocol
import UIKit

/// 输入框上下文圆环旁的同款圆环：中心显示实际余额（带币种/单位），
/// 弧长按「剩余/额度」百分比绘制。确定无法查询的连接根本不会把数据
/// 交给它，也就连占位都不显示；本来支持但本次失败时保留圆环并显示
/// 上次缓存或「--」。
final class ProviderBalanceButton: UIControl {
    static let size: CGFloat = 24

    private let ring = ProgressRing()
    private let label = UILabel()
    private(set) var balance: ProviderBalance?
    var tapAction: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        ring.isUserInteractionEnabled = false
        addSubview(ring)
        label.font = .monospacedDigitSystemFont(ofSize: 9, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.5
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
        CGSize(width: Self.size, height: Self.size)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        label.frame = bounds.insetBy(dx: 1, dy: 1)
    }

    func set(_ balance: ProviderBalance?) {
        let hadFigure = self.balance != nil
        self.balance = balance
        isHidden = balance == nil
        guard let balance else { return }
        tintColor = balance.stale ? .systemOrange : .secondaryLabel
        label.textColor = tintColor
        label.text = Self.amountText(balance)
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
