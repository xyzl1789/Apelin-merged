import ApelinCore
import UIKit

/// 聊天页背后画的东西。
///
/// 三种选择：应用原本的背景、应用自己画的一张纸、读者选的一张图片。
/// 纸是不透明的，不需要淡化；图片按 `opacity` 画成半透明，让应用原本的
/// 颜色透上来。
enum ChatBackground: Equatable {
    /// 应用原本的背景。
    case none
    /// 应用画的一张纸。
    case paper(Paper)
    /// 读者自己的图片。
    case image

    /// 应用画的纸，顺序与设置页列出的相同。
    enum Paper: String, CaseIterable {
        case rice
        case ivory
        case kraft
        case slate
        case ruled
        case grid
        case dots

        var title: String {
            switch self {
            case .rice: String(localized: "Rice Paper")
            case .ivory: String(localized: "Ivory")
            case .kraft: String(localized: "Kraft")
            case .slate: String(localized: "Slate")
            case .ruled: String(localized: "Ruled")
            case .grid: String(localized: "Grid")
            case .dots: String(localized: "Dots")
            }
        }
    }

    // MARK: - 存储

    /// 设置改变后聊天页重新加载它画的东西。
    static let changed = Notification.Name("wiki.qaq.apelin.chatBackgroundChanged")

    private static let choiceKey = "chat.background"
    private static let opacityKey = "chat.backgroundOpacity"

    static var current: ChatBackground {
        get {
            let stored = UserDefaults.standard.string(forKey: choiceKey) ?? "none"
            if stored == "image", hasImage {
                return .image
            }
            if stored.hasPrefix("paper:"),
               let paper = Paper(rawValue: String(stored.dropFirst("paper:".count))) {
                return .paper(paper)
            }
            return .none
        }
        set {
            UserDefaults.standard.set(stored(for: newValue), forKey: choiceKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// 图片显示的比例：1 为原样，越低越让应用的颜色透上来。纸忽略这个值。
    static var opacity: Double {
        get {
            let stored = UserDefaults.standard.object(forKey: opacityKey) as? Double
            return min(max(stored ?? 0.85, 0.1), 1)
        }
        set {
            UserDefaults.standard.set(min(max(newValue, 0.1), 1), forKey: opacityKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    /// 当前选的纸：顶部模糊淡入它自己的颜色。
    var paper: Paper? {
        if case let .paper(paper) = self { return paper }
        return nil
    }

    /// 读者图片存放的位置：应用数据目录里的 `Background/chat.jpg`。
    static var imageURL: URL {
        DataFolder.app.chatBackgroundImage
    }

    /// 图片文件在不在，且是普通文件：指向一张已经不存在的图片时回退到原本的背景。
    static var hasImage: Bool {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(
            atPath: imageURL.path,
            isDirectory: &isDirectory,
        )
        return exists && !isDirectory.boolValue
    }

    /// 移除图片，以及指向它的选择。
    static func removeImage() throws {
        if hasImage {
            try FileManager.default.removeItem(at: imageURL)
        }
        if current == .image {
            UserDefaults.standard.set("none", forKey: choiceKey)
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }

    private static func stored(for background: ChatBackground) -> String {
        switch background {
        case .none: "none"
        case let .paper(paper): "paper:\(paper.rawValue)"
        case .image: "image"
        }
    }
}
