import UIKit

/// 将流式思考文本滚动显示在单行内，并把当前可见文本提供给辅助功能。
final class ChatRollingLine: UIView {
    var text: String? {
        didSet { update() }
    }

    var running = true {
        didSet { update() }
    }

    var font: UIFont = .preferredFont(forTextStyle: .subheadline) {
        didSet { label.font = font }
    }

    var textColor: UIColor = .tertiaryLabel {
        didSet { label.textColor = textColor }
    }

    static let maximumLength = 200
    static let rollInterval: TimeInterval = 0.25
    private static let rollDuration: TimeInterval = 0.2

    var lineHeight: CGFloat { ceil(font.lineHeight) }
    private(set) var shownText: String?

    private let clip = UIView()
    private let label = UILabel()
    private var lastRoll = Date.distantPast

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        isUserInteractionEnabled = false
        clip.clipsToBounds = true
        addSubview(clip)
        label.font = font
        label.textColor = textColor
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingHead
        clip.addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    static func tail(of text: String) -> String {
        let end = text.suffix(maximumLength * 2)
        let line = end.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let truncated = line.count > maximumLength || text.utf8.count > end.utf8.count
        guard truncated else { return line }
        return "…" + String(line.suffix(maximumLength))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        clip.frame = bounds
        label.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: lineHeight)
    }

    private func update() {
        let next = running ? text.map(Self.tail) : text
        label.lineBreakMode = running ? .byTruncatingHead : .byTruncatingTail
        guard next != shownText else { return }
        let previous = shownText
        shownText = next
        // 复用或节流期间的新文本也必须移除上一轮动画留下的副本。
        label.layer.removeAllAnimations()
        label.transform = .identity
        for view in clip.subviews where view !== label {
            view.removeFromSuperview()
        }
        if next == nil { lastRoll = .distantPast }
        let rolls = running && next != nil && previous != nil && window != nil
            && !UIAccessibility.isReduceMotionEnabled
            && Date().timeIntervalSince(lastRoll) >= Self.rollInterval
        guard rolls, let previous else {
            label.text = next
            return
        }
        lastRoll = Date()
        let line = max(bounds.height, lineHeight)
        let leaving = UILabel()
        leaving.font = font
        leaving.textColor = textColor
        leaving.numberOfLines = 1
        leaving.lineBreakMode = running ? .byTruncatingHead : .byTruncatingTail
        leaving.text = previous
        leaving.frame = CGRect(x: 0, y: 0, width: max(bounds.width, 1), height: line)
        clip.insertSubview(leaving, belowSubview: label)
        label.text = next
        label.transform = CGAffineTransform(translationX: 0, y: line)
        UIView.animate(withDuration: Self.rollDuration, delay: 0, options: [.curveEaseOut]) {
            leaving.transform = CGAffineTransform(translationX: 0, y: -line)
            leaving.alpha = 0
            self.label.transform = .identity
        } completion: { _ in
            leaving.removeFromSuperview()
        }
    }
}
