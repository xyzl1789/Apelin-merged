import ListViewKit
import Litext
import MarkdownView
import UIKit

/// User messages use FlowDown's trailing, accent-tinted bubble geometry.
/// Assistant text uses MarkdownView, with received images in an album below it.
/// Laid out left to right and mirrored right to left, where the bubble
/// and its attachments sit on the left.
final class ChatMessageRow: ListRowView {
    static let horizontalPadding: CGFloat = 20
    /// The widest a row's content gets: the composer's card at its widest
    /// (750 pt less its 10 pt gap each side), so text lines up with it. The
    /// list spans the page's safe area side to side, so the margins beside
    /// the content still scroll.
    static let readableWidth: CGFloat = 730

    /// A row's insets at `width`: the padding, or more to centre the content
    /// in the readable width.
    static func insets(for width: CGFloat, generatedFilesFollowing: Bool = false) -> UIEdgeInsets {
        let side = max(horizontalPadding, ((width - readableWidth) / 2).rounded(.down))
        let following = generatedFilesFollowing ? generatedFilesFollowingSpacing : 0
        return UIEdgeInsets(
            top: ChatMarkdownView.blockSpacing / 2,
            left: side,
            bottom: ChatMarkdownView.blockSpacing / 2 + following,
            right: side,
        )
    }

    private static let userContentPadding: CGFloat = 20
    private static let textPadding: CGFloat = 12
    /// Between the sender line and what it is over.
    private static let senderSpacing: CGFloat = 4

    private let bubble = MessageAccentGradientView()
    /// Over a message another conversation's agent sent: which one. A
    /// label, so VoiceOver reads it before the message.
    private let senderLabel = UILabel()
    /// The message this row shows: only a change to it animates, never the
    /// row taking another message out of the pool.
    private var shownID: UUID?
    /// 相同文本和字号不再重复生成 attributed string。
    private var shownText: String?
    private var shownTextSize: CGFloat?
    private let label = TextLabelView()
    /// The element VoiceOver reads a message by: where the chat's "Your
    /// Messages" rotor puts the cursor.
    var spokenElement: UIView { label }
    /// A generated-files reply gets a quiet container so the links read as one result group.
    private static let generatedFilesCardHorizontalPadding: CGFloat = 12
    private static let generatedFilesCardTopPadding: CGFloat = 12
    private static let generatedFilesCardBottomPadding: CGFloat = 4
    private static let generatedFilesCardCornerRadius: CGFloat = 12
    /// 文件卡片行额外留出的底部空白，单独拉开它与下一条消息的距离。
    private static let generatedFilesFollowingSpacing: CGFloat = 12
    private let generatedFilesCard = UIView()
    private var showsGeneratedFilesCard = false
    private let markdownView = ChatMarkdownView()
    private var markdownText: String?
    /// 流式视图发布已经布局的文档高度，列表只失效这一行。
    private var publishedDocumentHeight: CGFloat = 0
    var onDocumentHeightChange: (() -> Void)?
    /// The reply has finished, but its last text is still fading in.
    private var finishesStreamWhenStill = false
    /// 聊天内搜索的命中高亮：绘制器挂在 label 上，状态进来就重绘。
    private let searchRenderer = ChatSearchHighlightRenderer()
    /// 由 ChatController 在配置行时写入：本行消息该不该画命中、本行
    /// 是不是当前聚焦的那条。show() 里读它分发给两个绘制器。
    var searchHighlightState: ChatSearchHighlightCenter.State? {
        didSet {
            guard searchHighlightState != oldValue else { return }
            searchRenderer.update(state: searchHighlightState, text: label.attributedText.string)
            markdownView.setSearchHighlight(searchHighlightState)
        }
    }
    private var revealObservation: NSKeyValueObservation?
    private let attachmentsView = MessageAttachmentsView()
    /// The line under the message (`MessageFooterView`).
    private let footer = MessageFooterView()
    private var showsFooter = false
    /// Between what the message shows and the line under it.
    private static let footerSpacing: CGFloat = 4
    var onCopy: (() -> Void)? {
        get { footer.onCopy }
        set { footer.onCopy = newValue }
    }

    var onRewind: (() -> Void)? {
        get { footer.onRewind }
        set { footer.onRewind = newValue }
    }

    var onMore: (() -> Void)? {
        get { footer.onMore }
        set { footer.onMore = newValue }
    }

    /// Copy said Copied, under this message.
    func showCopied() {
        footer.showCopied()
    }
    var attachmentHeightLimit: CGFloat = 0 {
        didSet {
            if attachmentHeightLimit != oldValue {
                setNeedsLayout()
            }
        }
    }

