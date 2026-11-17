import ApelinCore
import Then
import UIKit

/// 会话用量详情：从聊天页上下文环下方进入，展示本会话的 token 用量。
/// 卡片样式参考 TrollAgent 的 TokenUsageDetailView：
/// 「当前上下文」进度条按占用分级着色（≥75% 橙、≥90% 红），
/// 下方四格统计输入（含缓存）、输出、缓存读、缓存写与缓存命中率。
/// 数据来自本会话在 `usage/usage.jsonl` 里的记录与最后的上下文占用。
final class ChatUsageDetailController: UIViewController {
    private enum Level {
        case normal, elevated, high

        var color: UIColor {
            switch self {
            case .normal: .systemGreen
            case .elevated: .systemOrange
            case .high: .systemRed
            }
        }
    }

    private struct Totals {
        var count = 0
        var input = 0
        var output = 0
        var cacheRead = 0
        var cacheWrite = 0
    }

    private let sessionID: String
    private var totals = Totals()
    private var usage: ChatContextUsage?
    /// 全量记录（不分会话），供「总览」与「最大会话 TOP8」两卡用。
    private var allRecords: [UsageRecord] = []
    /// 会话 id → 标题，TOP 卡的行名。
    private var sessionTitles: [String: String] = [:]

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private let contextCard = UIView()
    private let contextTitleLabel = UILabel()
    private let contextValueLabel = UILabel()
    private let contextPercentLabel = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private let contextNoteLabel = UILabel()
    private let statsCard = UIView()
    private let statsStack = UIStackView()
    private let overviewCard = UIView()
    private let overviewStack = UIStackView()
    private let rankingCard = UIView()
    private let rankingStack = UIStackView()
    private let modelsCard = UIView()
    private let modelsStack = UIStackView()

    /// 按模型汇总：模型 id → (次数, 输入含缓存, 输出)。
    private var byModel: [(model: String, count: Int, prompt: Int, output: Int)] = []

