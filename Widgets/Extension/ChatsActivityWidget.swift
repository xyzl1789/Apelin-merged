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
                // 内容必须压到系统最小胶囊宽度以内，否则胶囊被撑宽，
                // 挤掉状态栏右侧的信号图标（minis 即是如此）。标记取小。
                MarkView(size: 16, braces: .white)
            } compactTrailing: {
                // 右侧多样化显示：不同状态换不同的 SF Symbol 图标——
                // 有会话等审批亮警告，有失败亮叉，全在跑亮进度圆环，
                // 多会话时把计数用小字叠进圆环中空处，不占额外宽度。
                // 圆环有中空，数字能放进去；实心图标（⚠️、❌、✓）无
                // 中空，计数改放旁边。
                ZStack {
                    Image(systemName: state.statusSymbol)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(state.statusColor)
                    if state.inProgressCount > 1, state.statusSymbol == "arrow.triangle.2.circlepath" {
                        Text(verbatim: "\(state.inProgressCount)")
                            .font(.system(size: 7, weight: .black))
                            .minimumScaleFactor(0.6)
                            .foregroundStyle(.white)
                            .contentTransition(.numericText())
                            .accessibilityHidden(true)
                    }
                }
                .frame(minWidth: 17, alignment: .center)
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
        // 全部完成：照 minis，纯绿色裸对勾，不带圈。
        return "checkmark"
    }

    var statusColor: Color {
        if waitingCount > 0 { return WidgetTheme.island.amber }
        if chats.contains(where: { $0.status == .failed }) { return WidgetTheme.island.red }
        if workingCount > 0 { return WidgetTheme.island.green }
        // 完成态：绿色，同 minis。
        return WidgetTheme.island.green
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


