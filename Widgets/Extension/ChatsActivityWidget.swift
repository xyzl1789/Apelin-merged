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
                MarkView(size: 22, braces: .white)
                    .frame(width: 26, alignment: .leading)
            } compactTrailing: {
                Text(verbatim: "\(state.totalCount)")
                    .font(.rounded(.title3, .bold))
                    .foregroundStyle(state.waitingCount > 0 ? WidgetTheme.island.amber : .white)
                    .contentTransition(.numericText())
                    .frame(width: 26, alignment: .trailing)
                    .accessibilityLabel(Text(state.summaryLine ?? ""))
            } minimal: {
                MarkView(size: 24, braces: .white)
            }
            .widgetURL(state.mostUrgent?.link)
        }
    }
}

/// The lock screen card: the header — mark, name and counts — then a row
/// per conversation in progress.
@available(iOS 16.2, *)
private struct ChatsLockScreenView: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: ChatWidgetSnapshot

    var body: some View {
        let custom = ChatWidgetAppearance.customBackground
        // 开启自定义底色时沿用恒定深色主题；关闭时回到原项目随系统深浅色
        // 自动切换的主题。这样外观切换后文字和底色不会一个亮一个暗。
        let theme = custom ? WidgetTheme.lockScreen : WidgetTheme(colorScheme)
        // 自定义底色是半透明黑，盖在系统材质上让壁纸隐约透出；关闭时把
        // 底色交回系统，黑或白跟着视图的深浅色自动切换。
        let tint = custom
            ? Color(red: 0, green: 0, blue: 0, opacity: ChatWidgetAppearance.backgroundOpacity)
            : theme.ground
        VStack(alignment: .leading, spacing: WidgetSpacing.line) {
            ChatWidgetHeader(snapshot: state, theme: theme)
            ChatWidgetRows(snapshot: state, theme: theme, limit: 3)
        }
        .foregroundStyle(theme.ink)
        .padding(WidgetSpacing.card)
        .animation(.easeInOut(duration: 0.35), value: state)
        .activityBackgroundTint(tint)
        .activitySystemActionForegroundColor(theme.green)
        .widgetURL(state.mostUrgent?.link)
    }
}
