import UIKit

/// 页面的开场：一段没有消息的对话中间的一行字，带着光标写出来，停留一会
/// 让读者看清，再逐字收回，换成另一句重写。
///
/// 整句一次排版、靠颜色逐字显现，所以写字时行不会重排也不会滑动；光标放在
/// 这份固定排版上，跟着已写出的字走。
///
/// 它不接收触碰，对 VoiceOver 是一个整体元素——即便还在写，也读完整句。
final class ChatWelcomeView: UIView {
    /// 从随机一句开始，之后按顺序轮播，每句都会出现。
    static var lines: [String] {
        [
            String(localized: "Hello, is there anything I can help you with?"),
            String(localized: "What would you like to do right now?"),
            String(localized: "A thought in hand, waiting to set out."),
            String(localized: "In this small square, thoughts become things!"),
            String(localized: "Wherever thought turns, it can take shape."),
            String(localized: "What would you like to explore?"),
            String(localized: "Ready and waiting for your word."),
            String(localized: "Ready when you are — let's begin!"),
            String(localized: "One thought, a thousand things built."),
            String(localized: "Waiting quietly for your next idea."),
        ]
    }

    /// 不论句子长短，写完大约用这么久——长的英文行和短的中文行在眼睛看来
    /// 节奏一致——每个字耗时在下面两个界限之间。
    private static let writingSeconds = 1.6
    private static let slowestCharacter = 0.11
    private static let fastestCharacter = 0.035
    /// 收回比写出快：读者已经读过了。
    private static let erasingSeconds = 0.7
    private static let quickestErase = 0.018
    /// 写完停留多久才收回，以及空页停留多久再写下一句。
    private static let heldSeconds = 2.4
    private static let emptySeconds = 0.6
    /// 最新一个字后面拖一个半字的淡入，读起来像墨迹浮现，而不是一排灯逐盏亮起。
    private static let fadeCharacters = 1.5
    private static let blinkSeconds = 0.5

    /// 墨迹的浓度：问候语是给别人读的，不是在喊。
    private static let inkAlpha: CGFloat = 0.9

    private static var ink: UIColor {
        UIColor.label.withAlphaComponent(inkAlpha)
    }

    /// 对齐上游字号：欢迎语低调一点，较长的译文也能自然换行。
    private static var font: UIFont {
        UIFontMetrics(forTextStyle: .title2).scaledFont(
            for: .systemFont(ofSize: 20, weight: .regular),
            maximumPointSize: 34,
        )
    }

