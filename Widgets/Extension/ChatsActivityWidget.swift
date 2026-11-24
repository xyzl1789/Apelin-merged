import ActivityKit
import SwiftUI
import WidgetKit

/// 灵动岛与锁屏上的实时活动，照 Minis 的样子：展开时身份胶囊 + 进行中
/// 计数胶囊 + 当前会话行，收起时图标旁带数字；点按打开最需要处理的会话。
/// 字段取 Apelin 自己的快照；隐私模式、Loop、计时器与音频这些 Minis 专有
/// 的东西没有对应数据，不画。
@available(iOS 16.2, *)
struct ChatsActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChatActivityAttributes.self) { context in
            ChatLockScreenView(state: context.state)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text(verbatim: "Apelin")
                            .font(.caption.bold())
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.white.opacity(0.15), in: Capsule())
                    .padding(.leading, 8)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if state.allCompleted {
                        HStack(spacing: 3) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(.green)
                            Text(verbatim: "\(state.chats.count)")
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.18), in: Capsule())
                        .padding(.trailing, 8)
                    } else {
                        Text(state.summaryLine ?? "")
                            .font(.caption.bold())
                            .contentTransition(.numericText())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.white.opacity(0.15), in: Capsule())
                            .padding(.trailing, 8)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let chat = state.mostUrgent {
                        ChatActivitySessionRow(chat: chat, state: state)
                            .padding(.leading, 8)
                            .padding(.trailing, 8)
                            .padding(.top, 4)
                    }
                }
            } compactLeading: {
                // 照 Minis 的 compactLeading：图标与数字并排（HStack，间距 3），
                // 不再用叠加徽标——叠在 18pt 图标右上角的 8pt 数字会被灵动岛
                // 收起态的圆角和边界裁掉，只剩一个小点。并排的数字完整可见。
                HStack(spacing: 3) {
                    MarkView(size: 16, braces: .white)
                    if state.inProgressCount > 0 {
                        Text(verbatim: "\(state.inProgressCount)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(state.summaryLine ?? ""))
            } compactTrailing: {
                if let tool = state.currentTool {
                    ChatActivityToolIcon(tool: tool, font: .body)
                } else {
                    Image(systemName: state.statusSymbol)
                        .font(.body)
                        .foregroundStyle(state.statusColor)
                        .id(state.statusSymbol)
                        .transition(.opacity.animation(.easeInOut(duration: 0.35)))
                }
            } minimal: {
                if let tool = state.currentTool {
                    ChatActivityToolIcon(tool: tool, font: .caption)
                } else {
                    MarkView(size: 26, braces: .white)
                }
            }
            .widgetURL(state.mostUrgent?.link)
        }
    }
}

/// 收起状态的整体符号：等待审批是警告三角，有工作在跑是进度环，
/// 只有全部结束且出过错才是叉，全成功是纯绿对勾。进行中优先于历史失败，
/// 免得一个旧的失败会话让新任务在跑时也一直顶着 ❌。
@available(iOS 16.2, *)
private extension ChatWidgetSnapshot {
    var statusSymbol: String {
        if waitingCount > 0 { return "exclamationmark.triangle.fill" }
        if workingCount > 0 { return "arrow.triangle.2.circlepath" }
        if chats.contains(where: { $0.status == .failed }) { return "xmark.circle.fill" }
        // 全部完成：照 Minis 的绿色圆底对勾（caption 圈勾），收起态不再
        // 用 body 字号的裸对勾——那个明显偏大。
        return "checkmark.circle.fill"
    }

    var statusColor: Color {
        if waitingCount > 0 { return WidgetTheme.island.amber }
        if workingCount > 0 { return WidgetTheme.island.green }
        if chats.contains(where: { $0.status == .failed }) { return WidgetTheme.island.red }
        return WidgetTheme.island.green
    }

    /// 没有进行中的会话、也没有失败时才算全部完成；有失败的会话仍显示红叉。
    var allCompleted: Bool { inProgressCount == 0 && !chats.contains(where: { $0.status == .failed }) }
}

