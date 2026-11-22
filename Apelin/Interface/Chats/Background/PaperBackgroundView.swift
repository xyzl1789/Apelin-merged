import UIKit

/// 应用画在聊天背后的一张纸：暖色底、向内变暗的边和纸的纤维，全部由代码
/// 画出来，不附带任何图片。
final class PaperBackgroundView: UIView {
    /// 画哪一张纸。
    var paper: ChatBackground.Paper = .rice {
        didSet {
            applyStyle()
            setNeedsLayout()
        }
    }

    /// 横线和圆点的间距，相对整页：设置页 44 pt 的预览画得密一些，能显示多个。
    var scale: CGFloat = 1 {
        didSet { setNeedsLayout() }
    }

    private let base = CAGradientLayer()
    private let vignette = CAGradientLayer()
    private let pattern = CAShapeLayer()
    private let grain = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear

        // 底色：三个色标，从左上受光、向右下变暗，像窗下的纸。
        base.startPoint = CGPoint(x: 0.10, y: 0)
        base.endPoint = CGPoint(x: 0.85, y: 1)
        base.locations = [0, 0.48, 1]
        layer.addSublayer(base)

        // 画的横线、格子和圆点：在底色之上、边之下。
        pattern.fillColor = UIColor.clear.cgColor
        layer.addSublayer(pattern)

        // 边：中间透明，边缘变深。
        vignette.type = .radial
        vignette.colors = [UIColor.clear.cgColor, UIColor.clear.cgColor, UIColor.clear.cgColor]
        vignette.locations = [0.28, 0.70, 1]
        vignette.startPoint = CGPoint(x: 0.5, y: 0.44)
        vignette.endPoint = CGPoint(x: 1.05, y: 1.05)
        layer.addSublayer(vignette)

        // 纤维：一像素的噪点小块，铺满整页。
        grain.backgroundColor = UIColor(patternImage: Self.grainTexture)
        grain.isUserInteractionEnabled = false
        grain.isAccessibilityElement = false
        addSubview(grain)

        applyStyle()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        vignette.frame = bounds
        pattern.frame = bounds
        grain.frame = bounds
        pattern.path = drawnPattern()
        CATransaction.commit()
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle {
            applyStyle()
        }
    }

    /// 纸印在哪一种底色上，供需要淡入它的视图（聊天顶部的模糊）使用。
    static func base(_ paper: ChatBackground.Paper, traits: UITraitCollection) -> UIColor {
        paper.design(dark: traits.userInterfaceStyle == .dark).base[1]
    }

    private func applyStyle() {
        let design = paper.design(dark: traitCollection.userInterfaceStyle == .dark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.colors = design.base.map(\.cgColor)
        vignette.colors = design.edge.map(\.cgColor)
        grain.alpha = design.grain
        if paper.pattern == .dots {
            pattern.fillColor = design.ink.cgColor
            pattern.strokeColor = UIColor.clear.cgColor
        } else {
            pattern.fillColor = UIColor.clear.cgColor
            pattern.strokeColor = design.ink.cgColor
            pattern.lineWidth = 1 / max(traitCollection.displayScale, 1)
        }
        CATransaction.commit()
    }

    private func drawnPattern() -> CGPath? {
        let path = CGMutablePath()
        switch paper.pattern {
        case .none:
            return nil
        case .ruled:
            let spacing = 30 * scale
            var y = spacing
            while y < bounds.maxY {
                path.move(to: CGPoint(x: bounds.minX, y: y))
                path.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += spacing
            }
        case .grid:
            let spacing = 24 * scale
            var x = spacing
            while x < bounds.maxX {
                path.move(to: CGPoint(x: x, y: bounds.minY))
                path.addLine(to: CGPoint(x: x, y: bounds.maxY))
                x += spacing
            }
            var y = spacing
            while y < bounds.maxY {
                path.move(to: CGPoint(x: bounds.minX, y: y))
                path.addLine(to: CGPoint(x: bounds.maxX, y: y))
                y += spacing
            }
        case .dots:
            let spacing = 18 * scale
            let radius = max(1.2 * scale, 0.7)
            var y = spacing
            while y < bounds.maxY {
                var x = spacing
                while x < bounds.maxX {
                    path.addEllipse(in: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2))
                    x += spacing
                }
                y += spacing
            }
        }
        return path
    }

    /// 只画一块：一像素的点在 scale 1 上，三倍屏会把它看成纤维而不是颗粒。
    private static let grainTexture: UIImage = {
        let side = 96
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = false
        format.scale = 1
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side),
            format: format,
        ).image { context in
            let cg = context.cgContext
            var random = SplitMix64(seed: 0x7061_7065_7200_0001)
            for y in 0 ..< side {
                for x in 0 ..< side {
                    let value = CGFloat(random.next() % 1_000) / 1_000
                    cg.setFillColor(UIColor(white: value, alpha: 1).cgColor)
                    cg.fill(CGRect(x: x, y: y, width: 1, height: 1))
                }
            }
        }
    }()
}

