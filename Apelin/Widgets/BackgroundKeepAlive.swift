import Foundation
import ObjectiveC
import os

/// 有会话进行时申请 PreventSuspend；系统拒绝或接口不兼容时不保活。
/// 私有接口的签名必须先核验，不能用 perform 读取 BOOL 或传递整数参数。
@MainActor
enum BackgroundKeepAlive {
    private static let log = Logger(subsystem: "wiki.qaq.apelin", category: "keepalive")
    private static var assertion: NSObject?
    private static var runningCount = 0
    private static var requestID: UUID?
    private static var isAcquiring = false
    private static var wasValid = false
    private static var retryNotBefore: TimeInterval = 0
    private static var acquisitionTimeout: Task<Void, Never>?

    /// 应用启动时接入持久日志；独立回归不依赖 Dog 或 UIKit。
    static var diagnosticHandler: ((String, Bool) -> Void)?

    private static func record(_ message: String, isError: Bool = false) {
        if isError {
            log.error("\(message, privacy: .public)")
        } else {
            log.notice("\(message, privacy: .public)")
        }
        diagnosticHandler?(message, isError)
    }

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
            record("后台保活接口缺失或签名不兼容，已跳过保活", isError: true)
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
        guard method_getNumberOfArguments(method) == UInt32(arguments.count) else { return false }
        let returnType = method_copyReturnType(method)
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

    /// 计数式请求保活。申请回调到来之前保留对象，不把暂时的 valid=false 当成拒绝。
    static func setRunningCount(_ count: Int) {
        let count = max(0, count)
        if runningCount != count {
            runningCount = count
            record("进行中会话数变为 \(count)")
        }
        guard count > 0 else {
            release(reason: "没有进行中的会话")
            retryNotBefore = 0
            return
        }
        guard !isAcquiring, !isHolding,
              ProcessInfo.processInfo.systemUptime >= retryNotBefore else { return }
        release(reason: "旧断言已失效，准备重新申请")
        acquire()
    }

    /// 返回系统实际有效性；申请中仍为 false，但不会因此释放尚未回调的对象。
    static var isHolding: Bool {
        guard let assertion, let bridge else { return false }
        let valid = bridge.isValid(Unmanaged.passUnretained(assertion).toOpaque(), validSelector)
        if wasValid, !valid {
            record("后台保活断言已失效", isError: true)
        }
        wasValid = valid
        return valid
    }

    private static func acquire() {
        guard let bridge else { return }
        let id = UUID()
        requestID = id
        isAcquiring = true
        record("开始申请后台保活断言（PreventSuspend），进行中会话 \(runningCount)")
        let classPointer = Unmanaged.passUnretained(bridge.cls as AnyObject).toOpaque()
        guard let allocated = bridge.allocate(classPointer, allocateSelector) else {
            record("后台保活对象分配失败", isError: true)
            release(reason: "分配失败")
            retryNotBefore = ProcessInfo.processInfo.systemUptime + 10
            return
        }
        // name 是 NSString 对象；申请回调是 void (^)(BOOL)，不能传 C 函数或对象返回值。
        let name: NSString = "wiki.qaq.apelin.keepalive"
        let handler: @convention(block) (Bool) -> Void = { acquired in
            // 私有接口不保证回调队列，也可能在初始化器返回前回调。
            // 转到 MainActor 后再处理，确保 assertion 已接管返回对象的所有权。
            Task { @MainActor in
                acquisitionFinished(acquired, request: id)
            }
        }
        let handlerObject = handler as AnyObject
        let initialized = withExtendedLifetime((name, handlerObject)) {
            bridge.initialize(
                allocated, initializeSelector, ProcessInfo.processInfo.processIdentifier,
                1, 10005, Unmanaged.passUnretained(name).toOpaque(),
                Unmanaged.passUnretained(handlerObject).toOpaque()
            )
        }
        // alloc 的 +1 所有权经 init 转移到返回对象，再由 ARC 接管一次。
        // init 返回 nil 时遵循 ObjC init 的约定，不再释放旧 receiver。
        guard let initialized else {
            record("后台保活对象初始化失败", isError: true)
            release(reason: "初始化失败")
            retryNotBefore = ProcessInfo.processInfo.systemUptime + 10
            return
        }
        assertion = Unmanaged<NSObject>.fromOpaque(initialized).takeRetainedValue()
        record("后台保活申请已提交，初始有效状态为 \(isHolding)，等待申请回调")
        acquisitionTimeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, requestID == id, isAcquiring else { return }
            isAcquiring = false
            acquisitionTimeout = nil
            if isHolding {
                record("后台保活回调未到达，但断言有效，继续保留")
            } else {
                record("后台保活申请回调超时，断言仍无效", isError: true)
                release(reason: "申请回调超时")
                retryNotBefore = ProcessInfo.processInfo.systemUptime + 10
            }
        }
    }

    private static func acquisitionFinished(_ acquired: Bool, request id: UUID) {
        guard requestID == id, assertion != nil else {
            record("忽略已释放或已替换的后台保活申请回调")
            return
        }
        isAcquiring = false
        acquisitionTimeout?.cancel()
        acquisitionTimeout = nil
        let valid = isHolding
        record("后台保活申请回调：授予=\(acquired)，有效=\(valid)", isError: !acquired || !valid)
        guard acquired, valid else {
            release(reason: acquired ? "回调时断言已失效" : "系统拒绝授予")
            retryNotBefore = ProcessInfo.processInfo.systemUptime + 10
            return
        }
    }

    private static func release(reason: String) {
        let object = assertion
        let hadRequest = requestID != nil
        requestID = nil
        isAcquiring = false
        wasValid = false
        acquisitionTimeout?.cancel()
        acquisitionTimeout = nil
        assertion = nil
        if let object, let bridge {
            bridge.invalidate(Unmanaged.passUnretained(object).toOpaque(), invalidateSelector)
        }
        if hadRequest || object != nil {
            record("释放后台保活断言：\(reason)")
        }
    }
}
