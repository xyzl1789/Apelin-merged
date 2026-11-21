import Foundation
import KWWKAI
#if canImport(UIKit) && !targetEnvironment(macCatalyst)
import UIKit
#endif

/// 自建/中转 OpenAI 兼容端点的客户端标识。
///
/// 这类中转站按 User-Agent 白名单放行客户端（Codex、Claude Code、Minis 等），
/// 缺少可识别标识时会以“仅支持编程客户端”为由拒绝请求。与 OpenMinis 的做法
/// 一致，给这些端点带上稳定的 `Minis/<版本> (iOS …; …)` 标识。
/// 只用于自建/中转端点：Codex、Claude、Gemini 等 OAuth/CLI 登录自带强制 UA，
/// 绝不改写。
public enum CompatibleEndpointUserAgent {
    /// 与 Minis 相同的客户端标识格式。版本取系统版本，客户端名固定，
    /// 因为白名单按客户端名放行，而不是按具体版本号。
    public static var `default`: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let model = UIDevice.current.model
        #else
        let model = "Unknown"
        #endif
        // 与 Minis 的 MinisUserAgent 一致：`Minis/<营销版本> (iOS <系统版本>; <机型>)`。
        // 拿不到 app bundle（测试/辅助进程）时用 "?"，白名单按客户端名放行。
        return "Minis/\(version) (iOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion); \(model))"
    }

    /// 给端点的模型带上标识；模型已有的 User-Agent（不论大小写）原样保留，
    /// 这样调用方显式指定的 UA 仍然优先。
    public static func applying(to model: Model) -> Model {
        var model = model
        var headers = model.headers ?? [:]
        if !headers.keys.contains(where: { $0.lowercased() == "user-agent" }) {
            headers["User-Agent"] = `default`
        }
        model.headers = headers
        return model
    }
}