// MARK: - 每张纸的构成

extension ChatBackground.Paper {
    /// 一张纸在底色上画的纹路，没有就不画。
    enum Pattern {
        case none
        case ruled
        case grid
        case dots
    }

    var pattern: Pattern {
        switch self {
        case .rice, .ivory, .kraft, .slate: .none
        case .ruled: .ruled
        case .grid: .grid
        case .dots: .dots
        }
    }

    /// 一张纸在一种外观下的底色、边、纤维和墨色。
    /// 纸在深色下有它自己的颜色，不是把浅色调暗：深色下聊天文字是白色的。
    struct Design {
        let base: [UIColor]
        let edge: [UIColor]
        let ink: UIColor
        let grain: CGFloat
    }

    func design(dark: Bool) -> Design {
        let ink = Self.ink
        switch self {
        case .rice:
            return Design(
                base: dark
                    ? [Self.rgb(0x1C1B18), Self.rgb(0x171613), Self.rgb(0x201E1A)]
                    : [Self.rgb(0xF6F1E7), Self.rgb(0xEDE5D7), Self.rgb(0xF8F4EC)],
                edge: dark
                    ? [.clear, UIColor(white: 0, alpha: 0.12), UIColor(white: 0, alpha: 0.36)]
                    : [.clear, Self.rgb(0x1A1917, alpha: 0.05), Self.rgb(0x1A1917, alpha: 0.13)],
                ink: ink,
                grain: dark ? 0.05 : 0.075,
            )
        case .ivory:
            return Design(
                base: dark
                    ? [Self.rgb(0x1A1A1C), Self.rgb(0x151517), Self.rgb(0x1E1E21)]
                    : [Self.rgb(0xFBFAF6), Self.rgb(0xF2F0E9), Self.rgb(0xFDFCFA)],
                edge: dark
                    ? [.clear, UIColor(white: 0, alpha: 0.12), UIColor(white: 0, alpha: 0.34)]
                    : [.clear, Self.rgb(0x14161A, alpha: 0.04), Self.rgb(0x14161A, alpha: 0.10)],
                ink: ink,
                grain: dark ? 0.04 : 0.05,
            )
        case .kraft:
            return Design(
                base: dark
                    ? [Self.rgb(0x2A241C), Self.rgb(0x221D16), Self.rgb(0x2E2820)]
                    : [Self.rgb(0xE7D8BE), Self.rgb(0xD9C6A6), Self.rgb(0xEEDFC8)],
                edge: dark
                    ? [.clear, UIColor(white: 0, alpha: 0.14), UIColor(white: 0, alpha: 0.40)]
                    : [.clear, Self.rgb(0x3A2C1A, alpha: 0.06), Self.rgb(0x3A2C1A, alpha: 0.16)],
                ink: ink,
                grain: dark ? 0.09 : 0.13,
            )
        case .slate:
            return Design(
                base: dark
                    ? [Self.rgb(0x191C20), Self.rgb(0x14171A), Self.rgb(0x1D2126)]
                    : [Self.rgb(0xE9EDF0), Self.rgb(0xDCE3E8), Self.rgb(0xEEF2F5)],
                edge: dark
                    ? [.clear, UIColor(white: 0, alpha: 0.12), UIColor(white: 0, alpha: 0.36)]
                    : [.clear, Self.rgb(0x1B2530, alpha: 0.04), Self.rgb(0x1B2530, alpha: 0.11)],
                ink: ink,
                grain: dark ? 0.04 : 0.05,
            )
        case .ruled, .grid, .dots:
            var design = ChatBackground.Paper.rice.design(dark: dark)
            design = Design(
                base: design.base,
                edge: design.edge,
                ink: dark ? UIColor(white: 1, alpha: 0.10) : Self.rgb(0x1A1917, alpha: 0.10),
                grain: design.grain,
            )
            return design
        }
    }

    private static var ink: UIColor { rgb(0x1A1917) }

    private static func rgb(_ value: UInt32, alpha: CGFloat = 1) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha,
        )
    }
}

/// 固定的数列：每次启动时纤维都一样，页面不会在读者正在读的时候移动。
struct SplitMix64 {
    var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
