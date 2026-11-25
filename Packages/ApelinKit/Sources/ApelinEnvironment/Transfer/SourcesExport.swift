import ApelinCore
import ApelinGit
import ApelinProject
import ApelinProtocol
import ArchiveKit
import CryptoKit
import Darwin
import Foundation

/// 导出可由其他工具解压的源码 ZIP：保留源码、资源、授权文件和已有 Xcode 工程，
/// 不携带应用自己的项目描述、Git 历史或构建产物。
extension TransferService {
    static func isApelinOnly(_ path: String) -> Bool {
        path == ProjectStore.projectFileName
    }

    func sourcesContents(
        _ project: ProjectLocator.Project,
        staging: URL,
        reporter: TaskReporter,
    ) throws -> SourcesCollected {
        let root = project.root
        var repository: GitRepository?
        var metadata = stat()
        let gitFolder = root.appendingPathComponent(".git")
        if lstat(gitFolder.path, &metadata) == 0,
           metadata.st_mode & S_IFMT == S_IFDIR,
           let opened = try? GitRepository(at: root)
        {
            repository = opened
        }
        let ignores = try GitIgnoreRules(
            root: root,
            repository: repository,
            scratch: staging.appendingPathComponent("ignore-rules"),
        )
        let rules = TransferTree.Rules(skip: { path, isDirectory in
            let components = path.split(separator: "/")
            if components.last == ".DS_Store" {
                return true
            }
            // 源码 ZIP 不携带任何仓库元数据，也不携带设备上的构建记录。
            if components.contains(".git") || components.first == "Builds" {
                return true
            }
            if Self.isApelinOnly(path) {
                return true
            }
            return try ignores.ignores(path, isDirectory: isDirectory)
        }, lenient: true)
        let tree = try TransferTree.collect(root, rules: rules, reporter: reporter)
        return SourcesCollected(tree: tree, name: project.name, warnings: tree.leftOut.map { "已排除 \($0)" })
    }

    struct SourcesCollected {
        var tree: TransferTree
        var name: String
        var warnings: [String] = []
    }

