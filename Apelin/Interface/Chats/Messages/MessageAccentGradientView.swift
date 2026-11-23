import UIKit

/// 读者气泡的底色，图片相册也共用它。
///
/// 渐变是视图自己的 layer，所以跟随 view 的 frame，和 UIKit 移动视图的时机
/// 一致：动画块外立即跟随，自身从不单独动。一个独立 sublayer 会在每次 frame
/// 变化时隐式动画，从重用池里取出的行会把上一条消息留下的底色滑动过来。
///
/// 底色正是 `ChatBubbleStyle`：五种淡染，其中一种跟着应用着色走。样式在绘制
/// 时读取，选取另一种时再读一次，于是聊天不必重建就能改变。
final class MessageAccentGradientView: UIView {
    override class var layerClass: AnyClass {
        CAGradientLayer.self
    }

    @objc dynamic private var gradient: CAGradientLayer {
        layer as! CAGradientLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        gradient.startPoint = CGPoint(x: 0.6, y: 0)
        gradient.endPoint = CGPoint(x: 0.4, y: 1)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(stylingChanged),
            name: ChatBubbleStyle.changed,
            object: nil,
        )
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func tintColorDidChange() {
        super.tintColorDidChange()
        updateColors()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateColors()
    }

    @objc dynamic var showsConversationBorder = false {
        didSet { updateColors() }
    }

    @objc private func stylingChanged() {
        updateColors()
    }

    @objc dynamic private func updateColors() {
        let skin = ChatBubbleStyle.current.colours(
            dark: traitCollection.userInterfaceStyle == .dark,
            accent: tintColor.resolvedColor(with: traitCollection),
            custom: ChatBubbleStyle.customColor,
        )
        gradient.colors = skin.fill.map(\.cgColor)
        // 来自其他渠道的消息保留绿边，不论底色是什么：边说的是消息从哪里来。
        if showsConversationBorder {
            layer.borderWidth = 1.5
            layer.borderColor = UIColor.systemGreen.resolvedColor(with: traitCollection).cgColor
        } else {
            layer.borderWidth = skin.width
            layer.borderColor = skin.border?.cgColor
        }
    }
}
