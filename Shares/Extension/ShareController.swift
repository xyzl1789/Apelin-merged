import UIKit
import UniformTypeIdentifiers

/// 扩展只登记投递；不启动会话、不上传附件，也不调用主应用的服务。
@objc(ShareController)
final class ShareController: UITableViewController {
    private var destinations: [ShareTransfer.Destination] = []
    private var selected: IndexPath = IndexPath(row: 0, section: 0)
    private var saving = false
    private weak var addButton: UIButton?

    override func viewDidLoad() {
        super.viewDidLoad()
        if let root = ShareTransfer.root { destinations = ShareTransfer.destinations(at: root) }
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "destination")
        tableView.tableHeaderView = makeHeader()
    }

    private func makeHeader() -> UIView {
        let header = UIView(frame: CGRect(x: 0, y: 0, width: 320, height: 56))
        let cancel = UIButton(type: .system, primaryAction: UIAction(title: "取消") { [weak self] _ in
            self?.extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
        })
        let send = UIButton(type: .system, primaryAction: UIAction(title: "加入草稿") { [weak self] _ in self?.save() })
        let buttons = UIStackView(arrangedSubviews: [cancel, UIView(), send])
        addButton = send
        buttons.translatesAutoresizingMaskIntoConstraints = false
        header.addSubview(buttons)
        NSLayoutConstraint.activate([
            buttons.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: header.topAnchor),
            buttons.bottomAnchor.constraint(equalTo: header.bottomAnchor),
        ])
        return header
    }

    override func numberOfSections(in _: UITableView) -> Int { 2 }

    override func tableView(_: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : destinations.count
    }

    override func tableView(_: UITableView, titleForHeaderInSection section: Int) -> String? {
        section == 0 ? "分享到 Apelin" : (destinations.isEmpty ? nil : "选择会话")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "destination", for: indexPath)
        var content = UIListContentConfiguration.subtitleCell()
        if indexPath.section == 0 {
            content.text = "新建会话"
            content.secondaryText = "返回 Apelin 后查看草稿，不会自动发送"
        } else {
            let item = destinations[indexPath.row]
            content.text = item.title
            content.secondaryText = item.project
        }
        cell.contentConfiguration = content
        cell.accessoryType = indexPath == selected ? .checkmark : .none
        if indexPath == selected { cell.accessibilityTraits.insert(.selected) }
        else { cell.accessibilityTraits.remove(.selected) }
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !saving else { return }
        selected = indexPath
        tableView.reloadData()
    }

    private func save() {
        guard !saving, let context = extensionContext else { return }
        saving = true
        tableView.tableHeaderView?.isUserInteractionEnabled = false
        addButton?.isEnabled = false
        addButton?.setTitle("暂存中…", for: .normal)
        let target = selected.section == 0 ? nil : destinations[selected.row].id
        let items = context.inputItems.compactMap { $0 as? NSExtensionItem }
        Task {
            do {
                try await stage(items, target: target)
                let alert = UIAlertController(title: "已加入分享队列", message: "返回 Apelin 后即可查看草稿。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "完成", style: .default) { _ in
                    context.completeRequest(returningItems: nil, completionHandler: nil)
                })
                present(alert, animated: true)
            } catch {
                saving = false
                tableView.tableHeaderView?.isUserInteractionEnabled = true
                addButton?.isEnabled = true
                addButton?.setTitle("加入草稿", for: .normal)
                let alert = UIAlertController(title: "未能加入草稿", message: (error as? ShareFailure)?.message ?? "无法暂存分享内容，请检查可用空间后重试。", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "好", style: .default))
                present(alert, animated: true)
            }
        }
    }

    private struct ShareFailure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    private func stage(_ items: [NSExtensionItem], target: UUID?) async throws {
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
        try ShareTransfer.write(.init(target: target, text: text.joined(separator: "\n\n"), files: files, createdAt: Date()), to: stage)
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
