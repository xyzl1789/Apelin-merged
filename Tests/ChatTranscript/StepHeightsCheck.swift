import Foundation

/// 验证逐步骤测高缓存：内容和布局状态改变才重测，且不同步骤互不串用。
func checkStepHeights() {
    var heights = ChatStepHeights<Int>()
    var measured: [UUID] = []
    let first = UUID()
    let second = UUID()

    func height(_ id: UUID, _ stamp: Int) -> CGFloat {
        heights.height(for: id, stamp: stamp) {
            measured.append(id)
            return CGFloat(stamp)
        }
    }

    precondition(height(first, 1) == 1)
    precondition(measured == [first], "步骤第一次读取时测量")
    precondition(height(first, 1) == 1)
    precondition(measured == [first], "相同布局状态直接读取缓存")
    precondition(height(first, 2) == 2)
    precondition(measured == [first, first], "步骤状态变化重新测量")
    precondition(height(second, 2) == 2)
    precondition(measured == [first, first, second], "不同步骤各有独立条目")
    precondition(heights.count == 2)
    heights.forget()
    precondition(heights.count == 0)
    precondition(height(first, 2) == 2)
    precondition(measured == [first, first, second, first], "清除缓存后重新测量")

    var small = ChatStepHeights<Int>(capacity: 2)
    let ids = (0 ..< 4).map { _ in UUID() }
    for id in ids { _ = small.height(for: id, stamp: 0) { 10 } }
    precondition(small.count == 2, "超出容量后清空旧条目")
    var remeasured = false
    _ = small.height(for: ids[0], stamp: 0) {
        remeasured = true
        return 10
    }
    precondition(remeasured)

    struct Stamp: Equatable {
        var shape: ChatMessageShape
        var opened: Bool
        var width: CGFloat
        var textSize: String
    }
    var stateful = ChatStepHeights<Stamp>()
    var step = ChatMessage(id: first, role: .tool, text: "甲乙")
    var stamp = Stamp(shape: ChatMessageShape(step), opened: false, width: 320, textSize: "large")
    var measurements = 0
    func recordMeasurement(_ stamp: Stamp) {
        _ = stateful.height(for: first, stamp: stamp) {
            measurements += 1
            return CGFloat(measurements)
        }
    }
    recordMeasurement(stamp)
    recordMeasurement(stamp)
    precondition(measurements == 1)
    step.text = "丙丁"
    stamp.shape = ChatMessageShape(step)
    recordMeasurement(stamp)
    stamp.opened = true
    recordMeasurement(stamp)
    stamp.width = 280
    recordMeasurement(stamp)
    stamp.textSize = "accessibilityExtraLarge"
    recordMeasurement(stamp)
    precondition(measurements == 5, "同长度改文、展开、宽度和动态字体都会让缓存失效")
    print("通过：步骤测高按内容与布局状态缓存，支持独立步骤、容量和清空")
}

func checkRowDelta() {
    func row(_ id: UUID, _ text: String) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text)
    }
    let first = UUID(), second = UUID(), third = UUID()
    let rows = [row(first, "甲"), row(second, "乙"), row(third, "丙")]
    precondition(ChatRowDelta.changed(rows, rows) == [])
    precondition(ChatRowDelta.changed([], []) == [])
    var tail = rows
    tail[2].text = "丙，继续生成"
    precondition(ChatRowDelta.changed(rows, tail) == [2])
    var head = rows
    head[0].text = "甲，已编辑"
    precondition(ChatRowDelta.changed(rows, head) == [0])
    var both = rows
    both[1].text = "乙，已编辑"
    both[2].text = "丙，已编辑"
    precondition(ChatRowDelta.changed(rows, both) == [1, 2])
    var all = rows
    for index in all.indices { all[index].text += "！" }
    precondition(ChatRowDelta.changed(rows, all) == [0, 1, 2])
    precondition(ChatRowDelta.changed(rows, all, limit: 2) == nil)
    let moved = [row(second, "乙"), row(first, "甲"), row(third, "丙")]
    precondition(ChatRowDelta.changed(rows, moved) == nil)
    precondition(ChatRowDelta.changed(rows, Array(rows.dropLast())) == nil)
    precondition(ChatRowDelta.changed(rows, rows + [row(UUID(), "丁")]) == nil)
    precondition(ChatRowDelta.changed(rows, [row(UUID(), "甲"), rows[1], rows[2]]) == nil)
    print("通过：少量内容变化逐行更新，新增、移除、移动或大批变化仍完整比较")
}

@MainActor
func checkDocumentHeights() {
    ChatRowHeights.forget()
    let first = UUID(), second = UUID()
    ChatRowHeights.store(80, id: first, text: "甲乙", width: 320, textSize: "large")
    precondition(ChatRowHeights.height(id: first, text: "甲乙", width: 320, textSize: "large") == 80)
    precondition(ChatRowHeights.height(id: second, text: "甲乙", width: 320, textSize: "large") == nil)
    precondition(ChatRowHeights.height(id: first, text: "丙丁", width: 320, textSize: "large") == nil)
    precondition(ChatRowHeights.height(id: first, text: "甲乙", width: 280, textSize: "large") == nil)
    precondition(ChatRowHeights.height(id: first, text: "甲乙", width: 320, textSize: "accessibilityExtraLarge") == nil)
    for invalid in [CGFloat(0), -.infinity, .infinity, .nan] {
        ChatRowHeights.store(invalid, id: second, text: "无效", width: 320, textSize: "large")
    }
    precondition(ChatRowHeights.height(id: second, text: "无效", width: 320, textSize: "large") == nil)
    ChatRowHeights.forget()
    precondition(ChatRowHeights.height(id: first, text: "甲乙", width: 320, textSize: "large") == nil)
    print("通过：文档测高按消息、文本、宽度和动态字体隔离")
}

func checkActivityLine() {
    var summary = ChatMessage(role: .thinking(seconds: nil, tools: 0), text: "正在检查")
    precondition(ChatActivityContent.line(summary) == .thought("正在检查"))
    var call = ChatMessage(role: .tool, text: "读取文件")
    call.banner = ToolCallBanner(reason: "查看实现", tool: "file_read")
    summary.trace = [call]
    precondition(ChatActivityContent.line(summary) == .call(call.banner!, token: 1))
    let thought = ChatMessage(role: .thinking(seconds: nil, tools: 0), text: "继续分析")
    summary.trace.append(thought)
    precondition(ChatActivityContent.line(summary) == .thought("继续分析"))
    var repeated = call
    repeated.id = UUID()
    summary.trace.append(repeated)
    precondition(ChatActivityContent.line(summary) == .call(call.banner!, token: 2), "相同文案的下一调用仍要刷新")
    summary.foldsProcessSteps = true
    precondition(ChatActivityContent.line(summary) == .call(call.banner!, token: 2))
    precondition(ChatActivityContent.hasContent(summary))
    print("通过：当前活动行跟随最新思考和调用，重复调用由 token 区分")
}