/// 单个会话在状态行上的图标与颜色，照 minis 的工具图标那一行。
@available(iOS 16.2, *)
private extension ChatWidgetSnapshot.Chat {
    var activitySymbol: String {
        switch status {
        case .working: return "arrow.triangle.2.circlepath"
        case .waiting: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var activityColor: Color {
        switch status {
        case .working: return WidgetTheme.island.green
        case .waiting: return WidgetTheme.island.amber
        case .done: return WidgetTheme.island.idle
        case .failed: return WidgetTheme.island.red
        }
    }
}

/// 展开岛底部与锁屏共用的当前会话行：保留原有的标题与状态布局，
/// 有工具正在运行时在状态行下方单列操作说明。
@available(iOS 16.2, *)
private struct ChatActivitySessionRow: View {
    let chat: ChatWidgetSnapshot.Chat
    let state: ChatWidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                Text(verbatim: chat.title)
                    .font(.callout.bold())
                    .lineLimit(1)
                if state.inProgressCount > 1 {
                    Text(verbatim: "1/\(state.inProgressCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 6)
                // 照 Minis：计时胶囊在标题行右侧（Spacer 之后），caption2 字号。
                if let start = chat.startedAt, chat.status == .working || chat.status == .waiting {
                    Text("00:00")
                        .font(.caption2.monospacedDigit())
                        .hidden()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .overlay {
                            Text(start, style: .timer)
                                .font(.caption2.monospacedDigit())
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                        }
                        .background(.white.opacity(0.12), in: Capsule())
                }
            }
            HStack(spacing: 5) {
                Image(systemName: chat.activitySymbol)
                    .font(.caption)
                    .foregroundStyle(chat.activityColor)
                Text(verbatim: chat.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: chat.projectName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if chat.status == .working, let tool = state.currentTool {
                HStack(spacing: 5) {
                    ChatActivityToolIcon(tool: tool, font: .caption)
                        .accessibilityHidden(true)
                    Text(verbatim: tool.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

@available(iOS 16.2, *)
private struct ChatActivityToolIcon: View {
    let tool: ChatWidgetSnapshot.ToolActivity
    let font: Font

    var body: some View {
        Image(systemName: tool.symbol)
            .font(font)
            .foregroundStyle(.blue)
            .id(tool.symbol)
            .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            .accessibilityLabel(Text(verbatim: tool.title))
    }
}

/// 锁屏卡片：顶部身份胶囊 + 状态摘要胶囊，下面当前会话行。
/// 照 Minis：不加 `activityBackgroundTint`，交给系统默认的毛玻璃材质，
/// 深浅色永远由系统自己画——自创的半透明 tint 只在活动内容更新时被
/// 重画，配合外观探针重推也追不稳，是实时活动整卡空白的另一个嫌疑。
@available(iOS 16.2, *)
private struct ChatLockScreenView: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: ChatWidgetSnapshot

    var body: some View {
        let theme = WidgetTheme(colorScheme)
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                HStack(spacing: 3) {
                    Image(systemName: "sparkles")
                        .font(.caption2)
                    Text(verbatim: "Apelin")
                        .font(.caption.bold())
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.15), in: Capsule())
                Spacer()
                if state.allCompleted {
                    Text("All Done")
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.green.opacity(0.18), in: Capsule())
                } else if let summary = state.summaryLine {
                    Text(summary)
                        .font(.caption.bold())
                        .contentTransition(.numericText())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.15), in: Capsule())
                }
            }
            if let chat = state.mostUrgent {
                ChatActivitySessionRow(chat: chat, state: state)
            }
        }
        .foregroundStyle(theme.ink)
        .padding()
        .activityBackgroundTint(ChatWidgetAppearance.backgroundTint(for: colorScheme))
        .animation(.easeInOut(duration: 0.35), value: state)
        .activitySystemActionForegroundColor(theme.green)
        .widgetURL(state.mostUrgent?.link)
    }
}