    /// 通过临时文件写入并校验，成功后才成为最终导出；取消或失败清理本次目录。
    func exportSources(
        _ prepared: PreparedExport,
        staging: URL,
        reporter: TaskReporter,
    ) async throws -> TransferExport {
        guard let project = prepared.project else {
            throw ApelinError(.badRequest, "源码导出需要指定项目")
        }
        reporter.stage("collecting")
        let collected = try sourcesContents(project, staging: staging, reporter: reporter)
        try reporter.checkCancelled()

        reporter.stage("packing")
        try layout.make(layout.exports)
        let folderName = "sources-" + Self.fileSafe(prepared.id)
        let folder = layout.exports.appendingPathComponent(folderName, isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try layout.make(folder)
        let rootName = Self.fileSafe(collected.name)
        let fileName = rootName + ".zip"
        let partial = folder.appendingPathComponent("." + fileName + ".partial")
        let destination = folder.appendingPathComponent(fileName)
        let digest: String
        let size: Int64
        do {
            try SourcesArchiveWriter(tree: collected.tree, rootName: rootName)
                .write(to: partial, reporter: reporter)
            reporter.stage("verifying")
            let total = try partial.resourceValues(forKeys: [.fileSizeKey]).fileSize.map(Int64.init)
            let throttle = ProgressThrottle()
            reporter.progress("verifying", completed: 0, total: total)
            (digest, size) = try TransferDigest.file(partial) { completed in
                try reporter.checkCancelled()
                if throttle.shouldEmit() {
                    reporter.progress("verifying", completed: completed, total: total)
                }
            }
            reporter.progress("verifying", completed: size, total: size)
            try reporter.checkCancelled()
            guard rename(partial.path, destination.path) == 0 else {
                throw ArchiveExtractor.posix("命名导出文件")
            }
        } catch {
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
        collected.warnings.forEach(reporter.warning)
        return TransferExport(
            path: destination.path,
            exportedPath: folderName + "/" + fileName,
            fileName: fileName,
            size: size,
            sha256: digest,
            summary: TransferSummary(
                formatVersion: TransferManifest.currentFormatVersion,
                kind: .project,
                id: prepared.id,
                name: collected.name,
                createdBy: prepared.createdBy,
                created: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
                fileCount: collected.tree.members.filter { $0.kind != .link }.count,
                payloadBytes: size,
            ),
        )
    }
}

/// ZIP 解压到项目自己的顶层文件夹，不与同一目录下的其他项目混合。
struct SourcesArchiveWriter {
    var tree: TransferTree
    var rootName: String

    /// 不记录源文件的修改时间，使同一棵源码树产生相同归档。
    static let modificationTime: time_t = 0

    func write(to destination: URL, reporter: TaskReporter) throws {
        guard let archive = archive_write_new() else {
            throw ApelinError(.internal, "libarchive：无法创建 ZIP 写入器")
        }
        defer { _ = archive_write_free(archive) }
        try step(archive_write_set_format_zip(archive), archive, "设置 ZIP 格式")
        // 不支持压缩选项时仍可写出未压缩的合法 ZIP。
        _ = archive_write_set_options(archive, "zip:compression=deflate")
        try step(archive_write_open_filename(archive, destination.path), archive, "创建 \(destination.lastPathComponent)")

        try ArchiveExtractor.withUTF8Names {
            try addFolder(rootName, to: archive)
            for member in tree.members {
                try reporter.checkCancelled()
                switch member.kind {
                case .directory:
                    try addFolder(rootName + "/" + member.path, to: archive)
                case .link:
                    // 不跟随链接；项目内目标如需导出，会作为自己的文件成员出现。
                    continue
                case .file:
                    guard let source = tree.sources[member.path] else {
                        throw ApelinError(.internal, "\(member.path) 没有对应源文件")
                    }
                    try addFile(source, member: member, as: rootName + "/" + member.path,
                                to: archive, reporter: reporter)
                }
            }
        }
        try step(archive_write_close(archive), archive, "完成 \(destination.lastPathComponent)")
    }

    private func addFolder(_ name: String, to archive: OpaquePointer) throws {
        guard let entry = archive_entry_new() else {
            throw ApelinError(.internal, "libarchive：无法分配归档条目")
        }
        defer { _ = archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, numericCast(S_IFDIR))
        archive_entry_set_perm(entry, numericCast(0o755))
        archive_entry_set_size(entry, 0)
        archive_entry_set_mtime(entry, Self.modificationTime, 0)
        try step(archive_write_header(archive, entry), archive, "写入 \(name)")
        try step(archive_write_finish_entry(archive), archive, "完成 \(name)")
    }

    private func addFile(
        _ url: URL,
        member: TransferMember,
        as name: String,
        to archive: OpaquePointer,
        reporter: TaskReporter,
    ) throws {
        guard let size = member.size else {
            throw ApelinError(.internal, "\(member.path) 没有对应文件大小")
        }
        // 复用传输模块的安全打开逻辑：拒绝扫描后换成链接或移到项目外的文件。
        let descriptor = try TransferDigest.openFile(url, inside: tree.root)
        defer { close(descriptor) }
        guard let entry = archive_entry_new() else {
            throw ApelinError(.internal, "libarchive：无法分配归档条目")
        }
        defer { _ = archive_entry_free(entry) }
        archive_entry_set_pathname_utf8(entry, name)
        archive_entry_set_filetype(entry, numericCast(S_IFREG))
        archive_entry_set_perm(entry, numericCast(member.executable == true ? 0o755 : 0o644))
        archive_entry_set_size(entry, size)
        archive_entry_set_mtime(entry, Self.modificationTime, 0)
        try step(archive_write_header(archive, entry), archive, "写入 \(name)")
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1 << 20, alignment: 16)
        defer { buffer.deallocate() }
        var hash = SHA256()
        var count: Int64 = 0
        while true {
            try reporter.checkCancelled()
            let read = Darwin.read(descriptor, buffer, 1 << 20)
            guard read >= 0 else { throw ArchiveExtractor.posix("读取 \(name)") }
            if read == 0 { break }
            count += Int64(read)
            guard count <= size else { break }
            hash.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: read))
            var written = 0
            while written < read {
                let result = archive_write_data(archive, buffer + written, read - written)
                guard result > 0 else {
                    throw ApelinError(.internal, "libarchive：\(name) 未完整写入")
                }
                written += result
            }
        }
        guard count == size, TransferDigest.hex(hash.finalize()) == member.sha256 else {
            throw ApelinError(.conflict, "\(member.path) 在导出期间发生变化，请重新导出")
        }
        try step(archive_write_finish_entry(archive), archive, "完成 \(name)")
    }

    private func step(_ status: Int32, _ archive: OpaquePointer, _ what: String) throws {
        guard status >= ARCHIVE_OK else {
            let reason = archive_error_string(archive).map { String(cString: $0) } ?? "libarchive 错误 \(status)"
            throw ApelinError(.internal, "无法\(what)：\(reason)")
        }
    }
}