    init(sessionID: String, usage: ChatContextUsage?) {
        self.sessionID = sessionID
        self.usage = usage
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(sessionID:usage:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "会话用量")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.backButtonDisplayMode = .minimal

        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

        buildContextCard()
        buildStatsCard()
        buildOverviewCard()
        buildRankingCard()

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: view.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: scrollView.frameLayoutGuide.trailingAnchor, constant: -16),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        loadRecords()
    }

    private func buildContextCard() {
        contextCard.backgroundColor = .secondarySystemGroupedBackground
        contextCard.layer.cornerRadius = 14
        contextCard.layer.cornerCurve = .continuous

        contextTitleLabel.text = String(localized: "当前上下文")
        contextTitleLabel.font = .preferredFont(forTextStyle: .subheadline)
        contextTitleLabel.font = Self.weighted(contextTitleLabel.font, .semibold)
        contextTitleLabel.textColor = .label
        contextTitleLabel.adjustsFontForContentSizeCategory = true

        contextValueLabel.font = .preferredFont(forTextStyle: .headline)
        contextValueLabel.textColor = .label
        contextValueLabel.adjustsFontForContentSizeCategory = true
        contextValueLabel.accessibilityLabel = String(localized: "已使用上下文")

        contextPercentLabel.font = .preferredFont(forTextStyle: .caption1)
        contextPercentLabel.textColor = .secondaryLabel
        contextPercentLabel.adjustsFontForContentSizeCategory = true

        track.backgroundColor = UIColor.separator.withAlphaComponent(0.4)
        track.layer.cornerRadius = 4
        track.clipsToBounds = true

        fill.layer.cornerRadius = 4
        track.addSubview(fill)

        contextNoteLabel.font = .preferredFont(forTextStyle: .caption2)
        contextNoteLabel.textColor = .secondaryLabel
        contextNoteLabel.numberOfLines = 0
        contextNoteLabel.adjustsFontForContentSizeCategory = true
        contextNoteLabel.text = String(localized: "占用为模型最近一次请求报告的上下文用量；达到压缩阈值后对话会自动压缩。")

        for subview in [contextTitleLabel, contextValueLabel, contextPercentLabel, track, contextNoteLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contextCard.addSubview(subview)
        }
        stack.addArrangedSubview(contextCard)
    }

    private func buildStatsCard() {
        statsCard.backgroundColor = .secondarySystemGroupedBackground
        statsCard.layer.cornerRadius = 14
        statsCard.layer.cornerCurve = .continuous

        let title = UILabel()
        title.text = String(localized: "累计用量")
        title.font = Self.weighted(.preferredFont(forTextStyle: .subheadline), .semibold)
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true

        statsStack.axis = .vertical
        statsStack.spacing = 10

        for subview in [title, statsStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            statsCard.addSubview(subview)
        }
        stack.addArrangedSubview(statsCard)

        modelsCard.backgroundColor = .secondarySystemGroupedBackground
        modelsCard.layer.cornerRadius = 14
        modelsCard.layer.cornerCurve = .continuous

        let modelsTitle = UILabel()
        modelsTitle.text = String(localized: "按模型")
        modelsTitle.font = Self.weighted(.preferredFont(forTextStyle: .subheadline), .semibold)
        modelsTitle.textColor = .label
        modelsTitle.adjustsFontForContentSizeCategory = true

        modelsStack.axis = .vertical
        modelsStack.spacing = 10

        for subview in [modelsTitle, modelsStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            modelsCard.addSubview(subview)
        }
        stack.addArrangedSubview(modelsCard)
    }

    /// 「总览」卡（TrollAgent 同构）：会话数、消息数无法从这里拿到，
    /// 用请求次数、总输入（含缓存）、总输出与最大会话代替。
    private func buildOverviewCard() {
        overviewCard.backgroundColor = .secondarySystemGroupedBackground
        overviewCard.layer.cornerRadius = 14
        overviewCard.layer.cornerCurve = .continuous

        let title = UILabel()
        title.text = String(localized: "总览")
        title.font = Self.weighted(.preferredFont(forTextStyle: .subheadline), .semibold)
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true

        overviewStack.axis = .vertical
        overviewStack.spacing = 10

        for subview in [title, overviewStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            overviewCard.addSubview(subview)
        }
        stack.addArrangedSubview(overviewCard)
    }

    /// 「最大会话 TOP8」卡：按全部请求量最大的会话排（输入含缓存 + 输出）。
    private func buildRankingCard() {
        rankingCard.backgroundColor = .secondarySystemGroupedBackground
        rankingCard.layer.cornerRadius = 14
        rankingCard.layer.cornerCurve = .continuous

        let title = UILabel()
        title.text = String(localized: "最大会话 TOP8")
        title.font = Self.weighted(.preferredFont(forTextStyle: .subheadline), .semibold)
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true

        rankingStack.axis = .vertical
        rankingStack.spacing = 8

        for subview in [title, rankingStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            rankingCard.addSubview(subview)
        }
        stack.addArrangedSubview(rankingCard)
    }

    private func loadRecords() {
        let url = UsageRecorder.file(in: DataFolder.app.root)
        let session = sessionID
        let loaded = Task.detached {
            UsageRecorder.readAll(from: url)
        }
        Task { [weak self] in
            let all = await loaded.value
            guard let self else { return }
            self.allRecords = all
            let records = all.filter { $0.sessionID == session }.sorted { $0.time < $1.time }
            var totals = Totals()
            var models: [String: (count: Int, prompt: Int, output: Int)] = [:]
            for record in records {
                totals.count += 1
                totals.input += record.input
                totals.output += record.output
                totals.cacheRead += record.cacheRead
                totals.cacheWrite += record.cacheWrite
                let entry = models[record.model, default: (0, 0, 0)]
                models[record.model] = (
                    entry.count + 1,
                    entry.prompt + record.input + record.cacheRead + record.cacheWrite,
                    entry.output + record.output,
                )
            }
            self.totals = totals
            self.byModel = models
                .map { (model: $0.key, count: $0.value.count, prompt: $0.value.prompt, output: $0.value.output) }
                .sorted { $0.prompt + $0.output > $1.prompt + $1.output }
            self.render()
        }
    }

    private func render() {
        let used = usage?.tokens ?? 0
        let window = usage?.window ?? 0
        let ratio = (usage?.fraction).map { min(1, max(0, $0)) }

        contextValueLabel.text = ratio == nil && used == 0
            ? String(localized: "还没有用量")
            : String(localized: "\(Self.tokenText(used)) / \(window > 0 ? Self.tokenText(window) : "—")")
        contextPercentLabel.text = ratio.map { String(format: "%.1f%%", $0 * 100) }
            ?? String(localized: "窗口未知")

        let level: Level = switch ratio {
        case .none: .normal
        case let value?: value >= 0.9 ? .high : value >= 0.75 ? .elevated : .normal
        }
        fill.backgroundColor = level.color
        contextPercentLabel.textColor = ratio == nil ? .secondaryLabel : level.color
        contextValueLabel.accessibilityValue = ratio.map {
            String(localized: "已使用 \(Self.tokenText(used))，窗口 \(Self.tokenText(window))，占 \($0 * 100, format: .number.precision(.fractionLength(0)))%")
        } ?? String(localized: "窗口未知")

        for row in statsStack.arrangedSubviews { row.removeFromSuperview() }
        if totals.count == 0 {
            let empty = UILabel()
            empty.text = String(localized: "本会话还没有请求记录。")
            empty.font = .preferredFont(forTextStyle: .caption1)
            empty.textColor = .secondaryLabel
            empty.adjustsFontForContentSizeCategory = true
            statsStack.addArrangedSubview(empty)
        } else {
            let prompt = totals.input + totals.cacheRead + totals.cacheWrite
            let hitRate = prompt > 0 ? Double(totals.cacheRead) / Double(prompt) : 0
            statsStack.addArrangedSubview(statRow(
                title: String(localized: "请求次数"),
                value: String(totals.count),
            ))
            statsStack.addArrangedSubview(statRow(
                title: String(localized: "输入（含缓存）"),
                value: Self.tokenText(prompt),
            ))
            statsStack.addArrangedSubview(statRow(
                title: String(localized: "输出"),
                value: Self.tokenText(totals.output),
            ))
            statsStack.addArrangedSubview(statRow(
                title: String(localized: "缓存读取"),
                value: Self.tokenText(totals.cacheRead),
            ))
            statsStack.addArrangedSubview(statRow(
                title: String(localized: "缓存写入"),
                value: Self.tokenText(totals.cacheWrite),
            ))
            statsStack.addArrangedSubview(statRow(
                title: String(localized: "缓存命中率"),
                value: String(format: "%.1f%%", hitRate * 100),
            ))
        }
        for row in modelsStack.arrangedSubviews { row.removeFromSuperview() }
        if byModel.isEmpty {
            let empty = UILabel()
            empty.text = String(localized: "本会话还没有请求记录。")
            empty.font = .preferredFont(forTextStyle: .caption1)
            empty.textColor = .secondaryLabel
            empty.adjustsFontForContentSizeCategory = true
            modelsStack.addArrangedSubview(empty)
        } else {
            for entry in byModel {
                modelsStack.addArrangedSubview(statRow(
                    title: "\(entry.model) ｜ \(entry.count) 次",
                    value: String(localized: "输入 \(Self.tokenText(entry.prompt)) ｜ 输出 \(Self.tokenText(entry.output))"),
                ))
            }
        }
        renderOverview()
        renderRanking()
        view.setNeedsLayout()
    }

    /// 「总览」：全部记录的请求次数、输入（含缓存）、输出与最大会话。
    private func renderOverview() {
        for row in overviewStack.arrangedSubviews { row.removeFromSuperview() }
        if allRecords.isEmpty {
            overviewStack.addArrangedSubview(emptyNote(String(localized: "还没有任何请求记录。")))
            return
        }
        var allPrompt = 0
        var allOutput = 0
        var bySession: [String: Int] = [:]
        for record in allRecords {
            allPrompt += record.promptTokens
            allOutput += record.output
            bySession[record.sessionID, default: 0] += record.promptTokens + record.output
        }
        let sessions = Set(allRecords.map(\.sessionID)).count
        let maxSession = bySession.values.max() ?? 0
        overviewStack.addArrangedSubview(statRow(title: String(localized: "会话数"), value: String(sessions)))
        overviewStack.addArrangedSubview(statRow(title: String(localized: "请求次数"), value: String(allRecords.count)))
        overviewStack.addArrangedSubview(statRow(title: String(localized: "输入（含缓存）"), value: Self.tokenText(allPrompt)))
        overviewStack.addArrangedSubview(statRow(title: String(localized: "输出"), value: Self.tokenText(allOutput)))
        overviewStack.addArrangedSubview(statRow(title: String(localized: "最大会话"), value: Self.tokenText(maxSession)))
    }

    /// 「最大会话 TOP8」：按请求量最大的会话排，行名是会话 id 的前 8 位
    /// （记录里没有标题可读）。
    private func renderRanking() {
        for row in rankingStack.arrangedSubviews { row.removeFromSuperview() }
        if allRecords.isEmpty {
            rankingStack.addArrangedSubview(emptyNote(String(localized: "还没有任何请求记录。")))
            return
        }
        var bySession: [String: (count: Int, tokens: Int)] = [:]
        for record in allRecords {
            let entry = bySession[record.sessionID, default: (0, 0)]
            bySession[record.sessionID] = (entry.count + 1, entry.tokens + record.promptTokens + record.output)
        }
        let top = bySession
            .map { (id: $0.key, count: $0.value.count, tokens: $0.value.tokens) }
            .sorted { $0.tokens > $1.tokens }
            .prefix(8)
        for (index, entry) in top.enumerated() {
            let name = String(entry.id.prefix(8))
            let row = UIStackView(arrangedSubviews: [
                UILabel().then {
                    $0.text = "\(index + 1)"
                    $0.font = .preferredFont(forTextStyle: .caption1)
                    $0.textColor = .secondaryLabel
                    $0.adjustsFontForContentSizeCategory = true
                    $0.setContentHuggingPriority(.required, for: .horizontal)
                },
                UILabel().then {
                    $0.text = name
                    $0.font = .preferredFont(forTextStyle: .caption1)
                    $0.textColor = .label
                    $0.adjustsFontForContentSizeCategory = true
                    $0.lineBreakMode = .byTruncatingMiddle
                },
                UILabel().then {
                    $0.text = "\(Self.tokenText(entry.tokens)) · \(entry.count) 次"
                    $0.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                    $0.textColor = .secondaryLabel
                    $0.adjustsFontForContentSizeCategory = false
                    $0.setContentHuggingPriority(.required, for: .horizontal)
                },
            ])
            row.axis = .horizontal
            row.spacing = 8
            row.alignment = .firstBaseline
            rankingStack.addArrangedSubview(row)
        }
    }

    private func emptyNote(_ text: String) -> UILabel {
        UILabel().then {
            $0.text = text
            $0.font = .preferredFont(forTextStyle: .caption1)
            $0.textColor = .secondaryLabel
            $0.adjustsFontForContentSizeCategory = true
            $0.numberOfLines = 0
        }
    }

    private func statRow(title: String, value: String) -> UIView {
        let row = UIStackView(arrangedSubviews: [
            UILabel().then {
                $0.text = title
                $0.font = .preferredFont(forTextStyle: .callout)
                $0.textColor = .secondaryLabel
                $0.adjustsFontForContentSizeCategory = true
            },
            UILabel().then {
                $0.text = value
                $0.font = Self.weighted(.preferredFont(forTextStyle: .callout), .semibold)
                $0.textColor = .label
                $0.adjustsFontForContentSizeCategory = true
                $0.setContentHuggingPriority(.required, for: .horizontal)
            },
        ])
        row.axis = .horizontal
        row.spacing = 8
        return row
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = contextCard.bounds.width
        fill.frame = CGRect(x: 0, y: 0, width: width * ((usage?.fraction).map { min(1, max(0, $0)) } ?? 0), height: 8)
    }

    private static func tokenText(_ tokens: Int) -> String {
        switch tokens {
        case 1_000_000_000...:
            String(format: "%.1fB", Double(tokens) / 1_000_000_000)
        case 1_000_000...:
            String(format: "%.1fM", Double(tokens) / 1_000_000)
        case 1_000...:
            String(format: "%.1fk", Double(tokens) / 1_000)
        default:
            String(tokens)
        }
    }

    private static func weighted(_ base: UIFont, _ weight: UIFont.Weight) -> UIFont {
        let descriptor = base.fontDescriptor.addingAttributes([
            .traits: [UIFontDescriptor.TraitKey.weight: weight],
        ])
        return UIFont(descriptor: descriptor, size: 0)
    }
}

extension UIViewController {
    /// 便捷：在 nav 栈里推出会话用量详情。
    func presentChatUsageDetail(sessionID: String, usage: ChatContextUsage?) {
        let detail = ChatUsageDetailController(sessionID: sessionID, usage: usage)
        if let navigation = navigationController {
            navigation.pushViewController(detail, animated: true)
        } else {
            let wrapped = UINavigationController(rootViewController: detail)
            wrapped.modalPresentationStyle = .formSheet
            present(wrapped, animated: true)
        }
    }
}
