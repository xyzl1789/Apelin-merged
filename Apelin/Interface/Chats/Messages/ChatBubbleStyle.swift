import UIKit

/// 读者自己消息的底色。回复永远不画在这上面：回复留在纸面上，聊天正是靠
/// 这层对比来读的。
///
/// 每种样式都是一层淡染，而不是独立的颜色——消息文字仍是应用的标签色，浅色
/// 页面黑字、深色页面白字——所以样式只是把文字下面的纸提亮或压暗，绝不跟
/// 上面的字抢视线。
enum ChatBubbleStyle: String, CaseIterable {
    /// 当下的强调色，和聊天一直以来的画法一致。
    case tinted
    /// 一张纸叠在纸面上：发丝般的描边，稍亮一点。
    case paper
    /// 没有底色：只沿消息画一圈发丝描边。
    case outline
    /// 暖棕色，浓淡读起来像牛皮纸而不是着色。
    case kraft
    /// 冷墨色，淡到几乎看不见：预设里最安静的一种。
    case inkWash
    /// 读者自己挑的颜色，存的是它的原始色值。
    case custom

    var title: String {
        switch self {
        case .tinted: String(localized: "Tinted")
        case .paper: String(localized: "Paper")
        case .outline: String(localized: "Outline")
        case .kraft: String(localized: "Kraft")
        case .inkWash: String(localized: "Ink Wash")
        case .custom: String(localized: "Custom Color")
        }
    }

    // MARK: - 存储

    static let changed = Notification.Name("wiki.qaq.apelin.chatBubbleStyleChanged")

    private static let key = "chat.bubbleStyle"
    private static let customColorKey = "chat.bubbleCustomColor"

    static var current: ChatBubbleStyle {
        get {
            UserDefaults.standard.string(forKey: key)
                .flatMap(Self.init(rawValue:)) ?? .tinted
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// 读者挑的自定义颜色，按四个色值存储，重启后不依赖归档或系统色表。
    static var customColor: UIColor {
        get {
            guard let values = UserDefaults.standard.array(forKey: customColorKey) as? [NSNumber],
                  values.count == 4
            else { return .systemBlue }
            return UIColor(
                red: CGFloat(values[0].doubleValue),
                green: CGFloat(values[1].doubleValue),
                blue: CGFloat(values[2].doubleValue),
                alpha: CGFloat(values[3].doubleValue),
            )
        }
        set {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
            let resolved = newValue.resolvedColor(with: UITraitCollection.current)
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else { return }
            UserDefaults.standard.set(
                [Double(red), Double(green), Double(blue), Double(alpha)],
                forKey: customColorKey,
            )
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    // MARK: - 底色

    /// 底色的两个渐变端点，以及围在它外面的描边。`accent` 是应用的着色，
    /// 只有 `tinted` 样式跟着它走，其余样式忽略它。
    func colours(dark: Bool, accent: UIColor, custom: UIColor? = nil) -> (fill: [UIColor], border: UIColor?, width: CGFloat) {
        switch self {
        case .tinted:
            // 强调色的淡染，加了描边，让它在任何颜色的纸上都读得出来，
            // 而不是沉进纸里。
            return (
                [accent.withAlphaComponent(0.10), accent.withAlphaComponent(0.15)],
                accent.withAlphaComponent(dark ? 0.16 : 0.12),
                1,
            )
        case .paper:
            return dark
                ? ([Self.rgb(0x3A3A3C, alpha: 0.90), Self.rgb(0x2C2C2E, alpha: 0.94)], Self.white(0.06), 1)
                : ([Self.white(0.92), Self.rgb(0xF4F4F7, alpha: 0.88)], Self.black(0.05), 1)
        case .outline:
            return (
                [.clear, .clear],
                dark ? Self.white(0.20) : Self.black(0.16),
                1,
            )
        case .kraft:
            return dark
                ? ([Self.rgb(0xC79A63, alpha: 0.16), Self.rgb(0x8A5E2E, alpha: 0.12)], Self.rgb(0xC79A63, alpha: 0.14), 1)
                : ([Self.rgb(0xC08A4E, alpha: 0.14), Self.rgb(0x8A5E2E, alpha: 0.10)], Self.rgb(0x8A5E2E, alpha: 0.16), 1)
        case .inkWash:
            // 冷墨色，描边细到刚好说明这层淡染是有意为之，而不是纸上
            // 蹭到的一道痕。
            return dark
                ? ([Self.white(0.05), Self.white(0.09)], Self.white(0.10), 1)
                : ([Self.rgb(0x0F1720, alpha: 0.05), Self.rgb(0x0F1720, alpha: 0.09)], Self.rgb(0x0F1720, alpha: 0.10), 1)
        case .custom:
            let colour = (custom ?? Self.customColor).resolvedColor(with: UITraitCollection.current)
            return (
                [colour.withAlphaComponent(dark ? 0.30 : 0.20), colour.withAlphaComponent(dark ? 0.40 : 0.28)],
                colour.withAlphaComponent(dark ? 0.55 : 0.38),
                1,
            )
        }
    }

    /// 底色的小圆角卡片，设置页用它预览：宽到能读成一个气泡，而不只是一个
    /// 色块。
    func preview(size: CGSize, traits: UITraitCollection, accent: UIColor) -> UIImage {
        let dark = traits.userInterfaceStyle == .dark
        let skin = colours(
            dark: dark,
            accent: accent.resolvedColor(with: traits),
            custom: Self.customColor,
        )
        let format = UIGraphicsImageRendererFormat.preferred()
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: skin.width, dy: skin.width)
            let path = UIBezierPath(roundedRect: rect, cornerRadius: rect.height * 0.42)
            path.addClip()
            let colours = skin.fill.map { $0.resolvedColor(with: traits).cgColor }
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colours as CFArray,
                locations: [0, 1],
            ) {
                context.cgContext.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: rect.midX, y: rect.minY),
                    end: CGPoint(x: rect.midX, y: rect.maxY),
                    options: [],
                )
            }
            if let border = skin.border, skin.width > 0 {
                border.resolvedColor(with: traits).setStroke()
                path.lineWidth = skin.width
                path.stroke()
            }
        }
    }

    private static func white(_ alpha: CGFloat) -> UIColor {
        UIColor(white: 1, alpha: alpha)
    }

    private static func black(_ alpha: CGFloat) -> UIColor {
        UIColor(white: 0, alpha: alpha)
    }

    private static func rgb(_ value: UInt32, alpha: CGFloat) -> UIColor {
        UIColor(
            red: CGFloat((value >> 16) & 0xFF) / 255,
            green: CGFloat((value >> 8) & 0xFF) / 255,
            blue: CGFloat(value & 0xFF) / 255,
            alpha: alpha,
        )
    }
}
