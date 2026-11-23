import UIKit

/// 聊天写在上面的那张纸：应用画的一张纸、读者自己的图片按 `opacity` 淡化，
/// 或者什么都不画，只用应用原本的背景。
///
/// 它不吃触摸：上面的消息列表和输入框都像在应用原本的背景上一样工作。
final class ChatBackgroundView: UIView {
    /// 画什么。
    var background: ChatBackground = .none {
        didSet { apply() }
    }

    /// 图片显示的比例。纸忽略它。
    var opacity: Double = 1 {
        didSet { imageView.alpha = opacity }
    }

    private let paperView = PaperBackgroundView()
    private let imageView = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        backgroundColor = .clear
        paperView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(paperView)
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageView.isAccessibilityElement = false
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)
        apply()
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        paperView.frame = bounds
        imageView.frame = bounds
    }

    @objc dynamic private func apply() {
        switch background {
        case .none:
            paperView.isHidden = true
            imageView.image = nil
            imageView.isHidden = true
        case let .paper(paper):
            paperView.paper = paper
            paperView.isHidden = false
            imageView.image = nil
            imageView.isHidden = true
        case .image:
            paperView.isHidden = true
            imageView.image = Self.picture()
            imageView.isHidden = imageView.image == nil
            imageView.alpha = opacity
        }
    }

    // MARK: - 图片

    /// 读者选的图片，按文件读一次：聊天页每次回到屏幕都会来取。
    private static var cachedPicture: UIImage?
    private static var cachedStamp: Date?
    private static var cachedPictureTint: UIColor?

    static func picture() -> UIImage? {
        let url = ChatBackground.imageURL
        let stamp = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let stamp, stamp == cachedStamp, let cachedPicture {
            return cachedPicture
        }
        let loaded = UIImage(contentsOfFile: url.path)
        cachedPicture = loaded
        cachedStamp = stamp
        cachedPictureTint = nil
        return loaded
    }

    /// 一张纸的小图，设置页每一行显示它。
    static func preview(_ paper: ChatBackground.Paper, size: CGSize, traits: UITraitCollection? = nil) -> UIImage {
        let view = PaperBackgroundView(frame: CGRect(origin: .zero, size: size))
        view.overrideUserInterfaceStyle = traits?.userInterfaceStyle ?? .unspecified
        view.paper = paper
        view.scale = 0.4
        view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat.preferred()
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            view.layer.render(in: context.cgContext)
        }
    }

    /// 读者的图片作为圆角小图，显示在命名它的那一行。
    static func picturePreview(size: CGSize) -> UIImage? {
        guard let image = picture(),
              let scaled = image.preparingThumbnail(of: size)
        else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            let path = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            path.addClip()
            scaled.draw(in: CGRect(origin: .zero, size: size))
        }
    }

    /// 纸印在哪一种底色上：顶部模糊淡入它。
    static func base(_ paper: ChatBackground.Paper, traits: UITraitCollection) -> UIColor {
        PaperBackgroundView.base(paper, traits: traits)
    }

    /// 读者图片顶部一条的颜色，顶部模糊正是压在这一条上：取一个平均像素，
    /// 让顶栏跟着图片走，而不是在图片上盖一张白纸或黑纸。
    static func topTint() -> UIColor? {
        guard let image = picture(), let cg = image.cgImage else { return nil }
        let band = max(1, cg.height / 8)
        guard let top = cg.cropping(to: CGRect(x: 0, y: 0, width: cg.width, height: band)) else {
            return nil
        }
        return averageTint(top)
    }

    /// 整张图片的平均色，给侧栏选中行的描边判断深浅用。
    static func pictureTint() -> UIColor? {
        guard let cg = picture()?.cgImage else { return nil }
        if let cachedPictureTint { return cachedPictureTint }
        cachedPictureTint = averageTint(cg)
        return cachedPictureTint
    }

    private static func averageTint(_ image: CGImage) -> UIColor? {
        var pixel = [UInt8](repeating: 0, count: 4)
        guard let context = CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        return UIColor(
            red: CGFloat(pixel[0]) / 255,
            green: CGFloat(pixel[1]) / 255,
            blue: CGFloat(pixel[2]) / 255,
            alpha: 1
        )
    }
}
