// Lakr233's Inhouse Code, from FlowDown.
// I CAN DO WHAT THE FUCK I WANT.

import UIKit

/// 图标和标题共用输入框同款磨砂底，图片背景下也能辨认。
final class ComposerGiantButton: UIButton {
    private let iconView = UIImageView()
    private let backgroundView = UIVisualEffectView()
    private let labelView = UILabel()
    @objc dynamic var actionBlock: () -> Void = {}

    init(title: String, icon: String) {
        super.init(frame: .zero)
        if #available(iOS 26, *) {
            backgroundView.effect = UIGlassEffect()
        } else {
            backgroundView.effect = UIBlurEffect(style: .systemThinMaterial)
        }
        backgroundView.clipsToBounds = true
        backgroundView.layer.cornerRadius = 16
        backgroundView.layer.cornerCurve = .continuous
        backgroundView.isUserInteractionEnabled = false
        addSubview(backgroundView)
        iconView.contentMode = .scaleAspectFit
        iconView.tintColor = .label.withAlphaComponent(0.75)
        iconView.image = UIImage(named: icon)?.withRenderingMode(.alwaysTemplate)
        backgroundView.contentView.addSubview(iconView)
        labelView.text = title
        labelView.textAlignment = .center
        labelView.font = .preferredFont(forTextStyle: .footnote)
        labelView.adjustsFontForContentSizeCategory = true
        labelView.adjustsFontSizeToFitWidth = true
        labelView.minimumScaleFactor = 0.7
        labelView.textColor = .secondaryLabel
        backgroundView.contentView.addSubview(labelView)
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title
        addTarget(self, action: #selector(onTapped), for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(title:icon:)")
    }

    @objc dynamic private func onTapped() {
        actionBlock()
    }

    override var isHighlighted: Bool {
        didSet {
            backgroundView.contentView.alpha = isHighlighted ? 0.4 : 1
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        backgroundView.frame = bounds
        // 标题现在也在磨砂上；图标使用标题上方剩余的空间。
        let labelHeight = max(32, labelView.font.lineHeight + 12)
        let iconArea = max(0, bounds.height - labelHeight)
        iconView.frame = CGRect(
            x: (bounds.width - 28) / 2,
            y: (iconArea - 28) / 2,
            width: 28,
            height: 28,
        )
        labelView.frame = CGRect(
            x: 8,
            y: iconArea,
            width: max(0, bounds.width - 16),
            height: min(labelHeight, bounds.height),
        )
    }
}
