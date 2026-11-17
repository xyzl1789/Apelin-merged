import ApelinProtocol
import UIKit

/// 输入框上下文圆环旁的小胶囊：显示当前模型供应商的实际余额（带币种）。
/// 高度与上下文圆环一致，宽度足以写下金额，纯文字、不画进度、不显示百分比；
/// 查不到余额时常显一条「没有可显示的余额」占位，而不是整个控件消失。
final class ProviderBalanceButton: UIControl {
    /// 与上下文圆环同高，保持一行对齐。
    static let height: CGFloat = 24
    /// 比圆环宽，容纳金额文字。
    static let width: CGFloat = 60

    private let label = UILabel()
    private(set) var balance: ProviderBalance?
    var tapAction: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false

        label.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.isUserInteractionEnabled = false
        addSubview(label)

        addTarget(self, action: #selector(tapped), for: .primaryActionTriggered)
        addTarget(self, action: #selector(tapped), for: .touchUpInside)

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = String(localized: "Provider Balances")
        accessibilityHint = String(localized: "Opens the provider balances.")
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: Self.width, height: Self.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
        label.frame = bounds.insetBy(dx: 4, dy: 1)
    }

    func set(_ balance: ProviderBalance?) {
        self.balance = balance
        // 常显：查不到余额时也留着占位，让读者知道这一栏在、只是没查到，
        // 而不是整个控件消失让人以为功能坏了。
        isHidden = false
        guard let balance else {
            backgroundColor = .clear
            label.textColor = .tertiaryLabel
            label.text = String(localized: "No balance to show")
            accessibilityValue = String(localized: "No balance to show")
            return
        }
        backgroundColor = balance.stale
            ? UIColor.systemOrange.withAlphaComponent(0.14)
            : UIColor.secondarySystemFill
        label.textColor = balance.stale ? .systemOrange : .secondaryLabel
        label.text = Self.amountText(balance)
        accessibilityValue = Self.spoken(balance)
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
