import UIKit
import UniformTypeIdentifiers

/// 扩展只暂存草稿，不发送消息，也不调用会话服务。
@objc(ShareController)
final class ShareController: UITableViewController {
    private var destinations: [ShareTransfer.Destination] = []
    @objc dynamic private var saving = false
    @objc dynamic private weak var progress: UIActivityIndicatorView?
    @objc dynamic private weak var cancelButton: UIButton?

    override func viewDidLoad() {
        super.viewDidLoad()
        if let root = ShareTransfer.root { destinations = ShareTransfer.destinations(at: root) }
        tableView.backgroundColor = .systemGroupedBackground
        tableView.separatorStyle = .none
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 78
        tableView.register(ShareDestinationCard.self, forCellReuseIdentifier: "destination")
        let header = makeHeader()
        header.frame.size.height = 88
        tableView.tableHeaderView = header
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let header = tableView.tableHeaderView, tableView.bounds.width > 0 else { return }
        let width = tableView.bounds.width
        let size = header.systemLayoutSizeFitting(
            CGSize(width: width, height: 0),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        )
        let height = ceil(size.height)
        guard header.frame.width != width || header.frame.height != height else { return }
        header.frame.size = CGSize(width: width, height: height)
        tableView.tableHeaderView = header
    }

    @objc dynamic private func makeHeader() -> UIView {
        let header = UIView()
        let title = UILabel()
        title.text = "分享到 Apelin"
        title.font = .preferredFont(forTextStyle: .title2)
        title.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.accessibilityTraits = .header
        let hint = UILabel()
        hint.text = "选一个会话，分享内容不会自动发送。"
        hint.font = .preferredFont(forTextStyle: .subheadline)
        hint.adjustsFontForContentSizeCategory = true
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        let cancel = UIButton(type: .system, primaryAction: UIAction(title: "取消") { [weak self] _ in
            guard let self, !saving else { return }
            extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        cancel.titleLabel?.font = .preferredFont(forTextStyle: .body)
        cancel.titleLabel?.adjustsFontForContentSizeCategory = true
        cancel.setContentCompressionResistancePriority(.required, for: .horizontal)
        cancelButton = cancel
        let spinner = UIActivityIndicatorView(style: .medium)
        spinner.isAccessibilityElement = true
        spinner.accessibilityLabel = "正在保存分享"
        progress = spinner
        let bar = UIStackView(arrangedSubviews: [title, spinner, cancel])
        bar.alignment = .center
        bar.spacing = 10
        let stack = UIStackView(arrangedSubviews: [bar, hint])
        stack.axis = .vertical
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: header.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
            cancel.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        return header
    }

    override func numberOfSections(in _: UITableView) -> Int { destinations.isEmpty ? 1 : 2 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : destinations.count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? nil : "已有会话"
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "destination", for: indexPath)
        guard let card = cell as? ShareDestinationCard else { return cell }
        if indexPath.section == 0 {
            card.configure(title: "新建会话", subtitle: "用本次分享创建草稿", isNew: true)
        } else {
            let item = destinations[indexPath.row]
            card.configure(title: item.title, subtitle: item.project ?? "通用会话", isNew: false)
        }
        return card
    }

    override func tableView(_: UITableView, shouldHighlightRowAt _: IndexPath) -> Bool { !saving }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !saving, presentedViewController == nil else { return }
        let destination = indexPath.section == 0 ? nil : destinations[indexPath.row]
        let alert = UIAlertController(
            title: destination?.title ?? "新建会话",
            message: "内容会加入草稿，不会自动发送。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "加入草稿", style: .default) { [weak self] _ in
            self?.save(target: destination?.id, openConversation: false)
        })
        alert.addAction(UIAlertAction(title: "打开会话", style: .default) { [weak self] _ in
            self?.save(target: destination?.id, openConversation: true)
        })
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        present(alert, animated: true)
    }

    @objc dynamic private func save(target: UUID?, openConversation: Bool) {
        guard !saving, let context = extensionContext else { return }
        saving = true
        cancelButton?.isEnabled = false
        progress?.startAnimating()
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        Task {
            do {
                try await stage(items, target: target, openConversation: openConversation)
                if openConversation {
                    openApelin(using: context)
                } else {
                    context.completeRequest(returningItems: nil, completionHandler: nil)
                }
            } catch {
                saving = false
                cancelButton?.isEnabled = true
                progress?.stopAnimating()
                let alert = UIAlertController(title: "未能加入草稿", message: (error as? ShareFailure)?.message ?? "无法暂存分享内容，请检查可用空间后重试。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                present(alert, animated: true)
            }
        }
    }

    @objc dynamic private func openApelin(using context: NSExtensionContext) {
        guard let url = ShareTransfer.wakeURL else {
            // 没有唤起链接时也算投递完成，不能让扩展停在转圈上。
            context.completeRequest(returningItems: nil, completionHandler: nil)
            return
        }
        // 先发布完整批次，再唤起应用。链接不携带会话或分享正文。
        context.open(url) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }
                if opened {
                    context.completeRequest(returningItems: nil, completionHandler: nil)
                } else {
                    progress?.stopAnimating()
                    let alert = UIAlertController(title: "分享已保存", message: "未能自动打开 Apelin。手动打开后会进入所选会话。", preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: "完成", style: .default) { _ in
                        context.completeRequest(returningItems: nil, completionHandler: nil)
                    })
                    present(alert, animated: true)
                }
            }
        }
    }

    private struct ShareFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func stage(_ items: [NSExtensionItem], target: UUID?, openConversation: Bool) async throws {
        guard let root = ShareTransfer.root else { throw ShareFailure("无法访问 Apelin 的分享收件箱。") }
        let folders = try ShareTransfer.directories(root)
        let batchID = UUID().uuidString
        let stage = folders.staging.appendingPathComponent(batchID, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        var text: [String] = []
        var files: [ShareTransfer.File] = []
        var bytes: Int64 = 0
        func addText(_ value: String) throws {
            let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty, !text.contains(value) { text.append(value) }
            guard text.joined(separator: "\n\n").utf8.count <= ShareTransfer.textLimit else {
                throw ShareFailure("分享的文字过长。")
            }
        }
        for item in items {
            for provider in item.attachments ?? [] {
                if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                   provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try await Self.load(provider, type: .url) as? URL, !url.isFileURL {
                    guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                        throw ShareFailure("只支持分享 HTTP 或 HTTPS 网页链接。")
                    }
                    try addText(url.absoluteString)
                } else if !provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                          ((provider.suggestedName ?? "") as NSString).pathExtension.isEmpty,
                          provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          !provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    let value = try await Self.load(provider, type: .plainText)
                    if let value = value as? String { try addText(value) }
                    else if let value = value as? Data, let decoded = String(data: value, encoding: .utf8) { try addText(decoded) }
                    else if let value = value as? NSAttributedString { try addText(value.string) }
                    else { throw ShareFailure("读取分享的文字失败。") }
                } else {
                    guard files.count < ShareTransfer.fileLimit else { throw ShareFailure("每次最多分享 8 个文件。") }
                    let id = UUID()
                    let (file, size) = try await Self.copy(provider, id: id, to: stage.appendingPathComponent(id.uuidString), remaining: Int64(ShareTransfer.bytesLimit) - bytes)
                    files.append(file)
                    bytes += size
                }
            }
            if let value = item.attributedContentText?.string { try addText(value) }
        }
        guard !text.isEmpty || !files.isEmpty else { throw ShareFailure("没有可以加入草稿的内容。") }
        let batch = ShareTransfer.Batch(
            target: target, text: text.joined(separator: "\n\n"), files: files, createdAt: Date(),
            opensConversation: openConversation ? true : nil
        )
        try ShareTransfer.write(batch, to: stage)
        try FileManager.default.moveItem(at: stage, to: folders.pending.appendingPathComponent(batchID))
    }

    nonisolated private static func load(_ provider: NSItemProvider, type: UTType) async throws -> NSSecureCoding {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { item, error in
                if let item { continuation.resume(returning: item) }
                else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)) }
            }
        }
    }

    nonisolated private static func copy(_ provider: NSItemProvider, id: UUID, to destination: URL, remaining: Int64) async throws -> (ShareTransfer.File, Int64) {
        let types = provider.registeredTypeIdentifiers.compactMap { UTType($0) }
        let type = types.first { $0.conforms(to: .image) }
            ?? types.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
            ?? types.first { $0 == .item }
        let suggestedName = provider.suggestedName
        let transfer: @Sendable (URL) throws -> (ShareTransfer.File, Int64) = { source in
            let access = source.startAccessingSecurityScopedResource()
            defer { if access { source.stopAccessingSecurityScopedResource() } }
            let source = source.resolvingSymlinksInPath()
            guard let size = ShareTransfer.size(of: source), size <= remaining else {
                throw ShareFailure("只能分享普通文件，每批文件合计最多 50 MB。")
            }
            let original = source.lastPathComponent
            var name = (suggestedName as NSString?)?.lastPathComponent ?? original
            if name.isEmpty || name == "." || name == ".." { name = "分享附件" }
            if (name as NSString).pathExtension.isEmpty,
               let ext = type?.preferredFilenameExtension ?? (source.pathExtension.isEmpty ? nil : source.pathExtension) {
                name += "." + ext
            }
            try FileManager.default.copyItem(at: source, to: destination)
            guard ShareTransfer.size(of: destination) == size else { throw CocoaError(.fileReadCorruptFile) }
            let mimeType = type?.preferredMIMEType ?? UTType(filenameExtension: (name as NSString).pathExtension)?.preferredMIMEType
            return (.init(id: id, name: String(name.prefix(255)), mimeType: mimeType), size)
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    guard let url = item as? URL, url.isFileURL else {
                        continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return
                    }
                    let access = url.startAccessingSecurityScopedResource()
                    defer { if access { url.stopAccessingSecurityScopedResource() } }
                    var coordinationError: NSError?
                    var result: Result<(ShareTransfer.File, Int64), Error>?
                    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { coordinated in
                        result = Result { try transfer(coordinated) }
                    }
                    if let coordinationError { continuation.resume(throwing: coordinationError) }
                    else if let result { continuation.resume(with: result) }
                    else { continuation.resume(throwing: CocoaError(.fileReadUnknown)) }
                }
            }
        }
        guard let type else { throw CocoaError(.fileReadUnsupportedScheme) }
        return try await withCheckedThrowingContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, error in
                guard let url else { continuation.resume(throwing: error ?? CocoaError(.fileReadUnknown)); return }
                continuation.resume(with: Result { try transfer(url) })
            }
        }
    }
}
