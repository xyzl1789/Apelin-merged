import ApelinCore
@testable import ApelinProject
import Foundation
import XCTest

/// 对生成工程按 OpenStep 格式回读，验证原生目标、资源、支持文件与签名设置。
final class XcodeProjectTests: XCTestCase {
    // 直接构造模板形状的输入，独立验证生成器，不依赖模板自身的内容变化。
    private static let tweak = """
    {
      "schemaVersion": 1,
      "projectID": "3f1c2a44-0d6e-4c31-9a3d-2b1f0e8c7d55",
      "kind": "tweak",
      "template": {
        "extensionID": "wiki.qaq.apelin.dev.tweak", "templateID": "objc-hook",
        "version": "0.1.1",
        "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
      },
      "environment": { "toolchain": { "id": "t", "digest": "sha256:00" }, "sdk": { "id": "s", "digest": "sha256:00" } },
      "language": "objc",
      "deploymentTarget": "16.0",
      "architectures": { "rootless": ["arm64", "arm64e"], "roothide": ["arm64e"] },
      "configurations": {
        "Debug": { "optimization": "0", "debugInfo": true, "defines": { "DEBUG": "1" } },
        "Release": { "optimization": "2", "debugInfo": true }
      },
      "products": [{
        "id": "tweak", "type": "dylib", "name": "SmokeTweak",
        "sources": ["Sources/*.m"], "headerSearchPaths": ["Sources"], "objcARC": true,
        "frameworks": ["Foundation", "UIKit"], "libraries": ["substrate"],
        "extensionSupport": [{ "extension": "wiki.qaq.apelin.dev.tweak", "component": "substrate" }]
      }],
      "build": { "steps": [{ "type": "compile", "product": "tweak" }, { "type": "link", "product": "tweak" }] },
      "package": {
        "id": "com.xyzl.xcode-smoke", "name": "回归工程", "version": "0.0.1", "description": "工程生成回归",
        "author": "测试", "section": "Tweaks",
        "layout": [{ "path": "/Library/MobileSubstrate/DynamicLibraries/SmokeTweak.dylib", "product": "tweak" }],
        "tweakFilter": { "dylib": "tweak", "bundles": ["com.apple.SpringBoard"] }
      }
    }
    """

    private static let app = """
    {
      "schemaVersion": 1,
      "projectID": "3f1c2a44-0d6e-4c31-9a3d-2b1f0e8c7d56",
      "kind": "app",
      "template": {
        "extensionID": "wiki.qaq.apelin.dev.app", "templateID": "uikit-swift",
        "version": "0.1.1",
        "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000000"
      },
      "environment": { "toolchain": { "id": "t", "digest": "sha256:00" }, "sdk": { "id": "s", "digest": "sha256:00" } },
      "language": "swift",
      "deploymentTarget": "16.0",
      "architectures": { "rootless": ["arm64"], "roothide": ["arm64"] },
      "configurations": {
        "Debug": { "optimization": "0", "debugInfo": true },
        "Release": { "optimization": "2", "debugInfo": true }
      },
      "products": [{
        "id": "app", "type": "app", "name": "SmokeApp",
        "sources": ["Sources/*.swift"], "resources": ["Resources/*"],
        "infoPlist": "Resources/Info.plist", "entitlements": "Packaging/App.entitlements",
        "frameworks": ["Foundation", "UIKit"]
      }],
      "build": { "steps": [{ "type": "compile", "product": "app" }, { "type": "link", "product": "app" }] },
      "package": {
        "id": "com.xyzl.xcode-smoke", "name": "回归工程", "version": "0.0.1", "description": "工程生成回归",
        "author": "测试", "section": "Applications",
        "layout": [{ "path": "/Applications/SmokeApp.app", "product": "app" }]
      }
    }
    """

