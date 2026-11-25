@testable import ApelinCore
import Foundation
import XCTest

final class ViewedConversationTests: XCTestCase {
    private let session = "11111111-2222-3333-4444-555555555555"
    private let other = "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    private let pid: UInt32 = 42

    func testOnlyFreshVisibleSameProcessMatches() {
        let lease = ViewedConversation.lease(processID: pid, uptime: 100)
        let foreground = UInt64(pid) << 32 | 5
        XCTAssertTrue(ViewedConversation.matches(lease: lease, foreground: foreground, uptime: 100))
        XCTAssertTrue(ViewedConversation.matches(lease: lease, foreground: foreground, uptime: 111.9))
        for now in [99.0, 112, .infinity, .nan] {
            XCTAssertFalse(ViewedConversation.matches(lease: lease, foreground: foreground, uptime: now))
        }
        for flags: UInt64 in [0, 1, 4] {
            XCTAssertFalse(ViewedConversation.matches(lease: lease, foreground: UInt64(pid) << 32 | flags, uptime: 101))
        }
        XCTAssertFalse(ViewedConversation.matches(lease: lease, foreground: UInt64(pid + 1) << 32 | 5, uptime: 101))
        XCTAssertFalse(ViewedConversation.matches(lease: 0, foreground: foreground, uptime: 101))
    }

    func testInvalidIdentityAndClockNeverProduceLease() {
        XCTAssertNil(ViewedConversation.channelName(session: ""))
        XCTAssertNil(ViewedConversation.channelName(session: "not-a-session"))
        XCTAssertEqual(ViewedConversation.channelName(session: other.uppercased()), ViewedConversation.channelName(session: other))
        XCTAssertEqual(ViewedConversation.lease(processID: 0, uptime: 100), 0)
        for now in [-1.0, 0, .infinity, .nan, Double(UInt32.max)] {
            XCTAssertEqual(ViewedConversation.lease(processID: pid, uptime: now), 0)
        }
    }

    func testSenderSuppressesOnlyViewedSessionAndLiveProcess() throws {
        let name = try XCTUnwrap(ViewedConversation.channelName(session: session))
        let foreground = UInt64(pid) << 32 | 5
        var states = [name: ViewedConversation.lease(processID: pid, uptime: 100),
                      ViewedConversation.foregroundName: foreground]
        func suppress(_ id: String, now: TimeInterval = 101, alive: Bool = true) -> Bool {
            ViewedConversation.shouldSuppress(session: id, uptime: now, readState: { states[$0] }, isAlive: { _ in alive })
        }
        XCTAssertTrue(suppress(session))
        XCTAssertFalse(suppress(other))
        XCTAssertFalse(suppress(session, now: 112))
        XCTAssertFalse(suppress(session, alive: false))
        states[ViewedConversation.foregroundName] = UInt64(pid) << 32 | 1
        XCTAssertFalse(suppress(session), "切后台或锁屏立即放行")
        states[ViewedConversation.foregroundName] = foreground
        states[name] = 0
        XCTAssertFalse(suppress(session), "页面离开后撤销租约")
        states[name] = ViewedConversation.lease(processID: pid + 1, uptime: 100)
        XCTAssertFalse(suppress(session), "旧进程不能静默新进程通知")
    }

    func testBackgroundTransitionDuringReadFailsOpen() throws {
        let name = try XCTUnwrap(ViewedConversation.channelName(session: session))
        var reads = 0
        let result = ViewedConversation.shouldSuppress(
            session: session, uptime: 101,
            readState: { key in
                if key == name { return ViewedConversation.lease(processID: self.pid, uptime: 100) }
                guard key == ViewedConversation.foregroundName else { return nil }
                reads += 1
                return UInt64(self.pid) << 32 | (reads == 1 ? 5 : 1)
            },
            isAlive: { _ in true }
        )
        XCTAssertFalse(result, "读取期间切后台或锁屏不能吞通知")
        XCTAssertEqual(reads, 2)
    }

    func testSessionSwitchDuringReadFailsOpen() throws {
        let name = try XCTUnwrap(ViewedConversation.channelName(session: session))
        var reads = 0
        let result = ViewedConversation.shouldSuppress(
            session: session, uptime: 101,
            readState: { key in
                if key == ViewedConversation.foregroundName { return UInt64(self.pid) << 32 | 5 }
                guard key == name else { return nil }
                reads += 1
                return reads == 1 ? ViewedConversation.lease(processID: self.pid, uptime: 100) : 0
            },
            isAlive: { _ in true }
        )
        XCTAssertFalse(result, "读取期间切换会话不能吞通知")
        XCTAssertEqual(reads, 2)
    }
}
