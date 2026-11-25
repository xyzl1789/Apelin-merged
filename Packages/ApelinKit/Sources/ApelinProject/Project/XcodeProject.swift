import ApelinCore
import Foundation

/// 为新项目生成可在 Mac 上继续编辑的原生 Xcode 工程。
/// 仅在创建时写入；已有工程交给 Xcode 管理，不会被重新生成覆盖。
/// 打包、设备签名和 vendored Swift 模块仍由设备端处理。
public enum XcodeProject {
    public struct Written: Sendable, Equatable {
        /// `.xcodeproj` 目录的绝对路径。
        public var path: String
        /// 按项目产物顺序排列的目标名称。
        public var targets: [String]

        public init(path: String, targets: [String]) {
            self.path = path
            self.targets = targets
        }
    }

    /// 移除不能安全用于工程目录名称的分隔符。
    public static func folderName(_ name: String) -> String {
        let cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Project" : cleaned
    }

    /// 写入工程和配套的 `Xcode/`，绝不替换已有工程。
    public static func write(
        _ project: ProjectDocument,
        name: String,
        root: URL,
        catalog: ExtensionCatalog? = nil,
    ) throws -> Written {
        guard !project.products.isEmpty else {
            throw ProjectFiles.Refused(description: "\(name) 没有可构建的产物")
        }
        let folder = folderName(name)
        let bundle = root.appendingPathComponent(folder + ".xcodeproj", isDirectory: true)
        var info = stat()
        guard lstat(bundle.path, &info) != 0 else {
            throw ProjectFiles.Refused(description: "\(folder).xcodeproj 已存在")
        }
        let builder = Builder(project: project, folder: folder, root: root, catalog: catalog)
        try builder.copySupport()
        let output = try builder.make()
        try builder.write(output, into: bundle)
        return Written(path: bundle.path, targets: builder.targetNames)
    }

    /// 优先使用 roothide 的链接桩与宏，两种 bootstrap 的桩不可混用。
    static func preferredBootstrap(_ project: ProjectDocument) -> Bootstrap? {
        if project.architectures.roothide != nil { return .roothide }
        if project.architectures.rootless != nil { return .rootless }
        return nil
    }

    /// 保持 bootstrap 顺序，汇总去重后的架构。
    static func architectures(_ project: ProjectDocument) -> [Architecture] {
        var seen: Set<Architecture> = []
        var out: [Architecture] = []
        for bootstrap in Bootstrap.allCases {
            for arch in project.architectures[bootstrap] ?? [] where !seen.contains(arch) {
                seen.insert(arch)
                out.append(arch)
            }
        }
        return out
    }

    /// 稳定的 24 位十六进制对象 ID，避免相同输入生成整份差异。
    static func hexID(_ seed: String) -> String {
        var first: UInt64 = 0xcbf2_9ce4_8422_2325
        var second: UInt64 = 0x8422_2325_cbf2_9ce4
        for byte in seed.utf8 {
            first = (first ^ UInt64(byte)) &* 0x0000_0100_0000_01b3
            second = (second &+ UInt64(byte)) &* 0x0000_0100_0000_01b3
        }
        return String(format: "%016llX%08llX", first, UInt32(truncatingIfNeeded: second))
    }
}

// MARK: - 工程生成

private final class Builder {
    enum Kind {
        case debug, release
    }

    /// 每个产物仅展开一次文件列表，使导航树与构建阶段一致。
    struct Plan {
        var product: ProjectDocument.Product
        var targetName: String
        var sources: [String]
        var resources: [String]
        var extras: [String]
    }

    struct Output {
        var pbxproj: String
        var schemes: [(name: String, text: String)]
    }

    let project: ProjectDocument
    let folder: String
    let root: URL
    let catalog: ExtensionCatalog?
    let bootstrap: Bootstrap

    private var supportIncludes: [String] = []
    private var supportLibraries: [String] = []
    private var supportRPaths: [String] = []
    private var supportFiles: [String] = []

    private var sections: [String: [(id: String, body: [String])]] = [:]
    private var objectIDs: [String: String] = [:]
    private var usedIDs: Set<String> = []
    private var schemes: [(name: String, text: String)] = []
    private(set) var targetNames: [String] = []

