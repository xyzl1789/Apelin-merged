import ActivityKit
import SwiftUI
import WidgetKit

/// The conversations in progress on the lock screen and in the Dynamic
/// Island, after iGhostVT's terminal sessions: the lock screen lists up to
/// three; closed, the island wears the mark with the count, amber while an
/// approval waits; minimal, the mark alone; expanded, the counts and the
/// first two. A tap opens the conversation waiting, else the latest working.
@available(iOS 16.2, *)
struct ChatsActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ChatActivityAttributes.self) { context in
            ChatsLockScreenView(state: context.state)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    // inset as the summary below is, so the name sits over it
                    Text(verbatim: "Apelin")
                        .font(.rounded(.subheadline, .bold))
                        .padding(.leading, WidgetSpacing.line)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    MarkView(size: 22, braces: .white)
                        .padding(.trailing, WidgetSpacing.line)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: WidgetSpacing.line) {
                        if let summary = state.summaryLine {
                            Text(summary)
                                .font(.rounded(.subheadline))
                                .opacity(0.6)
                                .lineLimit(1)
                                .contentTransition(.numericText())
                        }
                        ChatWidgetRows(snapshot: state, theme: .island, limit: 2)
                    }
                    .padding(WidgetSpacing.line)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } compactLeading: {
                // 收窄胶囊：标记不加固定宽框，系统按实际尺寸撑。
                MarkView(size: 18, braces: .white)
                    .padding(.trailing, 4)
            } compactTrailing: {
                // 右侧多样化显示：不同状态换不同的 SF Symbol 图标——
                // 有会话等审批亮警告，有失败亮叉，全在跑亮进度圆环；
                // 多于一个会话时图标旁带计数。
                HStack(spacing: 3) {
                    Image(systemName: state.statusSymbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(state.statusColor)
                    if state.totalCount > 1 {
                        Text(verbatim: "\(state.totalCount)")
                            .font(.rounded(.caption, .bold))
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(state.summaryLine ?? ""))
            } minimal: {
                MarkView(size: 24, braces: .white)
            }
            .widgetURL(state.mostUrgent?.link)
        }
    }
}

/// The compact trailing region's status icon: the most urgent conversation's
/// state decides it — a warning triangle while an approval waits, an x-mark
/// when the newest failed, a progress ring while anything runs, a checkmark
/// when everything is done.
@available(iOS 16.2, *)
private extension ChatWidgetSnapshot {
    var statusSymbol: String {
        if waitingCount > 0 { return "exclamationmark.triangle.fill" }
        if chats.contains(where: { $0.status == .failed }) { return "xmark.circle.fill" }
        if workingCount > 0 { return "arrow.triangle.2.circlepath" }
        return "checkmark.circle.fill"
    }

    var statusColor: Color {
        if waitingCount > 0 { return WidgetTheme.island.amber }
        if chats.contains(where: { $0.status == .failed }) { return WidgetTheme.island.red }
        if workingCount > 0 { return WidgetTheme.island.green }
        return WidgetTheme.island.idle
    }
}

/// The lock screen card: the compact list, over the adaptive semi-transparent
/// background tint — dark mode translucent black, light mode translucent
/// white — layered into the system material, which keeps the wallpaper
/// showing through and follows the appearance.
@available(iOS 16.2, *)
private struct ChatsLockScreenView: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: ChatWidgetSnapshot

    var body: some View {
        // 跟随深浅色的主题与半透明 tint；材质由系统提供。
        let theme = WidgetTheme(colorScheme)
        VStack(alignment: .leading, spacing: WidgetSpacing.line) {
            ChatWidgetHeader(snapshot: state, theme: theme)
            ChatWidgetRows(snapshot: state, theme: theme, limit: 3)
        }
        .foregroundStyle(theme.ink)
        .padding(WidgetSpacing.card)
        .activityBackgroundTint(ChatWidgetAppearance.backgroundTint(for: colorScheme))
        .animation(.easeInOut(duration: 0.35), value: state)
        .activitySystemActionForegroundColor(theme.green)
        .widgetURL(state.mostUrgent?.link)
    }
}


