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
            ChatLockScreenView(state: context.state.forActivityDisplay(isStale: context.isStale))
        } dynamicIsland: { context in
            let state = context.state.forActivityDisplay(isStale: context.isStale)
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
                    if let result = state.finishedBadge {
                        HStack(spacing: 3) {
                            Image(systemName: result.symbol)
                                .font(.caption)
                                .foregroundStyle(result.color)
                            Text(verbatim: result.label)
                                .font(.caption.bold())
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(result.color.opacity(0.18), in: Capsule())
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
                        VStack(alignment: .leading, spacing: 5) {
                            ChatActivitySessionRow(chat: chat, state: state)
                            if let result = state.transientResult {
                                ChatActivityResultRow(chat: result.chat)
                            }
                        }
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
                ChatActivityIslandIcon(state: state, font: .body)
            } minimal: {
                ChatActivityIslandIcon(state: state, font: .caption)
            }
            .widgetURL(state.mostUrgent?.link)
        }
    }
}

/// 审批优先，其次是单会话短提示；没有运行会话时才显示批次结果。
@available(iOS 16.2, *)
private struct ChatActivityIslandIcon: View {
    let state: ChatWidgetSnapshot
    let font: Font

    var body: some View {
        if state.waitingCount > 0 {
            symbol("exclamationmark.triangle.fill", color: WidgetTheme.island.amber, label: String(localized: "Needs Approval"))
        } else if let result = state.transientResult {
            let failed = result.chat.status == .failed
            symbol(failed ? "xmark" : "checkmark", color: failed ? WidgetTheme.island.red : WidgetTheme.island.green,
                   label: "\(result.chat.statusWord) · \(result.chat.title)")
        } else if state.workingCount > 0 {
            if let tool = state.currentTool {
                ChatActivityToolIcon(tool: tool, font: font)
            } else if let progress = state.progress {
                symbol(progress.symbol, color: .blue,
                       label: progress.detail.map { "\(progress.title) — \($0)" } ?? progress.title)
            } else if state.answerPreview != nil {
                symbol("text.bubble", color: .blue, label: String(localized: "Replying…"))
            } else {
                symbol("ellipsis.bubble", color: WidgetTheme.island.green, label: String(localized: "Thinking…"))
            }
        } else if let result = state.finishedBadge {
            symbol(result.symbol, color: result.color, label: result.label)
        } else {
            MarkView(size: 16, braces: .white)
        }
    }

    private func symbol(_ name: String, color: Color, label: String) -> some View {
        Image(systemName: name)
            .font(font)
            .foregroundStyle(color)
            .accessibilityLabel(Text(verbatim: label))
            .id(name)
            .transition(.opacity.animation(.easeInOut(duration: 0.35)))
    }
}

@available(iOS 16.2, *)
private extension ChatWidgetSnapshot {
    var finishedBadge: (symbol: String, color: Color, label: String)? {
        guard inProgressCount == 0 else { return nil }
        switch batchOutcome {
        case .succeeded: return ("checkmark.circle.fill", WidgetTheme.island.green, String(localized: "All Done"))
        case .failed: return ("xmark.circle.fill", WidgetTheme.island.red, String(localized: "Failed"))
        case .stopped: return ("stop.circle.fill", WidgetTheme.island.amber, String(localized: "Stopped"))
        case nil: return nil
        }
    }
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
/// 下方的一行随思考、工具调用和回答进度切换。
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
                let stopped = state.inProgressCount == 0 && state.batchOutcome == .stopped
                Image(systemName: stopped ? "stop.circle.fill" : chat.activitySymbol)
                    .font(.caption)
                    .foregroundStyle(stopped ? WidgetTheme.island.amber : chat.activityColor)
                Text(verbatim: stopped ? String(localized: "Stopped") : chat.statusLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Text(verbatim: chat.projectName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            if chat.status != .waiting {
                if let tool = state.currentTool {
                    activityDetail(symbol: tool.symbol, title: tool.title)
                } else if let progress = state.progress {
                    // 实时进度行：思考显示实际流出的内容，工具阶段用详情页同款图标。
                    activityDetail(symbol: progress.symbol,
                                   title: progress.detail.map { "\(progress.title) — \($0)" } ?? progress.title)
                        .privacySensitive()
                } else if let answer = state.answerPreview {
                    activityDetail(symbol: "text.bubble", title: answer)
                        .privacySensitive()
                } else if chat.status == .working {
                    activityDetail(symbol: "ellipsis.bubble", title: String(localized: "Thinking…"))
                }
            }
        }
    }

    private func activityDetail(symbol: String, title: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
                .accessibilityHidden(true)
            Text(verbatim: title)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .font(.caption)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@available(iOS 16.2, *)
private struct ChatActivityResultRow: View {
    let chat: ChatWidgetSnapshot.Chat

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: chat.activitySymbol)
                .foregroundStyle(chat.activityColor)
                .accessibilityHidden(true)
            Text(verbatim: "\(chat.title) · \(chat.statusWord)")
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 6)
        }
        .font(.caption)
        .accessibilityElement(children: .combine)
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
                if let result = state.finishedBadge {
                    Text(verbatim: result.label)
                        .font(.caption.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(result.color.opacity(0.18), in: Capsule())
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
                if let result = state.transientResult {
                    ChatActivityResultRow(chat: result.chat)
                }
            }
        }
        .foregroundStyle(theme.ink)
        .padding()
        .activityBackgroundTint(ChatWidgetAppearance.backgroundTint(for: colorScheme))
        .activitySystemActionForegroundColor(theme.green)
        .widgetURL(state.mostUrgent?.link)
    }
}