    /// The screen's, the one `height(for:…)` was given, rather than the
    /// row's own traits, which a row not yet in its window may not have:
    /// the row lays its images out at the height it was measured at.
    var displayScale: CGFloat = 0 {
        didSet {
            if displayScale != oldValue {
                setNeedsLayout()
            }
        }
    }

    private var attachments: [ComposerAttachment] = []
    private var isUser = false
    private static var sizingMarkdown = ChatMarkdownView()
    private static var sizingMarkdownTextSize = UIApplication.shared.preferredContentSizeCategory
    private static let sizingLabel = TextLabelView()
    var onAttachmentLayoutChanged: (() -> Void)?
    var onPreview: ((ComposerAttachment) -> Void)?
    var onPreviewImages: (([ComposerAttachment], UUID) -> Void)?
    var onOpenArtifact: ((String) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        // Selection handles extend beyond a transcript row.
        clipsToBounds = false
        bubble.layer.cornerRadius = 12
        bubble.layer.cornerCurve = .continuous
        bubble.clipsToBounds = true
        bubble.isHidden = true
        addSubview(bubble)
        senderLabel.font = Self.senderFont
        senderLabel.adjustsFontForContentSizeCategory = true
        senderLabel.textColor = .secondaryLabel
        senderLabel.textAlignment = .right
        senderLabel.lineBreakMode = .byTruncatingTail
        senderLabel.isHidden = true
        addSubview(senderLabel)
        label.isSelectable = true
        label.delegate = self
        label.isAccessibilityElement = true
        label.lineRenderer = searchRenderer
        addSubview(label)
        generatedFilesCard.layer.cornerRadius = Self.generatedFilesCardCornerRadius
        generatedFilesCard.layer.cornerCurve = .continuous
        generatedFilesCard.layer.borderWidth = 1
        generatedFilesCard.isHidden = true
        generatedFilesCard.isAccessibilityElement = false
        updateGeneratedFilesCardAppearance()
        addSubview(generatedFilesCard)
        addSubview(markdownView)
        markdownView.linkHandler = { [weak self] link, _, _ in
            let url: URL? = switch link {
            case let .url(value): value
            case let .string(value): URL(string: value)
            }
            guard let url else { return }
            if url.scheme?.lowercased() == "apelin-artifact",
               url.host == "share",
               let id = url.pathComponents.dropFirst().first
            {
                self?.onOpenArtifact?(id)
                return
            }
            // an apelin:// link opens its conversation in place
            if ApelinLinkRouter.open(url, in: self?.window?.windowScene) {
                return
            }
            if ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                UIApplication.shared.open(url)
            }
        }
        attachmentsView.onPreview = { [weak self] item in self?.onPreview?(item) }
        attachmentsView.onPreviewImages = { [weak self] items, selectedID in self?.onPreviewImages?(items, selectedID) }
        attachmentsView.onSizeChange = { [weak self] in self?.onAttachmentLayoutChanged?() }
        addSubview(attachmentsView)
        footer.isHidden = true
        addSubview(footer)
        revealObservation = markdownView.streamLabel.observe(\.isAnimating) { [weak self] _, _ in
            // Called while the label is still taking its animation down.
            DispatchQueue.main.async { [weak self] in
                guard let self, finishesStreamWhenStill, !markdownView.streamLabel.isAnimating else { return }
                finishStream()
            }
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(frame:)")
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        guard previousTraitCollection?.hasDifferentColorAppearance(comparedTo: traitCollection) == true else { return }
        updateGeneratedFilesCardAppearance()
    }

