import UIKit

/// VariableBlur's alpha-mask CAFilter approach, on a backdrop UIKit does not reconfigure.
/// Reference: https://github.com/nikstar/VariableBlur
final class ChatTopBlurView: UIView {
    private final class BackdropView: UIView {
        override class var layerClass: AnyClass {
            NSClassFromString("CABackdropLayer") ?? CALayer.self
        }
    }

    // 底色画在普通图层上，首次进窗口时不依赖背景模糊层完成合成。
    private let backdrop = BackdropView()

    /// Conversation 画在哪张底上，顶部模糊取它的颜色：纸用自己的底色，读者
    /// 的图片用顶部一条的颜色，没有则用应用原本的背景。
    var background: ChatBackground = .none {
        didSet { updateFrost() }
    }

    private let frost = CAGradientLayer()
    private var material: UIVisualEffectView?
    private var materialMask: CAGradientLayer?
    /// 盖在 material 之上、向下淡出的本页颜色：单靠系统的磨砂在亮图片上
    /// 仍是透明的，这一层让顶栏读作页面的磨砂边缘，而不是看穿它的窗口。
    private var veil: TintVeil?

    private func installStandardBlur() {
        let blur = UIVisualEffectView(effect: UIBlurEffect(style: .systemThickMaterial))
        blur.isUserInteractionEnabled = false
        blur.isAccessibilityElement = false
        let mask = CAGradientLayer()
        mask.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        mask.locations = [0, 1]
        blur.layer.mask = mask
        material = blur
        materialMask = mask
        addSubview(blur)
        let veil = TintVeil()
        veil.isUserInteractionEnabled = false
        veil.isAccessibilityElement = false
        veil.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(veil)
        self.veil = veil
        updateFrost()
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        frost.locations = [0, 1]
        defer {
            // 底色仍在普通图层上，保留冷启动首帧的修复。
            layer.addSublayer(frost)
            updateFrost()
        }
        guard #available(iOS 26, *),
              let backdropClass = NSClassFromString("CABackdropLayer"),
              backdrop.layer.isKind(of: backdropClass),
              let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
              let filter = filterClass.perform(
                  NSSelectorFromString("filterWithType:"),
                  with: "variableBlur",
              )?.takeUnretainedValue() as? NSObject
        else {
            installStandardBlur()
            return
        }
        addSubview(backdrop)

        let gradient = CAGradientLayer()
        gradient.frame = CGRect(x: 0, y: 0, width: 2, height: 128)
        gradient.colors = [UIColor.black.cgColor, UIColor.clear.cgColor]
        gradient.locations = frost.locations
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let mask = UIGraphicsImageRenderer(size: gradient.bounds.size, format: format)
            .image { gradient.render(in: $0.cgContext) }
        filter.setValue(5.0, forKey: "inputRadius")
        filter.setValue(mask.cgImage, forKey: "inputMaskImage")
        filter.setValue(true, forKey: "inputNormalizeEdges")
        backdrop.layer.filters = [filter]
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        backdrop.frame = bounds
        material?.frame = bounds
        materialMask?.frame = material?.bounds ?? .zero
        veil?.frame = bounds
        frost.frame = bounds
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        updateFrost()
    }

    @objc dynamic private func updateFrost() {
        let color: UIColor?
        switch background {
        case .none:
            color = UIColor.pageBackground.resolvedColor(with: traitCollection)
        case let .paper(paper):
            color = ChatBackgroundView.base(paper, traits: traitCollection)
                .resolvedColor(with: traitCollection)
        case .image:
            // 顶部取色尚不可用时退回整张图片的颜色，不让顶栏只剩系统的白色磨砂。
            color = ChatBackgroundView.topTint() ?? ChatBackgroundView.pictureTint()
        }
        if material != nil {
            // 保留默认背景的渐隐磨砂和冷启动底色；页面颜色只在导航栏底边淡出。
            frost.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor]
            veil?.gradient.locations = [0, 0.7, 1]
            veil?.gradient.colors = color.map {
                [
                    $0.cgColor,
                    $0.withAlphaComponent(0.85).cgColor,
                    $0.withAlphaComponent(0).cgColor,
                ]
            } ?? [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
            return
        }
        frost.colors = color.map {
            [$0.cgColor, $0.withAlphaComponent(0).cgColor]
        } ?? [UIColor.clear.cgColor, UIColor.clear.cgColor]
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let window, let backdropClass = NSClassFromString("CABackdropLayer"),
              backdrop.layer.isKind(of: backdropClass) else { return }
        backdrop.layer.setValue(window.traitCollection.displayScale, forKey: "scale")
    }
}

/// 图层就是渐变本身的视图：它在磨砂之上，向下淡出。
private final class TintVeil: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    var gradient: CAGradientLayer { layer as! CAGradientLayer }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        gradient.locations = [0, 1]
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }
}
