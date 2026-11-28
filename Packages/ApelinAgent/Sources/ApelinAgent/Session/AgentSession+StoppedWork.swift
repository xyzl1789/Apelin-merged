import Foundation

extension AgentSession {
    /// 一次停止请求发出时的工作快照；之后启动的轮次不计入这份回执。
    public final class StoppedWork: @unchecked Sendable {
        private let lock = NSLock()
        private var ended = false

        init(_ tasks: [Task<Void, Never>]) {
            guard !tasks.isEmpty else {
                ended = true
                return
            }
            Task {
                for task in tasks {
                    await task.value
                }
                self.lock.withLock { self.ended = true }
            }
        }

        /// 只在快照中的运行与压缩任务都结束后变为 true。
        @objc public dynamic var hasEnded: Bool {
            lock.withLock { ended }
        }
    }
}