    private func updateGeneratedFilesCardAppearance() {
        generatedFilesCard.backgroundColor = UIColor.secondarySystemBackground
        generatedFilesCard.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).resolvedColor(with: traitCollection).cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        label.clearSelection()
        label.attributedText = NSAttributedString()
        label.accessibilityLabel = nil
        bubble.isHidden = true
        bubble.showsConversationBorder = false
        senderLabel.text = nil
        senderLabel.isHidden = true
        shownID = nil
        shownText = nil
        shownTextSize = nil
        finishesStreamWhenStill = false
        markdownView.reset()
        markdownView.isStreaming = false
        markdownView.streamIdentity = nil
        markdownView.setSearchHighlight(nil)
        markdownText = nil
        publishedDocumentHeight = 0
        showsGeneratedFilesCard = false
        generatedFilesCard.isHidden = true
        onDocumentHeightChange = nil
        attachments = []
        markdownView.usesFileLinkColors = false
        attachmentsView.show([], trailing: false, animated: false)
        onAttachmentLayoutChanged = nil
        onPreview = nil
        onPreviewImages = nil
        onOpenArtifact = nil
        footer.reset()
        footer.isHidden = true
        showsFooter = false
    }

    func show(_ message: ChatMessage, isStreaming: Bool = false) {
        let isSameMessage = shownID == message.id
        let shouldStream = isStreaming && !message.isGeneratedFiles
        markdownView.usesFileLinkColors = message.isGeneratedFiles
        showsGeneratedFilesCard = message.role == .assistant && message.isGeneratedFiles
        generatedFilesCard.isHidden = !showsGeneratedFilesCard
        if !isSameMessage {
            publishedDocumentHeight = 0
        }
        isUser = message.role == .user
        let textSize = Self.font.pointSize
        if shownText != message.text || shownTextSize != textSize {
            shownText = message.text
            shownTextSize = textSize
            label.attributedText = Self.attributedText(message.text)
        }
        label.accessibilityLabel = message.text
        // A message the run has not taken yet waits faded, and settles in
        // place once it does.
        let waiting = isUser && message.isQueued
        let alpha: CGFloat = waiting ? 0.5 : 1
        if bubble.alpha != alpha {
            let fade = { [self] in
                bubble.alpha = alpha
                label.alpha = alpha
            }
            if isSameMessage, window != nil, !UIAccessibility.isReduceMotionEnabled {
                UIView.animate(withDuration: 0.25, animations: fade)
            } else {
                fade()
            }
        }
        shownID = message.id
        // 搜索高亮：label 的文本刚换，用新文本重新定位并要求重绘。
        searchRenderer.update(state: searchHighlightState, text: message.text)
        label.setNeedsTextDisplay()
        label.accessibilityValue = waiting ? String(localized: "Waiting to Send") : nil
        bubble.isHidden = !isUser || message.text.isEmpty
        bubble.showsConversationBorder = isUser && message.sender != nil
        senderLabel.text = isUser ? message.sender : nil
        senderLabel.isHidden = senderLabel.text == nil
        senderLabel.alpha = alpha
        label.isHidden = message.role != .user
        markdownView.isHidden = message.role == .user
        if message.role == .assistant {
            let firstFill = markdownView.streamIdentity != AnyHashable(message.id)
            if firstFill {
                finishesStreamWhenStill = false
            }
            markdownView.streamIdentity = message.id
            let animates = !UIAccessibility.isReduceMotionEnabled
            // The update that ends a reply often brings its last chunk too.
            // Turning streaming off now would show that chunk and the text
            // still fading at once, so it stays on until the label is still.
            if !shouldStream, animates, !firstFill, markdownView.isStreaming {
                finishesStreamWhenStill = true
            } else {
                finishesStreamWhenStill = false
                markdownView.isStreaming = shouldStream && animates
            }
            if firstFill || markdownText != message.text {
                ChatPerformance.measure("markdown") {
                    if firstFill || !markdownView.isStreaming {
                        markdownView.setMarkdown(message.text)
                    } else {
                        markdownView.setContent(MarkdownContent(markdown: message.text, theme: markdownView.theme))
                    }
                }
                markdownText = message.text
            }
            if finishesStreamWhenStill, !markdownView.streamLabel.isAnimating {
                finishStream()
            }
        }
        // 搜索高亮：回复行在渲染后的文档文本上定位 query 后交给绘制器。
        markdownView.setSearchHighlight(searchHighlightState)
        attachments = message.attachments
        attachmentsView.show(attachments, trailing: isUser, animated: isSameMessage)
        showsFooter = MessageFooterView.shows(message)
        footer.isHidden = !showsFooter
        if showsFooter {
            footer.show(message)
        }
        setNeedsLayout()
    }

    private func finishStream() {
        finishesStreamWhenStill = false
        markdownView.isStreaming = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let content = bounds.inset(by: Self.insets(for: bounds.width, generatedFilesFollowing: showsGeneratedFilesCard))
        let hasText = label.attributedText.length > 0
        let available = Self.textWidth(for: bounds.width, user: true)
        // The label measures itself as `height(for:)` measures it.
        let textSize = isUser && hasText ? label.sizeThatFits(CGSize(width: available, height: 0)) : nil
        let documentWidth = isUser ? Self.bubbleWidth(textSize: textSize, available: available) : 350
        let attachmentWidth = isUser ? available + Self.textPadding * 2 : content.width
        attachmentsView.documentWidthLimit = documentWidth
        attachmentsView.previewHeightLimit = attachmentHeightLimit
        attachmentsView.displayScale = displayScale
        let attachmentHeight = MessageAttachmentsView.height(
            for: attachments,
            width: attachmentWidth,
            documentWidthLimit: documentWidth,
            maximumPreviewHeight: attachmentHeightLimit,
            displayScale: displayScale,
        )
        let gap = hasText && attachmentHeight > 0 ? ChatMarkdownView.blockSpacing : 0
        let footerHeight = showsFooter ? MessageFooterView.height + Self.footerSpacing : 0
        if isUser {
            let textHeight = textSize.map { ceil($0.height) + Self.textPadding * 2 } ?? 0
            let width = documentWidth
            let senderHeight = senderLabel.isHidden ? 0 : Self.senderHeight
            // over the bubble, at its trailing edge
            senderLabel.textAlignment = laysOutRightToLeft ? .left : .right
            senderLabel.frame = CGRect(
                x: content.minX,
                y: content.minY,
                width: content.width,
                height: ceil(Self.senderFont.lineHeight),
            )
            let top = content.minY + senderHeight
            attachmentsView.frame = directionalFrame(CGRect(
                x: content.maxX - attachmentWidth,
                y: top,
                width: attachmentWidth,
                height: attachmentHeight,
            ))
            bubble.frame = directionalFrame(CGRect(
                x: content.maxX - width,
                y: top + attachmentHeight + gap,
                width: width,
                height: textHeight,
            ))
            label.frame = bubble.frame.insetBy(dx: Self.textPadding, dy: Self.textPadding)
            if showsFooter {
                // under the bubble, at its trailing edge
                let footerWidth = min(footer.contentWidth, content.width)
                footer.frame = directionalFrame(CGRect(
                    x: content.maxX - footerWidth,
                    y: top + attachmentHeight + gap + textHeight + Self.footerSpacing,
                    width: footerWidth,
                    height: MessageFooterView.height,
                ))
            }
        } else {
            let cardHorizontalPadding = showsGeneratedFilesCard ? Self.generatedFilesCardHorizontalPadding : 0
            let cardTopPadding = showsGeneratedFilesCard ? Self.generatedFilesCardTopPadding : 0
            let cardBottomPadding = showsGeneratedFilesCard ? Self.generatedFilesCardBottomPadding : 0
            let textHeight = hasText ? max(0, content.height - attachmentHeight - gap - footerHeight) : 0
            if showsGeneratedFilesCard {
                generatedFilesCard.frame = CGRect(
                    x: content.minX,
                    y: content.minY,
                    width: content.width,
                    height: textHeight + cardTopPadding + cardBottomPadding,
                )
                markdownView.frame = CGRect(
                    x: generatedFilesCard.frame.minX + cardHorizontalPadding,
                    y: generatedFilesCard.frame.minY + cardTopPadding,
                    width: generatedFilesCard.frame.width - cardHorizontalPadding * 2,
                    height: textHeight,
                )
            } else {
                generatedFilesCard.frame = .zero
                markdownView.frame = CGRect(x: content.minX, y: content.minY, width: content.width, height: textHeight)
            }
            markdownView.trackedScrollView = superview as? UIScrollView
            publishStreamingHeight()
            attachmentsView.frame = CGRect(
                x: content.minX,
                y: content.minY + textHeight + cardTopPadding + cardBottomPadding + gap,
                width: content.width,
                height: attachmentHeight,
            )
            if showsFooter {
                // under the reply, at its leading edge
                let footerWidth = min(footer.contentWidth, content.width)
                footer.frame = directionalFrame(CGRect(
                    x: content.minX,
                    y: content.minY + textHeight + cardTopPadding + cardBottomPadding + gap + attachmentHeight + Self.footerSpacing,
                    width: footerWidth,
                    height: MessageFooterView.height,
                ))
            }
        }
    }

    /// 视图已经量出的流式文档高度供列表复用，避免同一帧再解析一份。
    private func publishStreamingHeight() {
        guard markdownView.isStreaming, markdownView.bounds.width > 1,
              let text = markdownText, let id = shownID
        else { return }
        let document = ChatPerformance.measure("document") {
            markdownView.boundingSize(for: markdownView.bounds.width).height
        }
        ChatRowHeights.store(document, id: id, text: text, width: markdownView.bounds.width,
                             textSize: traitCollection.preferredContentSizeCategory.rawValue)
        guard abs(document - publishedDocumentHeight) > 0.5 else { return }
        publishedDocumentHeight = document
        onDocumentHeightChange?()
    }

    static func height(
        for message: ChatMessage,
        width: CGFloat,
        maximumAttachmentHeight: CGFloat,
        displayScale: CGFloat,
    ) -> CGFloat {
        let user = message.role == .user
        let textSizeCategory = UIApplication.shared.preferredContentSizeCategory
        if sizingMarkdownTextSize != textSizeCategory {
            sizingMarkdownTextSize = textSizeCategory
            sizingMarkdown = ChatMarkdownView()
        }
        sizingMarkdown.usesFileLinkColors = message.isGeneratedFiles
        let available = textWidth(for: width, user: user)
        let cardHorizontalPadding = !user && message.isGeneratedFiles ? generatedFilesCardHorizontalPadding : 0
        let markdownWidth = max(1, available - cardHorizontalPadding * 2)
        let userTextSize = user && !message.text.isEmpty ? textSize(message.text, width: available) : nil
        let textHeight: CGFloat
        if message.text.isEmpty {
            textHeight = 0
        } else if let userTextSize {
            textHeight = ceil(userTextSize.height) + textPadding * 2
        } else if let document = ChatRowHeights.height(id: message.id, text: message.text, width: markdownWidth,
                                                      textSize: textSizeCategory.rawValue) {
            textHeight = ceil(document)
        } else {
            let document = ChatPerformance.measure("height") { () -> CGFloat in
                sizingMarkdown.setMarkdown(message.text)
                return sizingMarkdown.boundingSize(for: markdownWidth).height
            }
            ChatRowHeights.store(document, id: message.id, text: message.text, width: markdownWidth,
                                 textSize: textSizeCategory.rawValue)
            textHeight = ceil(document)
        }
        let insets = Self.insets(for: width, generatedFilesFollowing: !user && message.isGeneratedFiles)
        let contentWidth = max(1, width - insets.left - insets.right)
        let attachmentWidth = user ? available + textPadding * 2 : contentWidth
        let documentWidth = user ? bubbleWidth(textSize: userTextSize, available: available) : 350
        let attachmentHeight = MessageAttachmentsView.height(
            for: message.attachments,
            width: attachmentWidth,
            documentWidthLimit: documentWidth,
            maximumPreviewHeight: maximumAttachmentHeight,
            displayScale: displayScale,
        )
        let gap = textHeight > 0 && attachmentHeight > 0 ? ChatMarkdownView.blockSpacing : 0
        let senderHeight = user && message.sender != nil ? Self.senderHeight : 0
        let footerHeight = MessageFooterView.shows(message) ? MessageFooterView.height + footerSpacing : 0
        let generatedFilesCardHeight = !user && message.isGeneratedFiles
            ? generatedFilesCardTopPadding + generatedFilesCardBottomPadding
            : 0
        return senderHeight + textHeight + generatedFilesCardHeight + attachmentHeight + gap + footerHeight + insets.top + insets.bottom
    }

    private static var senderFont: UIFont {
        .preferredFont(forTextStyle: .footnote)
    }

    /// The sender line and the space under it.
    private static var senderHeight: CGFloat {
        ceil(senderFont.lineHeight) + senderSpacing
    }

    /// A bubble fits its text; one with no text leaves its attachments the full width.
    private static func bubbleWidth(textSize: CGSize?, available: CGFloat) -> CGFloat {
        (textSize.map { ceil($0.width) } ?? available) + textPadding * 2
    }

    private static func textWidth(for width: CGFloat, user: Bool) -> CGFloat {
        let insets = Self.insets(for: width)
        let available = width - insets.left - insets.right
        return max(user ? min(800, available - userContentPadding * 2) - textPadding * 2 : available, 1)
    }

    /// Measured by Litext, which draws the text with CoreText and pins its first
    /// line to the top of the label. TextKit's `boundingRect` gives shorter
    /// lines wherever a fallback font brings a taller ascent and descent, as
    /// PingFang does for Chinese, and the text then sat low in its bubble.
    private static func textSize(_ text: String, width: CGFloat) -> CGSize {
        sizingLabel.attributedText = attributedText(text)
        return sizingLabel.sizeThatFits(CGSize(width: width, height: 0))
    }

    private static func attributedText(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: UIColor.label])
    }

    private static var font: UIFont {
        .preferredFont(forTextStyle: .body)
    }
}

extension ChatMessageRow: TextLabelViewDelegate {
    func textLabelView(
        _ label: TextLabelView,
        editMenuForSelection selection: NSRange,
        suggestedActions: [UIMenuElement],
    ) -> UIMenu? {
        ChatSelectionMenu.menu(for: label, selection: selection, suggestedActions: suggestedActions)
    }
}
