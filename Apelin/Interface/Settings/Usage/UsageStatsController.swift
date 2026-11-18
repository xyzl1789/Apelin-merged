import ApelinCore
import SnapKit
import Then
import UIKit

/// 设置 ▸ Agent ▸ 用量统计：照抄 TrollAgent 的用量统计版式——
/// 彩色数字的「总览」卡、按供应商、按模型与最近请求明细。
/// 数据来自 AgentSession 写下的 `<数据根>/usage/usage.jsonl`。
final class UsageStatsController: UIViewController {
    /// 总览格：大数字配小字，每个数字一种颜色（TrollAgent 同款）。
    private struct Tile {
        let caption: String
        let color: UIColor
        var value: String
    }

    private var records: [UsageRecord] = []
    private var tiles: [Tile] = []
    /// 按供应商汇总（旧记录归「未知」），按请求量排。
    private var byProvider: [(name: String, count: Int, input: Int, output: Int)] = []
    /// 按模型汇总，按请求量排。
    private var byModel: [(model: String, count: Int, input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = []

    private let scrollView = UIScrollView()
    private let stack = UIStackView()
    private var overviewTilesStack = UIStackView()
    private var providersStack = UIStackView()
    private var modelsStack = UIStackView()
    private var recentStack = UIStackView()
    private let emptyCard = UIView()
    private let emptyLabel = UILabel()

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init()")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "用量统计")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.backButtonDisplayMode = .minimal
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "清空记录"),
            primaryAction: UIAction { [weak self] _ in self?.confirmClear() },
        ).then {
            $0.accessibilityLabel = String(localized: "清空记录")
        }