    init(project: ProjectDocument, folder: String, root: URL, catalog: ExtensionCatalog?) {
        self.project = project
        self.folder = folder
        self.root = root
        self.catalog = catalog
        bootstrap = XcodeProject.preferredBootstrap(project) ?? .roothide
    }

    // MARK: 对象

    @objc dynamic private func id(_ key: String) -> String {
        if let existing = objectIDs[key] { return existing }
        var value = XcodeProject.hexID(project.projectID + "|" + key)
        while usedIDs.contains(value) {
            value = XcodeProject.hexID(value + "|")
        }
        objectIDs[key] = value
        usedIDs.insert(value)
        return value
    }

    @objc dynamic private func add(_ isa: String, _ objectID: String, _ body: [String]) {
        sections[isa, default: []].append((objectID, body))
    }

    // MARK: 扩展支持

    /// 把扩展中的头文件与链接桩复制到工程，Mac 无需访问设备目录。
    @objc(apelin_copySupportAndReturnError:) dynamic func copySupport() throws {
        for product in project.products {
            for reference in product.extensionSupport ?? [] {
                guard let found = catalog?.usableExtension(reference.extension),
                      let component = found.manifest?.support?[reference.component]
                else { continue }
                for directory in component.includeDirectories ?? [] {
                    let relative = try copy(directory, in: found.root)
                    if !supportIncludes.contains(relative) { supportIncludes.append(relative) }
                }
                if let stubs = component.linkStubDirectories?[bootstrap] {
                    let relative = try copy(stubs, in: found.root)
                    if !supportLibraries.contains(relative) { supportLibraries.append(relative) }
                }
                let prefix = bootstrap == .rootless ? "/var/jb" : ""
                for path in component.rpaths?[bootstrap] ?? [] {
                    let resolved = path.replacingOccurrences(of: "@PREFIX@", with: prefix)
                    if !supportRPaths.contains(resolved) { supportRPaths.append(resolved) }
                }
            }
        }
    }

    /// 仅复制普通文件，不跟随符号链接，也不复制设备节点。
    @objc(apelin_copy:in:error:) dynamic private func copy(_ directory: String, in extensionRoot: URL) throws -> String {
        let trimmed = directory.split(separator: "/").joined(separator: "/")
        let destination = "Xcode/Support/" + trimmed
        let source = try ProjectFiles.resolve(directory, in: extensionRoot)
        guard let walker = FileManager.default.enumerator(atPath: source) else {
            throw ProjectFiles.Refused(description: "无法读取 \(directory)")
        }
        var copied = false
        while let relative = walker.nextObject() as? String {
            var info = stat()
            let path = source + "/" + relative
            guard lstat(path, &info) == 0 else { continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                continue
            case S_IFREG:
                let relativeInProject = destination + "/" + relative
                try write(Data(contentsOf: URL(fileURLWithPath: path)), to: relativeInProject)
                if !supportFiles.contains(relativeInProject) { supportFiles.append(relativeInProject) }
                copied = true
            default:
                walker.skipDescendants()
            }
        }
        guard copied else {
            throw ProjectFiles.Refused(description: "\(directory) 中没有普通文件")
        }
        return destination
    }

