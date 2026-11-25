import Foundation
import QuartzCore
import UIKit
import os

/// 聊天实时刷新的耗时与帧率监视器，仅开发包启用。
/// 每秒写一行系统日志，由设备上的 apelin_log_read 读取。
@MainActor
enum ChatPerformance {
    static let active = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true

    private static let log = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "wiki.qaq.apelin",
        category: "chat-performance",
    )

    private struct Total {
        var calls = 0
        var milliseconds = 0.0
    }

    private static var totals: [String: Total] = [:]
    private static var frames = 0
    private static var dropped = 0
    private static var worstStall: CFTimeInterval = 0
    private static var windowStart: CFTimeInterval = 0
    private static var lastFrame: CFTimeInterval = 0
    private static var link: CADisplayLink?
    private static let window: CFTimeInterval = 1

    /// 记录一次测量，发布包只执行原操作，不产生日志。
    static func measure<T>(_ tag: String, _ body: () -> T) -> T {
        guard active else { return body() }
        let start = CACurrentMediaTime()
        defer {
            var total = totals[tag] ?? Total()
            total.calls += 1
            total.milliseconds += (CACurrentMediaTime() - start) * 1000
            totals[tag] = total
        }
        return body()
    }

    static func start() {
        guard active, link == nil else { return }
        lastFrame = 0
        windowStart = CACurrentMediaTime()
        let link = CADisplayLink(target: Target(), selector: #selector(Target.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    static func stop() {
        link?.invalidate()
        link = nil
        totals.removeAll(keepingCapacity: true)
        frames = 0
        dropped = 0
        worstStall = 0
    }

    fileprivate static func tick(_ link: CADisplayLink) {
        let now = CACurrentMediaTime()
        if lastFrame > 0 {
            let elapsed = now - lastFrame
            frames += 1
            let slot = link.duration > 0 ? link.duration : 1.0 / 60
            if elapsed > slot * 1.5 {
                dropped += 1
                worstStall = max(worstStall, elapsed)
            }
        }
        lastFrame = now
        guard now - windowStart >= window else { return }
        flush()
    }

    private static func flush() {
        let parts = totals
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.calls)/\(String(format: "%.1f", $0.value.milliseconds))ms" }
        log.notice(
            "帧数=\(frames, privacy: .public) 丢帧=\(dropped, privacy: .public) 最长停顿=\(String(format: "%.1f", worstStall * 1000), privacy: .public)毫秒 \(parts.joined(separator: " "), privacy: .public)",
        )
        totals.removeAll(keepingCapacity: true)
        frames = 0
        dropped = 0
        worstStall = 0
        windowStart = CACurrentMediaTime()
    }

    @MainActor
    private final class Target: NSObject {
        @objc func tick(_ link: CADisplayLink) {
            ChatPerformance.tick(link)
        }
    }
}
