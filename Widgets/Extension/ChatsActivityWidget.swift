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

/// The lock screen card. Two styles: the compact list, and the leaf garden —
/// one leaf per conversation in progress, green while it works, amber while
/// it waits for an approval, red when it failed. Which one shows is the
/// app's setting (`ChatWidgetAppearance.cardStyle`), read each time the
/// activity renders, so a switch applies on the next update.
@available(iOS 16.2, *)
private struct ChatsLockScreenView: View {
    @Environment(\.colorScheme) private var colorScheme

    let state: ChatWidgetSnapshot

    var body: some View {
        let custom = ChatWidgetAppearance.customBackground
        // 开启自定义底色时沿用恒定深色主题；关闭时回到随系统深浅色切换的
        // 主题，并把底色交回系统——不传 tint，材质跟着壁纸与深浅色走。
        let theme = custom ? WidgetTheme.lockScreen : WidgetTheme(colorScheme)
        Group {
            switch ChatWidgetAppearance.cardStyle {
            case .compact:
                VStack(alignment: .leading, spacing: WidgetSpacing.line) {
                    ChatWidgetHeader(snapshot: state, theme: theme)
                    ChatWidgetRows(snapshot: state, theme: theme, limit: 3)
                }
                .foregroundStyle(theme.ink)
                .activityBackgroundTint(
                    custom ? Color(red: 0, green: 0, blue: 0, opacity: ChatWidgetAppearance.defaultOpacity) : nil
                )
            case .leaf:
                ChatsLeafGarden(state: state, theme: theme)
                    .activityBackgroundTint(
                        custom ? Color(red: 0, green: 0, blue: 0, opacity: ChatWidgetAppearance.defaultOpacity) : nil
                    )
            }
        }
        .padding(WidgetSpacing.card)
        .animation(.easeInOut(duration: 0.35), value: state)
        .activitySystemActionForegroundColor(theme.green)
        .widgetURL(state.mostUrgent?.link)
    }
}

/// The leaf garden: a row of leaves, one per conversation in progress, over
/// the name and counts. Each leaf grows a little with its conversation's
/// rank in the list and takes its status's colour; done chats keep a dim
/// leaf so the garden never looks empty. The change of state replays the
/// grow-in, the one animation the lock screen replays with the activity.
@available(iOS 16.2, *)
private struct ChatsLeafGarden: View {
    let state: ChatWidgetSnapshot
    let theme: WidgetTheme

    /// The tallest a leaf, in points; the rest scale down the row.
    private static let tallest: CGFloat = 46

    var body: some View {
        let shown = Array(state.chats.prefix(4))
        VStack(alignment: .leading, spacing: WidgetSpacing.line) {
            ChatWidgetHeader(snapshot: state, theme: theme)
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, chat in
                    LeafPlant(chat: chat, theme: theme, height: Self.tallest - CGFloat(index) * 6)
                }
                if shown.count < state.totalCount {
                    Text("+\(state.totalCount - shown.count)")
                        .font(.rounded(.footnote, .bold))
                        .opacity(0.5)
                        .padding(.bottom, 4)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: Self.tallest + 6, alignment: .bottom)
            if let summary = state.summaryLine {
                Text(summary)
                    .font(.rounded(.footnote))
                    .opacity(0.6)
                    .lineLimit(1)
            }
        }
        .foregroundStyle(theme.ink)
        .accessibilityElement(children: .combine)
    }

    /// One conversation's plant: a stem with a leaf whose colour is the
    /// status's. Working leaves sit a touch higher than the others so the
    /// garden reads at a glance.
    private struct LeafPlant: View {
        let chat: ChatWidgetSnapshot.Chat
        let theme: WidgetTheme
        let height: CGFloat

        var body: some View {
            VStack(spacing: 2) {
                LeafShape()
                    .fill(color, style: FillStyle(eoFill: true))
                    .frame(width: height * 0.62, height: height * 0.62)
                    .scaleEffect(chat.status == .working ? 1 : 0.88, anchor: .bottom)
                    .animation(.spring(response: 0.5, dampingFraction: 0.7), value: chat.status)
                Rectangle()
                    .fill(theme.ink.opacity(0.35))
                    .frame(width: 1.5, height: height * 0.30)
            }
            .accessibilityHidden(true)
        }

        private var color: Color {
            switch chat.status {
            case .working: MarkView.leafGreen
            case .waiting: theme.amber
            case .failed: theme.red
            case .done: theme.idle
            }
        }
    }
}
