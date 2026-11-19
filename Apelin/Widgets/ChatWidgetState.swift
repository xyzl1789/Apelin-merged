import ApelinCore
import ApelinProtocol
import Foundation

extension ChatRecord {
    /// Whether the widgets list it: a conversation that holds something.
    /// An untouched New Chat holds nothing but its place in the sidebar.
    var isListedInWidgets: Bool {
        !events.isEmpty || sending != nil
    }

    /// What the widgets say about it, from the same events the transcript
    /// is built from. Waiting needs a running turn (`isWorking`): an
    /// approval left asking by a session that ended with the host waits
    /// for nothing. Failed is a last turn that finished `failed`, or one
    /// cut off by its task failing; a session that merely ended after its
    /// turn finished is done.
    func widgetChat(projectName: String?) -> ChatWidgetSnapshot.Chat {
        var waiting: [(id: String, tool: String)] = []
        var turnOpen = false
        var turnStart: Date?
        var failed = false
        for event in events {
            let payload = event.payload
            switch event.kind {
            case "prompt", "steer", "messageStarted":
                // 一轮的开始时间只认第一次：`messageStarted` 在一轮里
                // 每个助手消息段都会发一次（中途插入的引导也算），每次
                // 都写会让计时器回到 0 重新走，显示时长与真实运行时间
                // 对不上。turn 已经开着就保留原来的开始时间。
                if !turnOpen {
                    turnStart = event.time
                }
                turnOpen = true
                failed = false
            case "approvalRequested":
                if let id = payload?["approvalID"]?.stringValue {
                    // By today's name: the widget names only those.
                    let tool = payload?["tool"]?.stringValue ?? ""
                    waiting.append((id, AgentToolName.canonical(tool)?.rawValue ?? tool))
                }
            case "approvalResolved":
                let id = payload?["approvalID"]?.stringValue
                waiting.removeAll { $0.id == id }
            case "finished":
                failed = payload?["reason"]?.stringValue == "failed"
                turnOpen = false
                waiting.removeAll()
            case TaskEvent.stateKind:
                if let state = payload?["state"]?.stringValue.flatMap(TaskState.init(rawValue:)), state.isTerminal {
                    if turnOpen, state == .failed || state == .interrupted {
                        failed = true
                    }
                    turnOpen = false
                    waiting.removeAll()
                }
            default:
                break
            }
        }
        let status: ChatWidgetSnapshot.Chat.Status = if summary.isWorking {
            waiting.isEmpty ? .working : .waiting
        } else {
            failed ? .failed : .done
        }
        return ChatWidgetSnapshot.Chat(
            id: summary.id.uuidString,
            title: String(summary.displayTitle.prefix(80)),
            project: projectName,
            status: status,
            approvalTool: status == .waiting ? waiting.last?.tool : nil,
            startedAt: turnOpen ? turnStart : nil,
        )
    }
}