    /// 在创建过程独占的暂存目录中逐级写入，拒绝以链接或文件充当目录。
    private func write(_ data: Data, to relative: String) throws {
        let parts = relative.split(separator: "/").map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw ProjectFiles.Refused(description: "\(relative)：路径不可用")
        }
        var current = root.path
        for part in parts.dropLast() {
            current += "/" + part
            var info = stat()
            if lstat(current, &info) == 0 {
                guard info.st_mode & S_IFMT == S_IFDIR else {
                    throw ProjectFiles.Refused(description: "\(relative)：目录位置已被文件占用")
                }
            } else if mkdir(current, 0o755) != 0, errno != EEXIST {
                throw ProjectFiles.Refused(description: "\(relative)：\(String(cString: strerror(errno)))")
            }
        }
        try data.write(to: URL(fileURLWithPath: current + "/" + parts[parts.count - 1]), options: .atomic)
    }

    // MARK: 工程

    private func plan(for product: ProjectDocument.Product) throws -> Plan {
        let sources = try ProjectGlob.expand(product.sources, in: root).map(\.relative)
        let resources = try ProjectGlob.expand(product.resources ?? [], in: root).map(\.relative)
        var extras: [String] = []
        for path in [product.infoPlist, product.entitlements, product.bridgingHeader] {
            if let path, !extras.contains(path) { extras.append(path) }
        }
        var name = product.name
        if targetNames.contains(name) { name = "\(product.name)-\(product.id)" }
        targetNames.append(name)
        return Plan(product: product, targetName: name, sources: sources, resources: resources, extras: extras)
    }

    func make() throws -> Output {
        var plans: [Plan] = []
        for product in project.products {
            plans.append(try plan(for: product))
        }

        var everyFile: Set<String> = [ProjectStore.projectFileName]
        for plan in plans {
            everyFile.formUnion(plan.sources)
            everyFile.formUnion(plan.resources)
            everyFile.formUnion(plan.extras)
        }
        everyFile.formUnion(supportFiles)

        var references: [String: String] = [:]
        var products: [(id: String, name: String)] = []
        for plan in plans {
            let reference = id("product:" + plan.product.id)
            references[plan.product.id] = reference
            let file = productFileName(plan.product)
            products.append((reference, file))
            add("PBXFileReference", reference, [
                "isa = PBXFileReference;",
                "explicitFileType = \(Setting.text(fileType(ofProduct: plan.product.type)).render());",
                "includeInIndex = 0;",
                "path = \(Setting.text(file).render());",
                "sourceTree = BUILT_PRODUCTS_DIR;",
            ])
        }
        let productsGroup = id("group:Products")
        add("PBXGroup", productsGroup, groupBody(
            name: "Products",
            path: nil,
            children: products.sorted { $0.name < $1.name },
        ))

        let rootGroup = emitGroups(files: everyFile.sorted(), products: (productsGroup, "Products"))

        let projectObject = id("project")
        let projectList = id("list:project")
        let projectDebug = id("config:project:Debug")
        let projectRelease = id("config:project:Release")
        add("XCBuildConfiguration", projectDebug, configurationBody(projectSettings(.debug), name: "Debug"))
        add("XCBuildConfiguration", projectRelease, configurationBody(projectSettings(.release), name: "Release"))
        add("XCConfigurationList", projectList, listBody(debug: projectDebug, release: projectRelease))

        var targets: [(id: String, name: String)] = []
        for plan in plans {
            let target = id("target:" + plan.product.id)
            targets.append((target, plan.targetName))
            let phases = emitPhases(plan)
            let list = id("list:" + plan.product.id)
            let debug = id("config:\(plan.product.id):Debug")
            let release = id("config:\(plan.product.id):Release")
            add("XCBuildConfiguration", debug, configurationBody(planSettings(plan, .debug), name: "Debug"))
            add("XCBuildConfiguration", release, configurationBody(planSettings(plan, .release), name: "Release"))
            add("XCConfigurationList", list, listBody(debug: debug, release: release))
            add("PBXNativeTarget", target, [
                "isa = PBXNativeTarget;",
                "buildConfigurationList = \(list);",
                "buildPhases = (",
                phases.map { "\t\($0)," }.joined(separator: "\n"),
                ");",
                "buildRules = (",
                ");",
                "dependencies = (",
                ");",
                "name = \(Setting.text(plan.targetName).render());",
                "productName = \(Setting.text(plan.product.name).render());",
                "productReference = \(references[plan.product.id]!);",
                "productType = \(Setting.text(productType(plan.product.type)).render());",
            ])
            schemes.append((plan.targetName, scheme(
                target: target,
                name: plan.targetName,
                buildable: productFileName(plan.product),
                launchable: plan.product.type == .app,
            )))
        }

        var attributes = [
            "BuildIndependentTargetsInParallel = 1;",
            "LastUpgradeCheck = 1540;",
            "TargetAttributes = {",
        ]
        for target in targets {
            attributes.append("\t\(target.id) = {")
            attributes.append("\t\tCreatedOnToolsVersion = 15.0;")
            attributes.append("\t};")
        }
        attributes.append("};")

        add("PBXProject", projectObject, [
            "isa = PBXProject;",
            "attributes = {",
            attributes.map { "\t\($0)" }.joined(separator: "\n"),
            "};",
            "buildConfigurationList = \(projectList);",
            "compatibilityVersion = \"Xcode 14.0\";",
            "developmentRegion = en;",
            "hasScannedForEncodings = 0;",
            "knownRegions = (",
            "\ten,",
            "\tBase,",
            ");",
            "mainGroup = \(rootGroup);",
            "productRefGroup = \(productsGroup);",
            "projectDirPath = \"\";",
            "projectRoot = \"\";",
            "targets = (",
            targets.map { "\t\($0.id)," }.joined(separator: "\n"),
            ");",
        ])

        return Output(pbxproj: pbxproj(rootObject: projectObject), schemes: schemes)
    }

    /// 依次编译源码、链接框架、复制 bundle 资源。
    private func emitPhases(_ plan: Plan) -> [String] {
        let sources = id("phase:sources:" + plan.product.id)
        add("PBXSourcesBuildPhase", sources, phaseBody(
            isa: "PBXSourcesBuildPhase",
            files: plan.sources.filter(isCompilable).map { path in
                let build = id("build:\(plan.product.id):\(path)")
                add("PBXBuildFile", build, ["isa = PBXBuildFile;", "fileRef = \(id("file:" + path));"])
                return build
            },
        ))

        let frameworks = id("phase:frameworks:" + plan.product.id)
        add("PBXFrameworksBuildPhase", frameworks, phaseBody(isa: "PBXFrameworksBuildPhase", files: []))

        switch plan.product.type {
        case .app, .appex, .bundle:
            let resources = id("phase:resources:" + plan.product.id)
            let copied = plan.resources.filter { path in
                path != plan.product.infoPlist && !isCompilable(path)
            }
            add("PBXResourcesBuildPhase", resources, phaseBody(
                isa: "PBXResourcesBuildPhase",
                files: copied.map { path in
                    let build = id("resource:\(plan.product.id):\(path)")
                    add("PBXBuildFile", build, ["isa = PBXBuildFile;", "fileRef = \(id("file:" + path));"])
                    return build
                },
            ))
            return [sources, frameworks, resources]
        case .dylib, .executable:
            return [sources, frameworks]
        }
    }

    @objc dynamic private func phaseBody(isa: String, files: [String]) -> [String] {
        var body = [
            "isa = \(isa);",
            "buildActionMask = 2147483647;",
            "files = (",
        ]
        body += files.map { "\t\($0)," }
        body += [
            ");",
            "runOnlyForDeploymentPostprocessing = 0;",
        ]
        return body
    }

    private func groupBody(
        name: String?,
        path: String?,
        children: [(id: String, name: String)],
    ) -> [String] {
        var body = ["isa = PBXGroup;", "children = ("]
        body += children.map { "\t\($0.id) /* \($0.name) */," }
        body += [");"]
        if let name {
            body.append("name = \(Setting.text(name).render());")
        }
        if let path {
            body.append("path = \(Setting.text(path).render());")
        }
        body.append("sourceTree = \"<group>\";")
        return body
    }

    /// 根据磁盘目录层级建立导航树，最后列出 Products 分组。
    private func emitGroups(files: [String], products: (id: String, name: String)) -> String {
        var directories: Set<String> = []
        var entries: [String: [String]] = [:]
        for path in files {
            let parts = path.split(separator: "/").map(String.init)
            var parent = ""
            for part in parts.dropLast() {
                let next = parent.isEmpty ? part : parent + "/" + part
                if directories.insert(next).inserted {
                    entries[parent, default: []].append(next)
                }
                parent = next
            }
            entries[parent, default: []].append(path)
            add("PBXFileReference", id("file:" + path), [
                "isa = PBXFileReference;",
                "lastKnownFileType = \(Setting.text(fileType(of: path)).render());",
                "path = \(Setting.text((path as NSString).lastPathComponent).render());",
                "sourceTree = \"<group>\";",
            ])
        }
        func emit(_ directory: String) -> String {
            let groupID = id("group:" + directory)
            let children: [(id: String, name: String)] = (entries[directory] ?? []).sorted().map { entry in
                let name = (entry as NSString).lastPathComponent
                return directories.contains(entry) ? (emit(entry), name) : (id("file:" + entry), name)
            }
            add("PBXGroup", groupID, groupBody(
                name: nil,
                path: (directory as NSString).lastPathComponent,
                children: children,
            ))
            return groupID
        }
        let rootID = id("group:")
        var top: [(id: String, name: String)] = (entries[""] ?? []).sorted().map { entry in
            let name = (entry as NSString).lastPathComponent
            return directories.contains(entry) ? (emit(entry), name) : (id("file:" + entry), name)
        }
        top.append(products)
        add("PBXGroup", rootID, groupBody(name: nil, path: nil, children: top))
        return rootID
    }

    private func configurationBody(_ settings: [(String, Setting)], name: String) -> [String] {
        var body = ["isa = XCBuildConfiguration;", "buildSettings = {"]
        // 条件键包含方括号和等号，必须像值一样引用，否则 OpenStep 无法解析。
        body += settings.sorted { $0.0 < $1.0 }
            .map { "\t\(Setting.quote($0.0)) = \($0.1.render());" }
        body += ["};", "name = \(name);"]
        return body
    }

    @objc dynamic private func listBody(debug: String, release: String) -> [String] {
        [
            "isa = XCConfigurationList;",
            "buildConfigurations = (",
            "\t\(debug),",
            "\t\(release),",
            ");",
            "defaultConfigurationIsVisible = 0;",
            "defaultConfigurationName = Release;",
        ]
    }

    // MARK: 构建设置

    private func projectSettings(_ kind: Kind) -> [(String, Setting)] {
        let configuration = project.configuration(kind == .debug ? .debug : .release)
        var out: [(String, Setting)] = [
            ("ALWAYS_SEARCH_USER_PATHS", .text("NO")),
            ("ARCHS", .list(XcodeProject.architectures(project).map(\.rawValue))),
            ("CLANG_CXX_LANGUAGE_STANDARD", .text("gnu++20")),
            ("CLANG_ENABLE_MODULES", .text("YES")),
            ("CLANG_ENABLE_OBJC_ARC", .text("YES")),
            ("CODE_SIGNING_ALLOWED", .text("NO")),
            // 设备产物不在 Mac 签名；模拟器必须 ad-hoc 签名才能启动。
            ("CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]", .text("YES")),
            ("CODE_SIGNING_REQUIRED", .text("NO")),
            ("CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]", .text("YES")),
            ("CODE_SIGN_IDENTITY", .text("")),
            ("CODE_SIGN_IDENTITY[sdk=iphonesimulator*]", .text("-")),
            ("COPY_PHASE_STRIP", .text("NO")),
            ("ENABLE_STRICT_OBJC_MSGSEND", .text("YES")),
            ("ENABLE_USER_SCRIPT_SANDBOXING", .text("NO")),
            ("GCC_C_LANGUAGE_STANDARD", .text("gnu17")),
            ("GCC_NO_COMMON_BLOCKS", .text("YES")),
            ("GCC_OPTIMIZATION_LEVEL", .text(configuration.optimization)),
            ("GCC_PREPROCESSOR_DEFINITIONS", .list(defines(kind))),
            ("IPHONEOS_DEPLOYMENT_TARGET", .text(project.deploymentTarget)),
            ("SDKROOT", .text("iphoneos")),
            // 单列设备平台会导致模拟器误用设备二进制，必须保留独立平台。
            ("SUPPORTED_PLATFORMS", .text("iphoneos iphonesimulator")),
            ("SWIFT_OPTIMIZATION_LEVEL", .text(swiftOptimization(configuration.optimization))),
            ("SWIFT_VERSION", .text("5.0")),
            ("TARGETED_DEVICE_FAMILY", .text("1,2")),
        ]
        if kind == .debug {
            out += [
                ("DEBUG_INFORMATION_FORMAT", .text("dwarf")),
                ("ENABLE_TESTABILITY", .text("YES")),
                ("ONLY_ACTIVE_ARCH", .text("YES")),
            ]
        } else {
            out.append(("DEBUG_INFORMATION_FORMAT", .text(configuration.debugInfo ? "dwarf-with-dsym" : "dwarf")))
        }
        return out
    }

    /// 保留设备构建所定义的宏；Mac 上没有构建记录，构建 ID 固定为 xcode。
    private func defines(_ kind: Kind) -> [String] {
        let configuration = project.configuration(kind == .debug ? .debug : .release)
        var out = [
            "APELIN_BUILD_ID=\"xcode\"",
            "APELIN_PACKAGE_ID=\"\(project.package.id)\"",
            "APELIN_VERSION=\"\(project.package.version)\"",
            "APELIN_BOOTSTRAP_\(bootstrap.rawValue.uppercased())=1",
            "APELIN_CONFIGURATION_\(kind == .debug ? "DEBUG" : "RELEASE")=1",
        ]
        out += (configuration.defines ?? [:]).sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return out
    }

    @objc dynamic private func swiftOptimization(_ level: String) -> String {
        switch level {
        case "0": "-Onone"
        case "s", "z": "-Osize"
        default: "-O"
        }
    }

    private func planSettings(_ plan: Plan, _ kind: Kind) -> [(String, Setting)] {
        let product = plan.product
        let configuration = project.configuration(kind == .debug ? .debug : .release)
        var out: [(String, Setting)] = [
            ("CLANG_ENABLE_OBJC_ARC", .text(product.objcARC == true ? "YES" : "NO")),
            ("PRODUCT_NAME", .text(product.name)),
        ]
        if let standard = product.cxxStandard {
            out.append(("CLANG_CXX_LANGUAGE_STANDARD", .text(standard)))
        }
        var includes = ["$(inherited)"]
        includes += (product.headerSearchPaths ?? []).map { "$(SRCROOT)/\($0)" }
        includes += supportIncludes.map { "$(SRCROOT)/\($0)" }
        out.append(("HEADER_SEARCH_PATHS", .list(includes)))

        if let bridging = product.bridgingHeader {
            out.append(("SWIFT_OBJC_BRIDGING_HEADER", .text("$(SRCROOT)/" + bridging)))
        }
        var flags = ["$(inherited)"]
        flags += (product.frameworks ?? []).flatMap { ["-framework", $0] }
        flags += (product.weakFrameworks ?? []).flatMap { ["-weak_framework", $0] }
        flags += (product.libraries ?? []).map { "-l" + $0 }
        flags += configuration.linkFlags ?? []
        out.append(("OTHER_LDFLAGS", .list(flags)))

        var libraries = ["$(inherited)"]
        libraries += (product.librarySearchPaths ?? []).map { "$(SRCROOT)/\($0)" }
        libraries += supportLibraries.map { "$(SRCROOT)/\($0)" }
        out.append(("LIBRARY_SEARCH_PATHS", .list(libraries)))

        var frameworks = ["$(inherited)"]
        frameworks += (product.frameworkSearchPaths ?? []).map { "$(SRCROOT)/\($0)" }
        // 支持目录同时容纳 dylib 与 framework 形式的链接桩。
        for directory in supportLibraries where !frameworks.contains("$(SRCROOT)/\(directory)") {
            frameworks.append("$(SRCROOT)/\(directory)")
        }
        out.append(("FRAMEWORK_SEARCH_PATHS", .list(frameworks)))

        if !supportRPaths.isEmpty {
            out.append(("LD_RUNPATH_SEARCH_PATHS", .list(supportRPaths)))
        }
        if let flags = configuration.cFlags, !flags.isEmpty {
            out.append(("OTHER_CFLAGS", .list(flags)))
        }
        if let flags = configuration.cxxFlags, !flags.isEmpty {
            out.append(("OTHER_CPLUSPLUSFLAGS", .list(flags)))
        }
        if let flags = configuration.swiftFlags, !flags.isEmpty {
            out.append(("OTHER_SWIFT_FLAGS", .list(flags)))
        }
        if let path = product.infoPlist {
            out.append(("INFOPLIST_FILE", .text(path)))
        }
        if let path = product.entitlements {
            out.append(("CODE_SIGN_ENTITLEMENTS", .text(path)))
        }
        switch product.type {
        case .app, .appex:
            out.append(("PRODUCT_BUNDLE_IDENTIFIER", .text(project.package.id)))
            out.append(("SKIP_INSTALL", .text("NO")))
        case .bundle:
            out.append(("MACH_O_TYPE", .text("mh_bundle")))
            out.append(("WRAPPER_EXTENSION", .text("bundle")))
            out.append(("SKIP_INSTALL", .text("YES")))
        case .dylib:
            out.append(("LD_DYLIB_INSTALL_NAME", .text(product.effectiveInstallName)))
            out.append(("SKIP_INSTALL", .text("YES")))
        case .executable:
            out.append(("SKIP_INSTALL", .text("YES")))
        }
        return out
    }

    // MARK: 文本

    @objc dynamic private func pbxproj(rootObject: String) -> String {
        var out = "// !$*UTF8*$!\n{\n"
        out += "\tarchiveVersion = 1;\n\tclasses = {\n\t};\n\tobjectVersion = 56;\n\tobjects = {\n"
        for isa in sections.keys.sorted() {
            out += "\n/* Begin \(isa) section */\n"
            for object in sections[isa]!.sorted(by: { $0.id < $1.id }) {
                out += "\t\t\(object.id) = {\n"
                for line in object.body {
                    out += line.isEmpty ? "\n" : "\t\t\t\(line)\n"
                }
                out += "\t\t};\n"
            }
            out += "/* End \(isa) section */\n"
        }
        out += "\t};\n\trootObject = \(rootObject);\n}\n"
        return out
    }

    @objc dynamic private func scheme(target: String, name: String, buildable: String, launchable: Bool) -> String {
        let reference = """
        <BuildableReference
                     BuildableIdentifier = "primary"
                     BlueprintIdentifier = "\(target)"
                     BuildableName = "\(buildable)"
                     BlueprintName = "\(name)"
                     ReferencedContainer = "container:\(folder).xcodeproj">
                  </BuildableReference>
        """
        let runnable = launchable
            ? """
                  <BuildableProductRunnable
                     runnableDebuggingMode = "0">
                     \(reference)
                  </BuildableProductRunnable>
            """
            : ""
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <Scheme
           LastUpgradeVersion = "1540"
           version = "1.7">
           <BuildAction
              parallelizeBuildables = "YES"
              buildImplicitDependencies = "YES">
              <BuildActionEntries>
                 <BuildActionEntry
                    buildForTesting = "YES"
                    buildForRunning = "YES"
                    buildForProfiling = "YES"
                    buildForArchiving = "YES"
                    buildForAnalyzing = "YES">
                    \(reference)
                 </BuildActionEntry>
              </BuildActionEntries>
           </BuildAction>
           <TestAction
              buildConfiguration = "Debug"
              selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
              selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
              shouldUseLaunchSchemeArgsEnv = "YES">
              <Testables>
              </Testables>
           </TestAction>
           <LaunchAction
              buildConfiguration = "Debug"
              selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB"
              selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB"
              launchStyle = "0"
              useCustomWorkingDirectory = "NO"
              ignoresPersistentStateOnLaunch = "NO"
              debugDocumentVersioning = "YES"
              debugServiceExtension = "internal"
              allowLocationSimulation = "YES">
        \(runnable)
           </LaunchAction>
           <ProfileAction
              buildConfiguration = "Release"
              shouldUseLaunchSchemeArgsEnv = "YES"
              savedToolIdentifier = ""
              useCustomWorkingDirectory = "NO"
              debugDocumentVersioning = "YES">
           </ProfileAction>
           <AnalyzeAction
              buildConfiguration = "Debug">
           </AnalyzeAction>
           <ArchiveAction
              buildConfiguration = "Release"
              revealArchiveInOrganizer = "YES">
           </ArchiveAction>
        </Scheme>

        """
    }

    // MARK: 文件

    func write(_ output: Output, into bundle: URL) throws {
        try write(Data(output.pbxproj.utf8), to: bundle.lastPathComponent + "/project.pbxproj")
        let workspace = """
        <?xml version="1.0" encoding="UTF-8"?>
        <Workspace
           version = "1.0">
           <FileRef
              location = "self:">
           </FileRef>
        </Workspace>

        """
        try write(
            Data(workspace.utf8),
            to: bundle.lastPathComponent + "/project.xcworkspace/contents.xcworkspacedata",
        )
        for scheme in output.schemes {
            try write(
                Data(scheme.text.utf8),
                to: bundle.lastPathComponent + "/xcshareddata/xcschemes/\(scheme.name).xcscheme",
            )
        }
        try write(Data(Self.readme(name: folder).utf8), to: "Xcode/README.md")
    }

    @objc dynamic static func readme(name: String) -> String {
        """
        # Xcode

        在 Mac 上打开 `\(name).xcodeproj` 即可继续编辑。工程记录了创建时的文件；
        此后由 Xcode 管理，不会被重新生成覆盖。在 Xcode 中添加的文件随工程一起
        通过 Git 同步回设备；在设备上新增的文件需要手动添加到 Xcode 工程。

        设备构建不在 Mac 上签名，生成未签名二进制。模拟器使用独立的平台产物，
        并自动进行 ad-hoc 签名，不需要开发者证书。越狱专用的框架、链接桩和接口
        不保证能在模拟器运行。

        `.deb` 的安装布局、`.ipa` 打包、`ldid` 签名和越狱权限仍需在设备端处理。
        vendored Swift 模块没有对应的 Xcode 目标，需要在 Mac 上另行配置。

        `Support/` 保存随工程复制的开发头文件与链接桩，例如 `substrate.h` 和
        `libsubstrate.tbd`，因此 Mac 不需要读取设备上的扩展目录。

        """
    }

    private func productFileName(_ product: ProjectDocument.Product) -> String {
        switch product.type {
        case .app: product.name + ".app"
        case .appex: product.name + ".appex"
        case .dylib: product.name + ".dylib"
        case .bundle: product.name + ".bundle"
        case .executable: product.name
        }
    }

    private func productType(_ type: ProductType) -> String {
        switch type {
        case .app: "com.apple.product-type.application"
        case .appex: "com.apple.product-type.app-extension"
        case .dylib: "com.apple.product-type.library.dynamic"
        case .bundle: "com.apple.product-type.bundle"
        case .executable: "com.apple.product-type.tool"
        }
    }

    private func fileType(ofProduct type: ProductType) -> String {
        switch type {
        case .app: "wrapper.application"
        case .appex: "wrapper.app-extension"
        case .dylib: "compiled.mach-o.dylib"
        case .bundle: "wrapper.cfbundle"
        case .executable: "compiled.mach-o.executable"
        }
    }

    @objc dynamic private func fileType(of path: String) -> String {
        switch (path as NSString).pathExtension {
        case "m": "sourcecode.c.objc"
        case "mm": "sourcecode.cpp.objcpp"
        case "c": "sourcecode.c.c"
        case "cc", "cpp", "cxx", "C": "sourcecode.cpp.cpp"
        case "h", "hh", "hpp", "hxx": "sourcecode.c.h"
        case "swift": "sourcecode.swift"
        case "plist": "text.plist.xml"
        case "entitlements": "text.plist.entitlements"
        case "png": "image.png"
        case "jpg", "jpeg": "image.jpeg"
        case "json": "text.json"
        case "md": "net.daringfireball.markdown"
        case "tbd": "sourcecode.text-based-dylib-definition"
        case "sh": "text.script.sh"
        case "py": "text.script.python"
        default: "text"
        }
    }

    @objc dynamic private func isCompilable(_ path: String) -> Bool {
        switch (path as NSString).pathExtension {
        case "m", "mm", "c", "cc", "cpp", "cxx", "C", "swift": true
        default: false
        }
    }
}

// MARK: - 设置序列化

private enum Setting {
    case text(String)
    case list([String])

    func render() -> String {
        switch self {
        case let .text(value): Self.quote(value)
        case let .list(values): "( " + values.map(Self.quote).joined(separator: ", ") + " )"
        }
    }

    /// 只有连续字母、数字、下划线、点、斜杠可不加引号，其余字符均转义。
    static func quote(_ text: String) -> String {
        let plain = !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a" ... "z", "A" ... "Z", "0" ... "9", "_", ".", "/": true
            default: false
            }
        }
        if plain { return text }
        var out = "\""
        for character in text {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            default: out.append(character)
            }
        }
        return out + "\""
    }
}
