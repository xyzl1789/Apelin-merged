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
                DynamicIslandExpandedRegion(.leading, priority: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles")
                            .font(.caption2)
                        Text(verbatim: "Apelin")
                            .font(.caption.bold())
                            .lineLimit(1)
                            .fixedSize()
                            .layoutPriority(10)
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
                        .id(state)
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
            // 空详情退出布局；直接测量当前行，避免选型容器沿用旧的可用高度。
            if state.detailsEnabled && !details.isEmpty {
                ChatActivityDetailLayout {
                    flowRows(limit: 3, lines: 2)
                }
                // 只刷新详情子树的布局身份，不结束或重建 ActivityKit 活动。
                .id(Array(details.prefix(3)))
                .clipped()
                .layoutPriority(-1)
            }
        }
    }

    /// 来源与当前步骤先显示，其他结果按余量裁剪；不把历史工具冒充终态。
    private var details: [ChatWidgetSnapshot.ToolActivity] {
        let phase = state.sessionPhase(for: chat)
        var rows = state.flowNotes.filter { $0.title != phase.title || $0.detail != phase.detail }
        if let detail = phase.detail {
            rows.insert(.init(symbol: phase.symbol, title: detail), at: min(1, rows.count))
        }
        if state.finishedBadge == nil {
            for tool in state.recentTools {
                var row = tool
                let suffix = [tool.result, tool.detail].compactMap { $0 }.joined(separator: " · ")
                row.detail = suffix.isEmpty ? nil : suffix
                rows.append(row)
            }
        }
        if let metrics = state.metrics {
            rows.append(.init(symbol: "number", title: metrics))
        }
        return rows
    }

    private func flowRows(limit: Int, lines: Int) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(details.prefix(limit).enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: item.symbol)
                        .foregroundStyle(item.failed == true ? WidgetTheme.island.red : .secondary)
                        .frame(width: 16)
                        .accessibilityHidden(true)
                    Text(verbatim: [item.title, item.detail].compactMap { $0 }.joined(separator: " · "))
                        .lineLimit(lines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .privacySensitive()
            }
        }
        // 详情始终按当前宽度的自然高度排版；外层只裁剪超出预算的底部。
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 先以未限定高度量取详情，再裁剪到剩余预算；不把父容器高度当成内容高度。
/// 测量与放置使用同一宽度、同一个自然高度提案，减少内容时也重新取自然尺寸。
@available(iOS 16.2, *)
private struct ChatActivityDetailLayout: Layout {
    private let maximumHeight: CGFloat = 76

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let content = subviews.first else { return .zero }
        let height = max(0, min(proposal.height ?? maximumHeight, maximumHeight))
        let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: size.width, height: min(size.height, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(width: bounds.width, height: nil)
        )
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
/// 半透明 tint 叠加在系统毛玻璃上，并按 colorScheme 在深浅色间切换；
/// 外观变化时由发布器重推活动内容，使系统重新应用 tint。
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
                        .lineLimit(1)
                        .fixedSize()
                        .layoutPriority(10)
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
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(2)
            if let chat = state.mostUrgent {
                ChatActivitySessionRow(chat: chat, state: state)
                if let result = state.transientResult {
                    ChatActivityResultRow(chat: result.chat)
                }
            }
        }
        // 锁屏宿主可能继续提议上一次的较大高度；根视图始终按当前内容自然高度报告。
        .fixedSize(horizontal: false, vertical: true)
        // 让远程视图宿主重新拟合整卡高度，而非仅替换旧高度内的详情文字。
        .id(state)
        .foregroundStyle(theme.ink)
        .padding()
        .activityBackgroundTint(ChatWidgetAppearance.backgroundTint(for: colorScheme))
        .activitySystemActionForegroundColor(theme.green)
        .widgetURL(state.mostUrgent?.link)
    }
}
