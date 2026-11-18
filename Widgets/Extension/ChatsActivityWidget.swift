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
                    if state.inProgressCount > 0, state.statusSymbol == "arrow.triangle.2.circlepath" {
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
                // 照 minis 的 CompactTrailingView：右侧显示工作状态符号，
                // 颜色随状态（等待琥珀、失败红、进行中绿），切换时淡入淡出。
                Image(systemName: state.statusSymbol)
                    .font(.body)
                    .foregroundStyle(state.statusColor)
                    .id(state.statusSymbol)
                    .transition(.opacity.animation(.easeInOut(duration: 0.35)))
            } minimal: {
                // 多个实时活动折叠成一点时，照 Minis 的 MinimalIconView：
                // 标记本体挂计数小字（9pt，offset 8,-8），计数为 0 时只有
                // 标记本身。
                ZStack {
                    MarkView(size: 26, braces: .white)
                    if state.inProgressCount > 0 {
                        Text(verbatim: "\(state.inProgressCount)")
                            .font(.system(size: 9, weight: .bold).monospacedDigit())
                            .foregroundStyle(.white)
                            .offset(x: 8, y: -8)
                    }
                }
            }
            .widgetURL(state.mostUrgent?.link)
        }
    }
}

/// 收起状态的整体符号：等待审批是警告三角，最新失败是叉，运行中
/// 是进度环，全部完成是纯绿对勾。
@available(iOS 16.2, *)
private extension ChatWidgetSnapshot {
    var statusSymbol: String {
        if waitingCount > 0 { return "exclamationmark.triangle.fill" }
        if chats.contains(where: { $0.status == .failed }) { return "xmark.circle.fill" }
        if workingCount > 0 { return "arrow.triangle.2.circlepath" }
        return "checkmark"
    }

    var statusColor: Color {
        if waitingCount > 0 { return WidgetTheme.island.amber }
        if chats.contains(where: { $0.status == .failed }) { return WidgetTheme.island.red }
        if workingCount > 0 { return WidgetTheme.island.green }
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

/// 展开岛底部与锁屏共用的当前会话行：会话气泡 + 标题，状态图标 + 状态词，
/// 多于一个进行中会话时带上序号。
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
                if let start = chat.startedAt {
                    // 照 minis：当前任务的进行时长，系统自走计时，不需要每秒推快照。
                    Text(timerInterval: start ... Date().addingTimeInterval(86_400), countsDown: false)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                        .fixedSize()
                }
                Text(verbatim: chat.projectName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

/// 锁屏卡片：顶部身份胶囊 + 状态摘要胶囊，下面当前会话行。
/// 半透明背景仍由 activityBackgroundTint 交给系统材质，外观跟随深浅色。
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
