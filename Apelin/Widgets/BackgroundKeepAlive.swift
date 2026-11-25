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
/// BKSProcessAssertion 只能经 ObjC 运行时构造，Swift 里 `alloc()`、
/// 多参 `perform` 都不可用；这里用 `dlsym` 取 `objc_msgSend` 函数指针、
/// 按 `@convention(c)` 强类型调用，全部是普通 Swift 表达式。
///
/// 本机无法直接证明断言能阻止挂起（探针只看到 valid == true）；
/// 若系统拒绝授予，记录日志并静默降级为不保活。
@MainActor
enum BackgroundKeepAlive {
    private static let log = Logger(subsystem: "wiki.qaq.apelin", category: "keepalive")

    /// BKSProcessAssertion 的 flags。
    private static let preventSuspendFlags: UInt = 1
    /// reason 10005 = Continuous（实测授予；Audio/BackgroundUI 不授予）。
    private static let continuousReason: UInt = 10005

    private static var assertion: NSObject?
    private static var hasLoadedClass = false

    /// objc_msgSend，四对象参数形式：`initWithPID:flags:reason:name:withHandler:`。
    /// pid/reason 走整型寄存器，name 是 C 字符串，handler 传 nil。
    private typealias MsgSendInit = @convention(c) (
        AnyObject, Selector, Int32, UInt, UInt, UnsafePointer<CChar>?, AnyObject?
    ) -> Unmanaged<NSObject>?
    /// objc_msgSend，类方法形式：`alloc`。
    private typealias MsgSendAlloc = @convention(c) (
        AnyObject.Type, Selector
    ) -> Unmanaged<AnyObject>

    private static func msgSend() -> UnsafeMutableRawPointer? {
        let handle = dlopen(nil, RTLD_LAZY)
        return dlsym(handle, "objc_msgSend")
    }

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
        guard let raw = msgSend() else {
            log.error("取 objc_msgSend 失败，无法后台保活")
            return
        }
        let alloc = unsafeBitCast(raw, to: MsgSendAlloc.self)
        let send = unsafeBitCast(raw, to: MsgSendInit.self)
        let instance = alloc(cls, NSSelectorFromString("alloc")).takeUnretainedValue()
        let selector = NSSelectorFromString("initWithPID:flags:reason:name:withHandler:")
        guard let obj = send(instance, selector,
                             ProcessInfo.processInfo.processIdentifier,
                             preventSuspendFlags,
                             continuousReason,
                             "wiki.qaq.apelin.keepalive",
                             nil)?.takeRetainedValue() else {
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
