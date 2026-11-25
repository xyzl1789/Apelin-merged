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
                ChatActivityIslandIcon(state: state, font: .callout)
            } minimal: {
                ChatActivityIslandIcon(state: state, font: .caption)
            }
            .widgetURL(state.mostUrgent?.link)
        }
    }
}

/// 收起态跟随锁屏主行；另一条会话的短提示留在卡片自己的结果行。
@available(iOS 16.2, *)
private struct ChatActivityIslandIcon: View {
    let state: ChatWidgetSnapshot
    let font: Font

    var body: some View {
        if let chat = state.mostUrgent {
            let phase = state.sessionPhase(for: chat)
            // 工具图标本身不含参数；不让隐私遮盖把整个图标藏起来。
            symbol(phase.symbol, color: phase.color,
                   label: phase.isTool ? chat.statusWord : phase.title)
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
        case .stopping: return "stop.circle.fill"
        case .waiting: return "exclamationmark.triangle.fill"
        case .done: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    var activityColor: Color {
        switch status {
        case .working: return WidgetTheme.island.green
        case .stopping: return WidgetTheme.island.amber
        case .waiting: return WidgetTheme.island.amber
        case .done: return WidgetTheme.island.idle
        case .failed: return WidgetTheme.island.red
        }
    }
}

/// 锁屏、展开岛和收起岛从同一主会话阶段选图标，不混入其他会话的结果。
@available(iOS 16.2, *)
private extension ChatWidgetSnapshot {
    func sessionPhase(for chat: Chat) -> (symbol: String, color: Color, title: String, detail: String?, isTool: Bool) {
        if let badge = finishedBadge {
            let detail = detailsEnabled && batchOutcome == .succeeded ? answerPreview : nil
            let title = batchOutcome == .stopped ? badge.label : chat.statusLine
            return (badge.symbol, badge.color, title, detail, false)
        }
        guard detailsEnabled else {
            return (chat.activitySymbol, chat.activityColor, chat.statusLine, nil, false)
        }
        if chat.isInProgress, let progress {
            if progress.stage == .waitingForApproval {
                let detail = [progress.title, progress.detail].compactMap { $0 }.joined(separator: " — ")
                return (progress.symbol, chat.activityColor, chat.statusWord, detail, false)
            }
            if progress.stage == .waitingForNextStep, progress.symbol == "ellipsis.circle", let tool = recentTools.first {
                return (tool.symbol, chat.activityColor, tool.title, tool.result ?? tool.detail, true)
            }
            if progress.stage == .thinking, progress.detail == nil,
               flowNotes.contains(where: { $0.symbol == "bubble.left.and.bubble.right" }) {
                return ("bubble.left.and.bubble.right", chat.activityColor, "正在处理协作消息", nil, false)
            }
            return (progress.symbol, chat.activityColor, progress.title, progress.detail, progress.stage == .tool)
        }
        if chat.status == .working, let tool = currentTool {
            return (tool.symbol, chat.activityColor, tool.title, tool.detail, true)
        }
        if chat.status == .working, let answer = answerPreview {
            return ("text.bubble", chat.activityColor, String(localized: "Replying…"), answer, false)
        }
        return (chat.activitySymbol, chat.activityColor, chat.statusLine, nil, false)
    }
}

/// 展开岛底部与锁屏共用的当前会话行。
@available(iOS 16.2, *)
private struct ChatActivitySessionRow: View {
    let chat: ChatWidgetSnapshot.Chat
    let state: ChatWidgetSnapshot

    var body: some View {
        let phase = state.sessionPhase(for: chat)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: "bubble.left.fill")
                    .font(.caption)
                    .foregroundStyle(.blue)
                    .frame(width: 16)
                    .accessibilityHidden(true)
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
                if let start = chat.startedAt, chat.status == .working || chat.status == .stopping || chat.status == .waiting {
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
                Image(systemName: phase.symbol)
                    .font(.caption)
                    .foregroundStyle(phase.color)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(verbatim: phase.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(1)
                    .privacySensitive(phase.isTool)
                Spacer(minLength: 6)
                Text(verbatim: chat.projectName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            // 关闭保活或进入终态只收起流程详情和工具记录，身份、项目与基本状态始终保留。
            if state.detailsEnabled && state.finishedBadge == nil {
                if let detail = phase.detail {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: phase.symbol)
                            .font(.caption)
                            .foregroundStyle(phase.color)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        Text(verbatim: detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .privacySensitive()
                    }
                }
                ForEach(state.recentTools.indices, id: \.self) { index in
                    let tool = state.recentTools[index]
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Image(systemName: tool.symbol)
                            .frame(width: 16)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(verbatim: tool.title).lineLimit(1)
                            if let detail = tool.detail {
                                Text(verbatim: detail).lineLimit(1)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .privacySensitive()
                }
            }
        }
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
