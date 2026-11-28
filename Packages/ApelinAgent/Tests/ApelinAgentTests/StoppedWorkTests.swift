@testable import ApelinAgent
import Foundation
import Testing

@Suite("停止任务快照")
struct StoppedWorkTests {
    /// 可先释放再进入，保证失败清理不会丢失恢复信号。
    private actor Gate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []

        func wait() async {
            guard !released else { return }
            await withCheckedContinuation { waiters.append($0) }
        }

        func release() {
            released = true
            let pending = waiters
            waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private static func ended(_ stopped: AgentSession.StoppedWork) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !stopped.hasEnded, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return stopped.hasEnded
    }

    @Test
    func noWorkIsAlreadyFinished() {
        #expect(AgentSession.StoppedWork([]).hasEnded)
    }

    @Test(.timeLimit(.minutes(1)))
    func waitsForBothCapturedTasks() async {
        let runGate = Gate()
        let compactionGate = Gate()
        let run = Task { await runGate.wait() }
        let compaction = Task { await compactionGate.wait() }
        let stopped = AgentSession.StoppedWork([run, compaction])
        #expect(!stopped.hasEnded)
        await runGate.release()
        await run.value
        #expect(!stopped.hasEnded, "压缩还在运行，不能提前确认停止完成")
        await compactionGate.release()
        await compaction.value
        #expect(await Self.ended(stopped))
    }

    @Test(.timeLimit(.minutes(1)))
    func laterWorkDoesNotChangeTheEarlierReceipt() async {
        let oldGate = Gate()
        let oldTask = Task { await oldGate.wait() }
        let stopped = AgentSession.StoppedWork([oldTask])
        let newGate = Gate()
        let newTask = Task { await newGate.wait() }
        let later = AgentSession.StoppedWork([newTask])
        #expect(!stopped.hasEnded && !later.hasEnded)
        await oldGate.release()
        await oldTask.value
        #expect(await Self.ended(stopped), "后来的工作不能延长旧任务的停止期限")
        #expect(!later.hasEnded, "后来的任务此时仍然挂起")
        await newGate.release()
        await newTask.value
        #expect(await Self.ended(later))
        #expect(stopped.hasEnded)
    }
}