    /// 写入输入文件，解码为生成器读取的类型。
    private func project(_ json: String, in root: URL, files: [String: String]) throws -> ProjectDocument {
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            try Data(text.utf8).write(to: url)
        }
        return try JSONDecoder().decode(ProjectDocument.self, from: Data(json.utf8))
    }

    /// Xcode 首先按 OpenStep 属性列表读取工程，测试也采用相同格式。
    private func objects(
        _ written: XcodeProject.Written,
    ) throws -> (root: [String: Any], objects: [String: [String: Any]]) {
        let data = try Data(contentsOf: URL(fileURLWithPath: written.path + "/project.pbxproj"))
        var format = PropertyListSerialization.PropertyListFormat.openStep
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format)
        let root = try XCTUnwrap(plist as? [String: Any])
        let objects = try XCTUnwrap(root["objects"] as? [String: Any])
        var typed: [String: [String: Any]] = [:]
        for (key, value) in objects {
            typed[key] = try XCTUnwrap(value as? [String: Any], key)
        }
        return (root, typed)
    }

    private func body(_ objects: [String: [String: Any]], isa: String) -> [[String: Any]] {
        objects.values.filter { $0["isa"] as? String == isa }
    }

    /// 按所属对象查找配置，不能依赖字典遍历恰好先遇到目标或项目配置。
    private func settings(
        _ objects: [String: [String: Any]],
        owner: [String: Any],
        name: String,
    ) throws -> [String: Any] {
        let listID = try XCTUnwrap(owner["buildConfigurationList"] as? String)
        let list = try XCTUnwrap(objects[listID])
        let configurations = try XCTUnwrap(list["buildConfigurations"] as? [String])
        let configuration = try XCTUnwrap(configurations.compactMap { objects[$0] }.first {
            $0["name"] as? String == name
        })
        return try XCTUnwrap(configuration["buildSettings"] as? [String: Any])
    }

    func testATweakBecomesADylibTarget() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("Smoke Tweak")
        let document = try project(Self.tweak, in: root, files: ["Sources/Tweak.m": "#import <substrate.h>\n"])
        let written = try XcodeProject.write(
            document,
            name: "Smoke Tweak",
            root: root,
            catalog: ExtensionCatalog(directory: Repository.extensions),
        )
        XCTAssertEqual(written.targets, ["SmokeTweak"])
        XCTAssertEqual(written.path, root.appendingPathComponent("Smoke Tweak.xcodeproj").path)

        let (rootObject, objects) = try objects(written)
        XCTAssertEqual(rootObject["objectVersion"] as? Int, 56)
        XCTAssertNotNil(objects[rootObject["rootObject"] as? String ?? ""])

        let target = try XCTUnwrap(body(objects, isa: "PBXNativeTarget").first)
        XCTAssertEqual(target["name"] as? String, "SmokeTweak")
        XCTAssertEqual(target["productType"] as? String, "com.apple.product-type.library.dynamic")
        let reference = try XCTUnwrap(objects[target["productReference"] as? String ?? ""])
        XCTAssertEqual(reference["path"] as? String, "SmokeTweak.dylib")

        // 源文件参与编译，链接设置使用随工程携带的扩展头文件与链接桩。
        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
        let sources = try XCTUnwrap(phases.first { $0["isa"] as? String == "PBXSourcesBuildPhase" })
        let build = (sources["files"] as? [String] ?? []).compactMap { objects[$0] }
        XCTAssertEqual(build.count, 1)
        let compiled = try XCTUnwrap(build.first)
        let source = try XCTUnwrap(objects[compiled["fileRef"] as? String ?? ""])
        XCTAssertEqual(source["path"] as? String, "Tweak.m")

        let values = try settings(objects, owner: target, name: "Debug")
        XCTAssertEqual(values["PRODUCT_NAME"] as? String, "SmokeTweak")
        XCTAssertEqual(values["LD_DYLIB_INSTALL_NAME"] as? String, "@rpath/SmokeTweak.dylib")
        XCTAssertEqual(values["CLANG_ENABLE_OBJC_ARC"] as? String, "YES")
        XCTAssertEqual(
            values["HEADER_SEARCH_PATHS"] as? [String],
            ["$(inherited)", "$(SRCROOT)/Sources", "$(SRCROOT)/Xcode/Support/support/include"],
        )
        XCTAssertEqual(
            values["LIBRARY_SEARCH_PATHS"] as? [String],
            ["$(inherited)", "$(SRCROOT)/Xcode/Support/support/lib/roothide"],
        )
        XCTAssertEqual(
            values["FRAMEWORK_SEARCH_PATHS"] as? [String],
            ["$(inherited)", "$(SRCROOT)/Xcode/Support/support/lib/roothide"],
        )
        XCTAssertEqual(
            values["OTHER_LDFLAGS"] as? [String],
            ["$(inherited)", "-framework", "Foundation", "-framework", "UIKit", "-lsubstrate"],
        )

        let projectObject = try XCTUnwrap(objects[rootObject["rootObject"] as? String ?? ""])
        let projectValues = try settings(objects, owner: projectObject, name: "Debug")
        let defines = try XCTUnwrap(projectValues["GCC_PREPROCESSOR_DEFINITIONS"] as? [String])
        XCTAssertTrue(defines.contains("APELIN_BUILD_ID=\"xcode\""))
        XCTAssertTrue(defines.contains("APELIN_PACKAGE_ID=\"com.xyzl.xcode-smoke\""))
        XCTAssertTrue(defines.contains("APELIN_BOOTSTRAP_ROOTHIDE=1"))
        XCTAssertTrue(defines.contains("DEBUG=1"))
        XCTAssertEqual(projectValues["ARCHS"] as? [String], ["arm64", "arm64e"])

        let support = root.appendingPathComponent("Xcode/Support/support")
        for file in ["include/substrate.h", "lib/roothide/libsubstrate.tbd"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: support.appendingPathComponent(file).path), file)
        }
        let readme = try String(contentsOf: root.appendingPathComponent("Xcode/README.md"), encoding: .utf8)
        XCTAssertTrue(readme.contains("模拟器"))
        XCTAssertFalse(readme.contains(ProjectStore.projectFileName))

        let scheme = written.path + "/xcshareddata/xcschemes/SmokeTweak.xcscheme"
        XCTAssertTrue(XMLParser(contentsOf: URL(fileURLWithPath: scheme))?.parse() ?? false)
        let workspace = written.path + "/project.xcworkspace/contents.xcworkspacedata"
        XCTAssertTrue(XMLParser(contentsOf: URL(fileURLWithPath: workspace))?.parse() ?? false)
    }

    func testAnAppCopiesItsResourcesAndNotItsInfoPlist() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("Smoke App")
        let document = try project(Self.app, in: root, files: [
            "Sources/main.swift": "import UIKit\n",
            "Resources/icon.png": "png",
            "Resources/Info.plist": "<plist version=\"1.0\"><dict/></plist>\n",
            "Packaging/App.entitlements": "<plist version=\"1.0\"><dict/></plist>\n",
        ])
        let written = try XcodeProject.write(document, name: "Smoke App", root: root)
        let (rootObject, objects) = try objects(written)

        let target = try XCTUnwrap(body(objects, isa: "PBXNativeTarget").first)
        XCTAssertEqual(target["productType"] as? String, "com.apple.product-type.application")
        let phases = (target["buildPhases"] as? [String] ?? []).compactMap { objects[$0] }
        let resources = try XCTUnwrap(phases.first { $0["isa"] as? String == "PBXResourcesBuildPhase" })
        let copied = (resources["files"] as? [String] ?? []).compactMap { objects[$0] }
            .compactMap { objects[$0["fileRef"] as? String ?? ""]?["path"] as? String }
        XCTAssertEqual(copied, ["icon.png"])

        let values = try settings(objects, owner: target, name: "Release")
        XCTAssertEqual(values["INFOPLIST_FILE"] as? String, "Resources/Info.plist")
        XCTAssertEqual(values["CODE_SIGN_ENTITLEMENTS"] as? String, "Packaging/App.entitlements")
        XCTAssertEqual(values["PRODUCT_BUNDLE_IDENTIFIER"] as? String, "com.xyzl.xcode-smoke")

        // 设备不签名；模拟器必须独立构建并 ad-hoc 签名，条件键也必须能解析。
        let projectObject = try XCTUnwrap(objects[rootObject["rootObject"] as? String ?? ""])
        for name in ["Debug", "Release"] {
            let projectValues = try settings(objects, owner: projectObject, name: name)
            XCTAssertEqual(projectValues["CODE_SIGNING_ALLOWED"] as? String, "NO")
            XCTAssertEqual(projectValues["CODE_SIGNING_REQUIRED"] as? String, "NO")
            XCTAssertEqual(projectValues["CODE_SIGN_IDENTITY"] as? String, "")
            XCTAssertEqual(projectValues["SUPPORTED_PLATFORMS"] as? String, "iphoneos iphonesimulator")
            XCTAssertEqual(projectValues["CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]"] as? String, "YES")
            XCTAssertEqual(projectValues["CODE_SIGNING_REQUIRED[sdk=iphonesimulator*]"] as? String, "YES")
            XCTAssertEqual(projectValues["CODE_SIGN_IDENTITY[sdk=iphonesimulator*]"] as? String, "-")
        }
    }

    /// 相同输入在不同目录生成相同字节，不使用时间或随机 ID。
    func testTheSameDescriptionWritesTheSameBytes() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let first = scratch.appendingPathComponent("One/Smoke")
        let second = scratch.appendingPathComponent("Two/Smoke")
        let left = try XcodeProject.write(
            try project(Self.tweak, in: first, files: ["Sources/Tweak.m": "x\n"]),
            name: "Smoke",
            root: first,
            catalog: ExtensionCatalog(directory: Repository.extensions),
        )
        let right = try XcodeProject.write(
            try project(Self.tweak, in: second, files: ["Sources/Tweak.m": "x\n"]),
            name: "Smoke",
            root: second,
            catalog: ExtensionCatalog(directory: Repository.extensions),
        )
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: left.path + "/project.pbxproj")),
            try Data(contentsOf: URL(fileURLWithPath: right.path + "/project.pbxproj")),
        )
    }

    /// Xcode 修改过的工程绝不覆盖。
    func testAnExistingProjectIsNeverReplaced() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let root = scratch.appendingPathComponent("Smoke")
        let document = try project(Self.tweak, in: root, files: ["Sources/Tweak.m": "x\n"])
        _ = try XcodeProject.write(document, name: "Smoke", root: root)
        let marker = root.appendingPathComponent("Smoke.xcodeproj/project.pbxproj")
        try Data("已在 Xcode 中修改\n".utf8).write(to: marker)
        XCTAssertThrowsError(try XcodeProject.write(document, name: "Smoke", root: root))
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "已在 Xcode 中修改\n")
    }

    /// 所有内置模板都在创建时附带工程，不能只验证直接调用生成器的路径。
    func testCreatedProjectsCarryTheirXcodeProject() throws {
        let scratch = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(
            at: scratch.appendingPathComponent("Documents/wiki.qaq.apelin"),
            withIntermediateDirectories: true,
        )
        let store = ProjectStore(dataFolder: DataFolder(home: scratch.path))
        let catalog = ExtensionCatalog(directory: Repository.extensions)
        for item in catalog.usable {
            let manifest = try XCTUnwrap(item.manifest)
            for template in manifest.templates {
                let name = "Carried-\(template.id)"
                let created = try store.create(
                    templateID: "\(manifest.id)/\(template.id)",
                    name: name,
                    values: [:],
                    catalog: catalog,
                    registry: sampleRegistry(),
                )
                let path = created.root.appendingPathComponent(name + ".xcodeproj/project.pbxproj")
                XCTAssertTrue(FileManager.default.fileExists(atPath: path.path), template.id)
                XCTAssertTrue(FileManager.default.fileExists(
                    atPath: created.root.appendingPathComponent("Xcode/README.md").path,
                ), template.id)
                if manifest.id == "wiki.qaq.apelin.dev.tweak" {
                    XCTAssertTrue(FileManager.default.fileExists(
                        atPath: created.root.appendingPathComponent("Xcode/Support/support/include/substrate.h").path,
                    ), template.id)
                }
            }
        }
    }

    func testFolderNamesAndStableIdentifiers() {
        XCTAssertEqual(XcodeProject.folderName("  Demo:One/Two  "), "Demo-One-Two")
        XCTAssertEqual(XcodeProject.folderName(" \n "), "Project")
        XCTAssertEqual(XcodeProject.hexID("测试"), XcodeProject.hexID("测试"))
        XCTAssertNotEqual(XcodeProject.hexID("一"), XcodeProject.hexID("二"))
        XCTAssertEqual(XcodeProject.hexID("测试").count, 24)
    }
}
