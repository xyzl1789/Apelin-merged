import Foundation
import ObjectiveC
import os

/// 有会话进行时申请 PreventSuspend；系统拒绝或接口不兼容时不保活。
/// 私有接口的签名必须先核验，不能用 perform 读取 BOOL 或传递整数参数。
@MainActor
enum BackgroundKeepAlive {
    private static let log = Logger(subsystem: "wiki.qaq.apelin", category: "keepalive")
    private static var assertion: NSObject?

    private typealias Allocate = @convention(c) (UnsafeRawPointer, Selector) -> UnsafeMutableRawPointer?
    private typealias Initialize = @convention(c) (
        UnsafeMutableRawPointer, Selector, Int32, UInt32, UInt32, UnsafeRawPointer, UnsafeRawPointer?
    ) -> UnsafeMutableRawPointer?
    private typealias IsValid = @convention(c) (UnsafeRawPointer, Selector) -> Bool
    private typealias Invalidate = @convention(c) (UnsafeRawPointer, Selector) -> Void

    private struct Bridge {
        let cls: NSObject.Type
        let allocate: Allocate
        let initialize: Initialize
        let isValid: IsValid
        let invalidate: Invalidate
    }

    private static let allocateSelector = NSSelectorFromString("alloc")
    private static let initializeSelector = NSSelectorFromString("initWithPID:flags:reason:name:withHandler:")
    private static let validSelector = NSSelectorFromString("valid")
    private static let invalidateSelector = NSSelectorFromString("invalidate")

    /// 只获取一次经过签名检查的 IMP。不匹配就停止，不猜测其他版本的 ABI。
    private static let bridge: Bridge? = {
        _ = dlopen("/System/Library/PrivateFrameworks/AssertionServices.framework/AssertionServices", RTLD_LAZY)
        if NSClassFromString("BKSProcessAssertion") == nil {
            _ = dlopen("/System/Library/PrivateFrameworks/BackBoardServices.framework/BackBoardServices", RTLD_LAZY)
        }
        guard let cls = NSClassFromString("BKSProcessAssertion") as? NSObject.Type,
              let allocate = class_getClassMethod(cls, allocateSelector),
              let initialize = class_getInstanceMethod(cls, initializeSelector),
              let valid = class_getInstanceMethod(cls, validSelector),
              let invalidate = class_getInstanceMethod(cls, invalidateSelector),
              signatureMatches(allocate, returns: "@", arguments: ["@", ":"]),
              signatureMatches(initialize, returns: "@", arguments: ["@", ":", "i", "I", "I", "@", "@?"]),
              signatureMatches(valid, returns: "B", arguments: ["@", ":"]),
              signatureMatches(invalidate, returns: "v", arguments: ["@", ":"]) else {
            log.error("后台保活接口缺失或签名不兼容，已跳过保活")
            return nil
        }
        return Bridge(
            cls: cls,
            allocate: unsafeBitCast(method_getImplementation(allocate), to: Allocate.self),
            initialize: unsafeBitCast(method_getImplementation(initialize), to: Initialize.self),
            isValid: unsafeBitCast(method_getImplementation(valid), to: IsValid.self),
            invalidate: unsafeBitCast(method_getImplementation(invalidate), to: Invalidate.self)
        )
    }()

    private static func signatureMatches(_ method: Method, returns result: String, arguments: [String]) -> Bool {
        guard method_getNumberOfArguments(method) == UInt32(arguments.count),
              let returnType = method_copyReturnType(method) else { return false }
        defer { free(returnType) }
        guard String(cString: returnType) == result else { return false }
        for (index, expected) in arguments.enumerated() {
            guard let type = method_copyArgumentType(method, UInt32(index)) else { return false }
            let actual = String(cString: type)
            free(type)
            guard actual == expected else { return false }
        }
        return true
    }

    /// 计数式请求保活。零会话释放；失效后下次有事件时可以重新申请。
    static func setRunningCount(_ count: Int) {
        guard count > 0 else {
            release()
            return
        }
        guard !isHolding else { return }
        release()
        acquire()
    }

    /// 返回系统实际有效性，而不是仅判断保存的对象是否非空。
    static var isHolding: Bool {
        guard let assertion, let bridge else { return false }
        return bridge.isValid(Unmanaged.passUnretained(assertion).toOpaque(), validSelector)
    }

    private static func acquire() {
        guard let bridge else { return }
        let classPointer = Unmanaged.passUnretained(bridge.cls as AnyObject).toOpaque()
        guard let allocated = bridge.allocate(classPointer, allocateSelector) else {
            log.error("后台保活对象分配失败")
            return
        }
        // name 是 NSString 对象，不是 UTF-8 指针；flags/reason 是 32 位 unsigned int。
        let name: NSString = "wiki.qaq.apelin.keepalive"
        let initialized = withExtendedLifetime(name) {
            bridge.initialize(
                allocated, initializeSelector, ProcessInfo.processInfo.processIdentifier,
                1, 10005, Unmanaged.passUnretained(name).toOpaque(), nil
            )
        }
        // alloc 的 +1 所有权经 init 转移到返回对象，再由 ARC 接管一次。
        // init 返回 nil 时遵循 ObjC init 的约定，不再释放旧 receiver。
        guard let initialized else {
            log.error("后台保活对象初始化失败")
            return
        }
        let object = Unmanaged<NSObject>.fromOpaque(initialized).takeRetainedValue()
        assertion = object
        // 这个初始化器已发起申请，不重复 acquire；valid 是 BOOL，不能当对象读。
        if isHolding {
            log.notice("后台保活断言已授予（PreventSuspend）")
        } else {
            log.error("后台保活断言未被授予，已降级为不保活")
            release()
        }
    }

    private static func release() {
        guard let object = assertion, let bridge else { return }
        assertion = nil
        bridge.invalidate(Unmanaged.passUnretained(object).toOpaque(), invalidateSelector)
    }
}