    private let label = UILabel()
    private let caret = UIView()
    private var loop: Task<Void, Never>?
    private var full: NSAttributedString?
    private var ranges: [NSRange] = []
    /// 句子自己的排版，和它的存储一起留着：layout manager 弱引用 text
    /// storage，存储一旦释放，它就没有字形可以测量。
    private var textLayout: (storage: NSTextStorage, manager: NSLayoutManager, container: NSTextContainer)?
    private var lineIndex = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        label.numberOfLines = 0
        label.textAlignment = .center
        label.adjustsFontForContentSizeCategory = true
        label.font = Self.font
        label.textColor = Self.ink
        label.isAccessibilityElement = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        caret.backgroundColor = Self.ink.withAlphaComponent(0.55)
        caret.layer.cornerRadius = 1
        caret.isAccessibilityElement = false
        caret.isHidden = true
        label.addSubview(caret)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor),
            label.bottomAnchor.constraint(equalTo: bottomAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor),
            label.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    deinit {
        loop?.cancel()
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        super.willMove(toWindow: newWindow)
        if newWindow == nil {
            stop()
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 宽度变了，句子要重新排版；光标画到它现在该在的位置，而不是旧
        // 宽度留下的位置。
        buildLayout()
        if loop == nil {
            caret.layer.removeAllAnimations()
            caret.isHidden = true
        } else {
            startBlinking()
        }
    }

    // MARK: - 写字

    /// 打开新页面：第一句写出来，随后是另一句。
    @objc dynamic func play() {
        stop()
        // 读者要求减少动态效果，或正在用朗读时，不做逐字动画：句子直接在那。
        guard !UIAccessibility.isReduceMotionEnabled,
              !UIAccessibility.isVoiceOverRunning
        else {
            prepare(Self.lines.first ?? "")
            label.attributedText = full
            caret.isHidden = true
            return
        }
        lineIndex = Int.random(in: 0 ..< max(1, Self.lines.count))
        startBlinking()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, await self.writeThenErase() else { return }
            }
        }
    }

    /// 停在原处：句子留写到哪就是哪，不再变化。
    @objc dynamic func stop() {
        loop?.cancel()
        loop = nil
        caret.layer.removeAllAnimations()
        caret.isHidden = true
        if let full {
            label.attributedText = full
        }
    }

    /// 写一句、停一停、再收回。任务被取消时返回 false，循环就此结束，不会
    /// 写进另一页里。
    private func writeThenErase() async -> Bool {
        let lines = Self.lines
        guard !lines.isEmpty else { return false }
        let line = lines[lineIndex % lines.count]
        lineIndex = (lineIndex + 1) % lines.count
        prepare(line)
        if Task.isCancelled { return false }

        let count = ranges.count
        let step = min(Self.slowestCharacter, max(Self.fastestCharacter, Self.writingSeconds / Double(max(count, 1))))
        for written in 0 ... count {
            if Task.isCancelled { return false }
            reveal(written)
            try? await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
        }
        if Task.isCancelled { return false }
        try? await Task.sleep(nanoseconds: UInt64(Self.heldSeconds * 1_000_000_000))
        if Task.isCancelled { return false }

        let erasing = max(Self.quickestErase, Self.erasingSeconds / Double(max(count, 1)))
        for written in stride(from: count, through: 0, by: -1) {
            if Task.isCancelled { return false }
            reveal(written)
            try? await Task.sleep(nanoseconds: UInt64(erasing * 1_000_000_000))
        }
        if Task.isCancelled { return false }
        try? await Task.sleep(nanoseconds: UInt64(Self.emptySeconds * 1_000_000_000))
        return !Task.isCancelled
    }

    /// 把 `line` 完整排版并先全部藏起来，等着逐字显现。
    private func prepare(_ line: String) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 6
        let attributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: Self.ink,
            .paragraphStyle: paragraph,
        ]
        let full = NSAttributedString(string: line, attributes: attributes)
        self.full = full
        label.accessibilityLabel = line
        // 一个 range 对一个画出来的字，用 UTF-16 偏移，让着色走在画出来的
        // 字上，而不是存储的字上。
        ranges = []
        var offset = 0
        for character in line {
            let length = character.utf16.count
            ranges.append(NSRange(location: offset, length: length))
            offset += length
        }
        label.attributedText = full
        buildLayout()
        reveal(0)
    }

    /// 显示前 `written` 个字，并把光标放在它们后面。
    private func reveal(_ written: Int) {
        guard let full else { return }
        let shown = NSMutableAttributedString(attributedString: full)
        for (index, range) in ranges.enumerated() {
            let faded = max(0, min(1, (Double(written) - Double(index)) / Self.fadeCharacters))
            shown.addAttribute(
                .foregroundColor,
                value: Self.ink.withAlphaComponent(Self.inkAlpha * faded),
                range: range,
            )
        }
        label.attributedText = shown
        placeCaret(after: min(written, ranges.count))
    }

    // MARK: - 光标在固定排版上的位置

    private func buildLayout() {
        guard let full, label.bounds.width > 0, label.bounds.height > 0 else {
            textLayout = nil
            return
        }
        let storage = NSTextStorage(attributedString: full)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byWordWrapping
        storage.addLayoutManager(manager)
        manager.addTextContainer(container)
        manager.ensureLayout(for: container)
        textLayout = (storage, manager, container)
    }

    private func placeCaret(after written: Int) {
        guard let layout = textLayout else { return }
        let manager = layout.manager
        let container = layout.container
        let frame: CGRect
        if written == 0 || ranges.isEmpty {
            let fragment = manager.numberOfGlyphs > 0
                ? manager.lineFragmentRect(forGlyphAt: 0, effectiveRange: nil)
                : manager.extraLineFragmentRect
            frame = CGRect(x: fragment.minX, y: fragment.minY, width: 2, height: fragment.height)
        } else {
            // 最后一个字的整个字形段，这样由多个字形组成的字簇，光标会
            // 落在它们全部之后。
            let characters = ranges[written - 1]
            let glyphs = manager.glyphRange(forCharacterRange: characters, actualCharacterRange: nil)
            let rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
            let line = manager.lineFragmentRect(forGlyphAt: max(NSMaxRange(glyphs) - 1, 0), effectiveRange: nil)
            frame = CGRect(x: rect.maxX, y: line.minY, width: 2, height: line.height)
        }
        // UILabel 把文字块在 bounds 里居中，而排版从顶部开始，所以光标要
        // 跟着文字一起偏移。
        let used = manager.usedRect(for: container)
        let offsetY = max(0, (label.bounds.height - used.height) / 2)
        let height = min(frame.height, label.bounds.height)
        caret.isHidden = false
        caret.frame = CGRect(
            x: min(max(frame.minX, 0), max(0, label.bounds.width - 2)),
            y: min(max(offsetY + frame.midY - height / 2, 0), max(0, label.bounds.height - height)),
            width: 2,
            height: height,
        )
    }

    private func startBlinking() {
        caret.alpha = 1
        caret.layer.removeAllAnimations()
        UIView.animate(
            withDuration: Self.blinkSeconds,
            delay: 0,
            options: [.repeat, .autoreverse, .curveLinear, .allowUserInteraction],
        ) {
            self.caret.alpha = 0
        }
    }
}
