import Foundation

/// 可在具备 iOS Swift 工具链的环境中，与生产 BackgroundKeepAlive.swift 一同编译运行。
@main
struct BackgroundKeepAliveCheck {
    @MainActor
    static func main() async {
        var diagnostics: [String] = []
        BackgroundKeepAlive.diagnosticHandler = { message, _ in diagnostics.append(message) }
        BackgroundKeepAlive.setRunningCount(0)
        precondition(!BackgroundKeepAlive.isHolding, "零会话不应持有断言")
        var granted = 0
        for _ in 0..<100 {
            autoreleasepool {
                BackgroundKeepAlive.setRunningCount(1)
                if BackgroundKeepAlive.isHolding { granted += 1 }
                BackgroundKeepAlive.setRunningCount(2)
                BackgroundKeepAlive.setRunningCount(0)
                precondition(!BackgroundKeepAlive.isHolding, "结束后必须释放断言")
                BackgroundKeepAlive.setRunningCount(0)
                BackgroundKeepAlive.setRunningCount(-1)
                precondition(!BackgroundKeepAlive.isHolding, "重复结束不应持有断言")
            }
        }
        // 给已排队的回调一次执行机会；这个窗口不保证系统必定回调。
        try? await Task.sleep(for: .milliseconds(50))
        precondition(!BackgroundKeepAlive.isHolding, "迟到的申请回调不能恢复已结束的断言")
        precondition(diagnostics.contains("进行中会话数变为 1"), "开始会话必须输出诊断")
        precondition(diagnostics.contains("进行中会话数变为 0"), "结束会话必须输出诊断")
        BackgroundKeepAlive.diagnosticHandler = nil
        print("通过：生产 Swift 保活代码循环创建释放 100 次并检查延后状态，立即有效 \(granted) 次；不代表后台获准")
    }
}