        scrollView.alwaysBounceVertical = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        stack.axis = .vertical
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        scrollView.addSubview(stack)

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
        reload()
    }

    // MARK: - 卡片搭建

    /// 一张分组卡：标题 + 内容栈。
    private func makeCard(title: String, content: UIStackView) -> UIView {
        let card = UIView().then {
            $0.backgroundColor = .secondarySystemGroupedBackground
            $0.layer.cornerRadius = 14
            $0.layer.cornerCurve = .continuous
        }
        let titleLabel = UILabel().then {
            $0.text = title
            $0.font = Self.weighted(.preferredFont(forTextStyle: .subheadline), .semibold)
            $0.textColor = .label
            $0.adjustsFontForContentSizeCategory = true
        }
        content.axis = .vertical
        for subview in [titleLabel, content] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(subview)
        }
        titleLabel.snp.makeConstraints { make in
            make.leading.top.trailing.equalToSuperview().inset(16)
        }
        content.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.equalTo(titleLabel.snp.bottom).offset(10)
            make.bottom.equalToSuperview().inset(14)
        }
        return card
    }

    private func buildCards() {
        // 总览：彩色数字格。
        overviewTilesStack.spacing = 10
        stack.addArrangedSubview(makeCard(title: String(localized: "总览"), content: overviewTilesStack))
        // 按供应商。
        providersStack.spacing = 10
        stack.addArrangedSubview(makeCard(title: String(localized: "按供应商"), content: providersStack))
        // 按模型。
        modelsStack.spacing = 10
        stack.addArrangedSubview(makeCard(title: String(localized: "按模型"), content: modelsStack))
        // 最近请求。
        recentStack.spacing = 10
        stack.addArrangedSubview(makeCard(title: String(localized: "最近请求"), content: recentStack))

        // 空记录卡：全部清空后总览之上只给一句提示。
        emptyCard.backgroundColor = .secondarySystemGroupedBackground
        emptyCard.layer.cornerRadius = 14
        emptyCard.layer.cornerCurve = .continuous
        emptyLabel.font = .preferredFont(forTextStyle: .callout)
        emptyLabel.textColor = .secondaryLabel
        emptyLabel.numberOfLines = 0
        emptyLabel.adjustsFontForContentSizeCategory = true
        emptyLabel.text = String(localized: "还没有任何请求记录。")
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyCard.addSubview(emptyLabel)
        emptyLabel.snp.makeConstraints { make in
            make.leading.trailing.equalToSuperview().inset(16)
            make.top.bottom.equalToSuperview().inset(16)
        }
    }

    // MARK: - 数据与渲染

    private func reload() {
        let url = UsageRecorder.file(in: DataFolder.app.root)
        let loaded = Task.detached { UsageRecorder.readAll(from: url) }
        Task { [weak self] in
            let loaded = await loaded.value
            guard let self else { return }
            self.records = loaded
            self.rebuildSummary()
            self.render()
        }
    }

    private func rebuildSummary() {
        var providers: [String: (count: Int, input: Int, output: Int)] = [:]
        var models: [String: (count: Int, input: Int, output: Int, cacheRead: Int, cacheWrite: Int)] = [:]
        var sessionCount = 0
        var maxSession = 0
        var bySessionTokens: [String: Int] = [:]
        var allInput = 0
        var allOutput = 0
        var allCacheRead = 0
        for record in records {
            let provider = record.provider ?? String(localized: "未知供应商")
            let p = providers[provider, default: (0, 0, 0)]
            providers[provider] = (p.count + 1, p.input + record.promptTokens, p.output + record.output)
            let m = models[record.model, default: (0, 0, 0, 0, 0)]
            models[record.model] = (
                m.count + 1,
                m.input + record.promptTokens,
                m.output + record.output,
                m.cacheRead + record.cacheRead,
                m.cacheWrite + record.cacheWrite,
            )
            bySessionTokens[record.sessionID, default: 0] += record.promptTokens + record.output
            allInput += record.input
            allOutput += record.output
            allCacheRead += record.cacheRead
        }
        sessionCount = bySessionTokens.count
        maxSession = bySessionTokens.values.max() ?? 0
        let allPrompt = allInput + allCacheRead
        let hitRate = allPrompt > 0 ? Double(allCacheRead) / Double(allPrompt) : 0

        tiles = [
            Tile(caption: String(localized: "会话数"), color: .systemBlue, value: String(sessionCount)),
            Tile(caption: String(localized: "请求次数"), color: .systemPurple, value: String(records.count)),
            Tile(caption: String(localized: "最大会话"), color: .systemOrange, value: Self.tokenText(maxSession)),
            Tile(caption: String(localized: "输入（含缓存）"), color: .systemRed, value: Self.tokenText(allInput + allCacheRead)),
            Tile(caption: String(localized: "输出"), color: .systemGreen, value: Self.tokenText(allOutput)),
            Tile(caption: String(localized: "缓存命中率"), color: .systemTeal, value: String(format: "%.1f%%", hitRate * 100)),
        ]
        byProvider = providers
            .map { (name: $0.key, count: $0.value.count, input: $0.value.input, output: $0.value.output) }
            .sorted { ($0.input + $0.output) > ($1.input + $1.output) }
        byModel = models
            .map { (model: $0.key, count: $0.value.count, input: $0.value.input, output: $0.value.output, cacheRead: $0.value.cacheRead, cacheWrite: $0.value.cacheWrite) }
            .sorted { ($0.input + $0.output) > ($1.input + $1.output) }
    }

    private func render() {
        if stack.arrangedSubviews.isEmpty { buildCards() }
        emptyCard.removeFromSuperview()
        if records.isEmpty {
            stack.insertArrangedSubview(emptyCard, at: 0)
        }

        // 总览格：每行 3 格。
        for row in overviewTilesStack.arrangedSubviews { row.removeFromSuperview() }
        for chunk in stride(from: 0, to: tiles.count, by: 3) {
            let row = UIStackView(arrangedSubviews: Array(tiles[chunk..<min(chunk + 3, tiles.count)].map(makeTile)))
            row.axis = .horizontal
            row.spacing = 10
            row.distribution = .fillEqually
            overviewTilesStack.addArrangedSubview(row)
        }

        // 按供应商。
        for row in providersStack.arrangedSubviews { row.removeFromSuperview() }
        if byProvider.isEmpty {
            providersStack.addArrangedSubview(emptyNote(String(localized: "还没有任何请求记录。")))
        } else {
            let maxTokens = byProvider.map { $0.input + $0.output }.max() ?? 0
            for entry in byProvider {
                providersStack.addArrangedSubview(providerRow(entry: entry, maxTokens: maxTokens))
            }
        }

        // 按模型。
        for row in modelsStack.arrangedSubviews { row.removeFromSuperview() }
        if byModel.isEmpty {
            modelsStack.addArrangedSubview(emptyNote(String(localized: "还没有任何请求记录。")))
        } else {
            for entry in byModel {
                modelsStack.addArrangedSubview(statRow(
                    title: entry.model,
                    subtitle: String(localized: "\(entry.count) 次请求"),
                    value: Self.tokenText(entry.input + entry.output),
                ))
            }
        }

        // 最近请求：新到旧，最多 50 条。
        for row in recentStack.arrangedSubviews { row.removeFromSuperview() }
        let recent = records.sorted { $0.time > $1.time }.prefix(50)
        if recent.isEmpty {
            recentStack.addArrangedSubview(emptyNote(String(localized: "还没有任何请求记录。")))
        } else {
            for record in recent {
                let time = record.time.formatted(date: .abbreviated, time: .shortened)
                recentStack.addArrangedSubview(statRow(
                    title: record.model,
                    subtitle: "\(time) ｜ \(String(localized: "输入 \(Self.tokenText(record.promptTokens))")) ｜ \(String(localized: "输出 \(Self.tokenText(record.output))"))",
                    value: "",
                ))
            }
        }
        view.setNeedsLayout()
    }

    private func makeTile(_ tile: Tile) -> UIView {
        let value = UILabel().then {
            $0.text = tile.value
            $0.font = Self.weighted(.preferredFont(forTextStyle: .title2), .bold)
            $0.textColor = tile.color
            $0.adjustsFontForContentSizeCategory = true
            $0.adjustsFontSizeToFitWidth = true
            $0.minimumScaleFactor = 0.6
        }
        let caption = UILabel().then {
            $0.text = tile.caption
            $0.font = .preferredFont(forTextStyle: .caption1)
            $0.textColor = .secondaryLabel
            $0.adjustsFontForContentSizeCategory = true
        }
        let column = UIStackView(arrangedSubviews: [value, caption])
        column.axis = .vertical
        column.spacing = 2
        column.isAccessibilityElement = true
        column.accessibilityLabel = tile.caption
        column.accessibilityValue = tile.value
        return column
    }

    /// 明细行：行名 + 小字说明，右侧大数字（TrollAgent 同款结构）。
    private func statRow(title: String, subtitle: String, value: String) -> UIView {
        let nameLabel = UILabel().then {
            $0.text = title
            $0.font = .preferredFont(forTextStyle: .callout)
            $0.textColor = .label
            $0.adjustsFontForContentSizeCategory = true
            $0.lineBreakMode = .byTruncatingMiddle
        }
        let subtitleLabel = UILabel().then {
            $0.text = subtitle
            $0.font = .preferredFont(forTextStyle: .caption1)
            $0.textColor = .secondaryLabel
            $0.adjustsFontForContentSizeCategory = true
        }
        let column = UIStackView(arrangedSubviews: [nameLabel, subtitleLabel])
        column.axis = .vertical
        column.spacing = 2
        let row = UIStackView(arrangedSubviews: [column])
        if !value.isEmpty {
            let valueLabel = UILabel().then {
                $0.text = value
                $0.font = Self.weighted(.monospacedDigitSystemFont(ofSize: 17, weight: .semibold), .semibold)
                $0.textColor = .tintColor
                $0.setContentHuggingPriority(.required, for: .horizontal)
                $0.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            row.addArrangedSubview(valueLabel)
        }
        row.axis = .horizontal
        row.spacing = 8
        row.alignment = .firstBaseline
        row.isAccessibilityElement = true
        row.accessibilityLabel = title
        row.accessibilityValue = value.isEmpty ? subtitle : "\(subtitle)，\(value)"
        return row
    }

    /// 按供应商行：行名 + 次数，右侧总量，下面一条「输入/输出」双段比例
    /// 条——橙色段是输入（含缓存）、绿色段是输出，长度按各家总量在全表
    /// 最大值里的占比，两端各标一笔数字。
    private func providerRow(entry: (name: String, count: Int, input: Int, output: Int), maxTokens: Int) -> UIView {
        let top = statRow(
            title: entry.name,
            subtitle: String(localized: "\(entry.count) 次请求"),
            value: Self.tokenText(entry.input + entry.output),
        )
        let total = max(entry.input + entry.output, 1)
        let inputFraction = CGFloat(entry.input) / CGFloat(total)

        let track = UIView().then {
            $0.backgroundColor = .tertiarySystemFill
            $0.layer.cornerRadius = 3
            $0.clipsToBounds = true
        }
        let inputBar = UIView().then { $0.backgroundColor = .systemOrange }
        let outputBar = UIView().then { $0.backgroundColor = .systemGreen }
        for bar in [inputBar, outputBar] {
            bar.translatesAutoresizingMaskIntoConstraints = false
            track.addSubview(bar)
        }
        inputBar.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.width.equalToSuperview().multipliedBy(inputFraction)
        }
        outputBar.snp.makeConstraints { make in
            make.leading.equalTo(inputBar.snp.trailing)
            make.top.bottom.trailing.equalToSuperview()
        }
        track.accessibilityElementsHidden = true

        let inputLabel = UILabel().then {
            $0.text = String(localized: "输入 \(Self.tokenText(entry.input))")
            $0.font = .preferredFont(forTextStyle: .caption2)
            $0.textColor = .systemOrange
            $0.adjustsFontForContentSizeCategory = true
        }
        let outputLabel = UILabel().then {
            $0.text = String(localized: "输出 \(Self.tokenText(entry.output))")
            $0.font = .preferredFont(forTextStyle: .caption2)
            $0.textColor = .systemGreen
            $0.adjustsFontForContentSizeCategory = true
        }
        let legend = UIStackView(arrangedSubviews: [inputLabel, outputLabel]).then {
            $0.axis = .horizontal
            $0.spacing = 8
            $0.alignment = .firstBaseline
        }

        // 比例条：长度按本家总量在全表最大值里的占比，外层撑满、条按比例缩短。
        let holder = UIView()
        holder.addSubview(track)
        track.snp.makeConstraints { make in
            make.leading.top.bottom.equalToSuperview()
            make.height.equalTo(6)
        }
        if maxTokens > 0 {
            track.snp.makeConstraints { make in
                make.width.equalTo(holder.snp.width)
                    .multipliedBy(CGFloat(entry.input + entry.output) / CGFloat(maxTokens))
            }
        }

        let column = UIStackView(arrangedSubviews: [top, holder, legend]).then {
            $0.axis = .vertical
            $0.spacing = 6
            $0.isAccessibilityElement = true
            $0.accessibilityLabel = entry.name
            $0.accessibilityValue = String(
                localized: "\(entry.count) 次请求，输入 \(Self.tokenText(entry.input))，输出 \(Self.tokenText(entry.output))"
            )
        }
        return column
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

    // MARK: - 清空

    private func confirmClear() {
        let alert = UIAlertController(
            title: String(localized: "清空用量记录？"),
            message: String(localized: "全部 token 用量统计将被删除，无法恢复。"),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "取消"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "清空"), style: .destructive) { [weak self] _ in
            UsageRecorder.clear(UsageRecorder.file(in: DataFolder.app.root))
            self?.reload()
        })
        present(alert, animated: true)
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
