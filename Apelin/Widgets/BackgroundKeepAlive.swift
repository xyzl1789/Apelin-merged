import Foundation
import os

/// 后台保活断言：会话进行中时阻止系统把 Apelin 挂起，让 ChatRuntime 的
/// 读者（XPC 长轮询）与实时活动在切后台后继续刷新。
///
/// 通过私有的 BKSProcessAssertion（BackBoardServices）取得 PreventSuspend
/// 断言。取值来自 icli probe 的真机实测（iOS 16.3.1）：
/// - flags = 1（PreventSuspend）+ reason = 10005（Continuous）→ 授予；
/// - reason = 1（Audio）、7（BackgroundUI）、10004 均不授予；
/// - flags = 3（加 PreventThrottleDownCPU）也授予，但无额外收益，取 1。
///
/// 本机无法直接证明断言能阻止挂起（探针只看到 valid == true）；
/// 若系统拒绝授予，记录日志并静默降级为不保活。
@_silgen_name("objc_msgSend")
private func objcMsgSendAlloc(_ target: AnyObject.Type, _ sel: Selector) -> Unmanaged<AnyObject>?

@_silgen_name("objc_msgSend")
private func objcMsgSend4(_ target: AnyObject, _ sel: Selector, _ pid: Int32, _ flags: UInt, _ reason: UInt,
                          _ name: UnsafePointer<CChar>?, _ handler: AnyObject?) -> Unmanaged<NSObject>?

@MainActor
enum BackgroundKeepAlive {
    private static let log = Logger(subsystem: "wiki.qaq.apelin", category: "keepalive")

    /// BKSProcessAssertion 的 flags。
    private static let preventSuspendFlags: UInt = 1
    /// reason 10005 = Continuous（实测授予；Audio/BackgroundUI 不授予）。
    private static let continuousReason: UInt = 10005

    private static var assertion: NSObject?
    private static var hasLoadedClass = false

    /// 计数式请求保活：`count > 0` 时持有断言。
    static func setRunningCount(_ count: Int) {
        let want = count > 0
        let has = assertion != nil
        guard want != has else { return }
        if want {
            acquire()
        } else {
            release()
        }
    }

    static var isHolding: Bool { assertion != nil }

    /// 延迟加载 BKSProcessAssertion 类（框架在 dyld 共享缓存里）。
    private static func loadClass() -> NSObject.Type? {
        if !hasLoadedClass {
            hasLoadedClass = true
            if dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices", RTLD_LAZY) == nil {
                _ = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY)
            }
        }
        return NSClassFromString("BKSProcessAssertion") as? NSObject.Type
    }

    private static func acquire() {
        guard let cls = loadClass() else {
            log.error("BKSProcessAssertion 类不存在，无法后台保活")
            return
        }
        // initWithPID:flags:reason:name:withHandler:（实测：self pid、handler 传 null 可用）
        let selector = NSSelectorFromString("initWithPID:flags:reason:name:withHandler:")
        let obj = objcMsgSend4(objcMsgSendAlloc(cls, NSSelectorFromString("alloc"))!.takeUnretainedValue(), selector,
                               ProcessInfo.processInfo.processIdentifier,
                               preventSuspendFlags,
                               continuousReason,
                               "wiki.qaq.apelin.keepalive",
                               nil)?.takeRetainedValue()
        guard let obj else {
            log.error("BKSProcessAssertion 初始化失败，无法后台保活")
            return
        }
        assertion = obj
        obj.perform(NSSelectorFromString("acquire"))
        let valid = (obj.perform(NSSelectorFromString("valid"))?.takeUnretainedValue() as? Bool) ?? false
        if valid {
            log.notice("后台保活断言已授予（PreventSuspend）")
        } else {
            log.error("后台保活断言未被授予，实时活动在后台将停止更新")
            release()
        }
    }

    private static func release() {
        guard let obj = assertion else { return }
        assertion = nil
        obj.perform(NSSelectorFromString("invalidate"))
    }
}
