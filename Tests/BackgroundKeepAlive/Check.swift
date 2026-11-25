import Foundation

/// 可在具备 iOS Swift 工具链的环境中，与生产 BackgroundKeepAlive.swift 一同编译运行。
@main
struct BackgroundKeepAliveCheck {
    @MainActor
    static func main() {
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
        print("通过：生产 Swift 保活代码循环创建释放 100 次，授予 \(granted) 次")
    }
}
