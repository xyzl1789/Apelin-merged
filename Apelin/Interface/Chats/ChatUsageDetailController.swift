import ApelinCore
import SnapKit
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
            case .normal: .systemBlue
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
    /// 统计口径说明（TrollAgent 同款小字）。
    private let estimateNote = UILabel()
    private let overviewCard = UIView()
    private let overviewStack = UIStackView()
    private let rankingCard = UIView()
    private let rankingStack = UIStackView()
    private let providersCard = UIView()
    private let providersStack = UIStackView()
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
        buildProvidersCard()

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
        contextNoteLabel.text = String(localized: "压力分级：<60% 正常 · ≥60% 压缩输出 · ≥75% 激进摘要 · ≥90% 自动压缩")

        for subview in [contextTitleLabel, contextValueLabel, contextPercentLabel, track, contextNoteLabel] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            contextCard.addSubview(subview)
        }
        contextTitleLabel.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview().inset(16)
        }
        contextValueLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(contextTitleLabel.snp.bottom).offset(10)
        }
        contextPercentLabel.snp.makeConstraints { make in
            make.trailing.equalToSuperview().inset(16)
            make.centerY.equalTo(contextValueLabel)
            make.leading.greaterThanOrEqualTo(contextValueLabel.snp.trailing).offset(8)
        }
        track.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(contextValueLabel.snp.bottom).offset(10)
            make.height.equalTo(8)
        }
        fill.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalTo(track).multipliedBy(usage?.fraction ?? 0)
        }
        contextNoteLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(track.snp.bottom).offset(8)
            make.bottom.equalToSuperview().inset(14)
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

        for subview in [title, statsStack, estimateNote] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            statsCard.addSubview(subview)
        }
        title.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview().inset(16)
        }
        statsStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(title.snp.bottom).offset(10)
        }
        estimateNote.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(statsStack.snp.bottom).offset(8)
            make.bottom.equalToSuperview().inset(14)
        }
        stack.addArrangedSubview(statsCard)

        // TrollAgent 同款：标注口径说明，置于统计卡说明位。
        estimateNote.font = .preferredFont(forTextStyle: .caption2)
        estimateNote.textColor = .secondaryLabel
        estimateNote.numberOfLines = 0
        estimateNote.adjustsFontForContentSizeCategory = true
        estimateNote.text = String(localized: "用量为模型请求报告的真实计数，非估算值。")

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
        modelsTitle.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview().inset(16)
        }
        modelsStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(modelsTitle.snp.bottom).offset(10)
            make.bottom.equalToSuperview().inset(14)
        }
        stack.addArrangedSubview(modelsCard)
    }

    /// 「总览」卡（TrollAgent 同构）：会话数、消息数无法从这里拿到，
    /// 用请求次数、总输入（含缓存）、总输出与最大会话代替。统计的是
    /// 全部会话，标题照实写。
    private func buildOverviewCard() {
        overviewCard.backgroundColor = .secondarySystemGroupedBackground
        overviewCard.layer.cornerRadius = 14
        overviewCard.layer.cornerCurve = .continuous

        let title = UILabel()
        title.text = String(localized: "所有会话总览")
        title.font = Self.weighted(.preferredFont(forTextStyle: .subheadline), .semibold)
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true

        overviewStack.axis = .vertical
        overviewStack.spacing = 10

        for subview in [title, overviewStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            overviewCard.addSubview(subview)
        }
        title.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview().inset(16)
        }
        overviewStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(title.snp.bottom).offset(10)
            make.bottom.equalToSuperview().inset(14)
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
        title.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview().inset(16)
        }
        rankingStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(title.snp.bottom).offset(10)
            make.bottom.equalToSuperview().inset(14)
        }
        stack.addArrangedSubview(rankingCard)
    }

    /// 「按供应商」卡（TrollAgent 同构）：全部请求按供应商汇总，
    /// 按请求量排；旧记录没有供应商字段，归到「未知」。
    private func buildProvidersCard() {
        providersCard.backgroundColor = .secondarySystemGroupedBackground
        providersCard.layer.cornerRadius = 14
        providersCard.layer.cornerCurve = .continuous

        let title = UILabel()
        title.text = String(localized: "按供应商")
        title.font = Self.weighted(.preferredFont(forTextStyle: .subheadline), .semibold)
        title.textColor = .label
        title.adjustsFontForContentSizeCategory = true

        providersStack.axis = .vertical
        providersStack.spacing = 8

        for subview in [title, providersStack] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            providersCard.addSubview(subview)
        }
        title.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview().inset(16)
        }
        providersStack.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(title.snp.bottom).offset(10)
            make.bottom.equalToSuperview().inset(14)
        }
        stack.addArrangedSubview(providersCard)
    }

    private func loadRecords() {
        let url = UsageRecorder.file(in: DataFolder.app.root)
        let session = sessionID
        let loaded = Task.detached {
            let all = UsageRecorder.readAll(from: url)
            // 会话 id → 侧边栏标题，给「最大会话 TOP8」的行名用。
            var titles: [String: String] = [:]
            if let chats = try? await ChatStore(folder: .app).load() {
                for record in chats.records {
                    guard let id = record.sessionID, !id.isEmpty else { continue }
                    if titles[id] == nil { titles[id] = record.summary.displayTitle }
                }
            }
            return (all, titles)
        }
        Task { [weak self] in
            let (all, titles) = await loaded.value
            guard let self else { return }
            self.allRecords = all
            self.sessionTitles = titles
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
        let ratio: Double? = usage.map { min(1, max(0, $0.fraction)) }

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
        fill.snp.updateConstraints { make in
            make.width.equalTo(track).multipliedBy(ratio ?? 0)
        }
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
            let maxInput = byModel.map(\.prompt).max() ?? 0
            let maxOutput = byModel.map(\.output).max() ?? 0
            for entry in byModel {
                modelsStack.addArrangedSubview(modelRow(entry: entry, maxInput: maxInput, maxOutput: maxOutput))
            }
        }
        renderOverview()
        renderRanking()
        renderProviders()
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

    /// 「最大会话 TOP8」：按请求量最大的会话排，行名是侧边栏里的会话标题，
    /// 已删除或没标题的会话退回 id 前 8 位。
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
            let name = sessionTitles[entry.id] ?? String(entry.id.prefix(8))
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

    /// 按供应商汇总：全部记录（含旧记录归「未知」），按请求量排。
    private func renderProviders() {
        for row in providersStack.arrangedSubviews { row.removeFromSuperview() }
        if allRecords.isEmpty {
            providersStack.addArrangedSubview(emptyNote(String(localized: "还没有任何请求记录。")))
            return
        }
        var byProvider: [String: (count: Int, input: Int, output: Int)] = [:]
        for record in allRecords {
            let name = record.provider ?? String(localized: "未知供应商")
            let entry = byProvider[name, default: (0, 0, 0)]
            byProvider[name] = (
                entry.count + 1,
                entry.input + record.input + record.cacheRead + record.cacheWrite,
                entry.output + record.output,
            )
        }
        let entries: [(name: String, count: Int, input: Int, output: Int)] = byProvider
            .map { (name: $0.key, count: $0.value.count, input: $0.value.input, output: $0.value.output) }
            .sorted { ($0.input + $0.output) > ($1.input + $1.output) }
        for entry in entries {
            providersStack.addArrangedSubview(statRow(
                title: entry.name,
                value: "\(Self.tokenText(entry.input + entry.output)) · \(entry.count) 次",
            ))
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

    /// 按模型行：行名（过长换行，绝不截断）+ 次数 + 右侧总量，下面橙色
    /// 输入条与绿色输出条，长度按该模型在本向最大值里的占比——与设置里
    /// 「按供应商」同一种条。
    private func modelRow(entry: (model: String, count: Int, prompt: Int, output: Int),
                          maxInput: Int, maxOutput: Int) -> UIView {
        let top = statRow(title: entry.model, value: "\(Self.tokenText(entry.prompt + entry.output)) · \(entry.count) 次")
        let inputRow = barRow(
            fraction: CGFloat(entry.prompt) / CGFloat(max(maxInput, 1)),
            color: .systemOrange,
            text: String(localized: "输入 \(Self.tokenText(entry.prompt))"),
        )
        let outputRow = barRow(
            fraction: CGFloat(entry.output) / CGFloat(max(maxOutput, 1)),
            color: .systemGreen,
            text: String(localized: "输出 \(Self.tokenText(entry.output))"),
        )
        return UIStackView(arrangedSubviews: [top, inputRow, outputRow]).then {
            $0.axis = .vertical
            $0.spacing = 6
            $0.isAccessibilityElement = true
            $0.accessibilityLabel = entry.model
            $0.accessibilityValue = String(
                localized: "\(entry.count) 次请求，输入 \(Self.tokenText(entry.prompt))，输出 \(Self.tokenText(entry.output))"
            )
        }
    }

    /// 一条比例条 + 右端数字：条高 6pt，数字 caption2、颜色随条。
    private func barRow(fraction: CGFloat, color: UIColor, text: String) -> UIView {
        let label = UILabel().then {
            $0.text = text
            $0.font = .preferredFont(forTextStyle: .caption2)
            $0.textColor = color
            $0.adjustsFontForContentSizeCategory = true
            $0.setContentHuggingPriority(.required, for: .horizontal)
            $0.setContentCompressionResistancePriority(.required, for: .horizontal)
        }
        let fill = UIView().then { $0.backgroundColor = color }
        let track = UIView().then {
            $0.backgroundColor = .tertiarySystemFill
            $0.layer.cornerRadius = 3
            $0.clipsToBounds = true
        }
        track.addSubview(fill)
        fill.snp.makeConstraints {
            $0.leading.top.bottom.equalToSuperview()
            $0.width.equalTo(track.snp.width).multipliedBy(min(max(fraction, 0), 1))
        }
        let row = UIStackView(arrangedSubviews: [track, label]).then {
            $0.axis = .horizontal
            $0.spacing = 8
            $0.alignment = .center
        }
        track.snp.makeConstraints { $0.height.equalTo(6) }
        row.isAccessibilityElement = true
        row.accessibilityLabel = text
        return row
    }

    private func statRow(title: String, value: String) -> UIView {
        let row = UIStackView(arrangedSubviews: [
            UILabel().then {
                $0.text = title
                $0.font = .preferredFont(forTextStyle: .callout)
                $0.textColor = .secondaryLabel
                $0.adjustsFontForContentSizeCategory = true
                // 模型 id 常常很长：放不下就换行显示全名，不截断。
                $0.numberOfLines = 0
                $0.lineBreakMode = .byCharWrapping
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
        row.alignment = .firstBaseline
        return row
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
