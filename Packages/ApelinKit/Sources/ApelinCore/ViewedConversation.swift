import Darwin
import Foundation
import notify

/// 查看会话的短租约，只用于通知静默，不授予任何操作权限，也不落盘。
/// App 发布会话身份；SpringBoard 的独立状态才决定它是否真实可见。
public enum ViewedConversation {
    public static let foregroundName = "com.xyzl.apelin.foreground.status"
    public static let leaseSeconds: UInt32 = 12

    public static func channelName(session: String) -> String? {
        guard let id = UUID(uuidString: session) else { return nil }
        return "com.xyzl.apelin.viewed." + id.uuidString.lowercased()
    }

    /// 高 32 位为发布进程，低 32 位为单调时钟秒数；零表示不在查看。
    public static func lease(processID: UInt32, uptime: TimeInterval) -> UInt64 {
        guard processID > 0, uptime.isFinite, uptime >= 1, uptime < Double(UInt32.max) else { return 0 }
        return UInt64(processID) << 32 | UInt64(UInt32(uptime))
    }

    public static func matches(lease: UInt64, foreground: UInt64, uptime: TimeInterval) -> Bool {
        let processID = lease >> 32
        let issued = UInt32(truncatingIfNeeded: lease)
        guard processID > 0, issued > 0, foreground >> 32 == processID,
              foreground & 5 == 5, uptime.isFinite
        else { return false }
        let age = uptime - Double(issued)
        return age >= 0 && age < Double(leaseSeconds)
    }

    /// 每次发送前直接读 notifyd，不等待 App 的异步状态回调。
    /// 首尾各读一次租约，切换会话、进程退出或状态不明时一律放行。
    public static func shouldSuppress(session: String) -> Bool {
        shouldSuppress(
            session: session, uptime: ProcessInfo.processInfo.systemUptime,
            readState: state,
            isAlive: { processID in
                guard let pid = Int32(exactly: processID) else { return false }
                return kill(pid, 0) == 0
            }
        )
    }

    /// 与实际发送路径共用的可注入判定，测试不改真实通道或系统通知。
    static func shouldSuppress(
        session: String, uptime: TimeInterval,
        readState: (String) -> UInt64?, isAlive: (UInt32) -> Bool
    ) -> Bool {
        guard let name = channelName(session: session),
              let first = readState(name), first != 0,
              let foreground = readState(foregroundName),
              matches(lease: first, foreground: foreground, uptime: uptime),
              isAlive(UInt32(truncatingIfNeeded: first >> 32)),
              readState(name) == first,
              readState(foregroundName) == foreground
        else { return false }
        return true
    }

    private static func state(_ name: String) -> UInt64? {
        var token: Int32 = -1
        guard notify_register_check(name, &token) == NOTIFY_STATUS_OK else { return nil }
        defer { notify_cancel(token) }
        var value: UInt64 = 0
        guard notify_get_state(token, &value) == NOTIFY_STATUS_OK else { return nil }
        return value
    }
}
