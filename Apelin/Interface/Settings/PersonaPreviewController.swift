import ApelinCore
import Then
import UIKit

/// Dylix-style preview of the system prompt the current configuration would
/// produce. The note says plainly that the preview uses the app-wide model
/// default: a conversation that overrides its model re-matches at send time.
final class PersonaPreviewController: UIViewController {
    private let snapshot: PersonaSnapshot
    private var text = ""

    init(snapshot: PersonaSnapshot) {
        self.snapshot = snapshot
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { fatalError("Use init(snapshot:)") }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Preview Injection")
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Copy All"),
            primaryAction: UIAction { [weak self] _ in
                UIPasteboard.general.string = self?.text
            },
        ).then { $0.accessibilityLabel = String(localized: "Copy All") }

        let currentModel = Preferences.DefaultModels.selection(for: .derivedConversation)?.model
        let resolved = PersonaResolver.resolve(snapshot, model: currentModel)
        let body = PersonaResolver.text(snapshot, model: currentModel)
        text = body
        let summary = label(
            String(localized: "\(currentModel ?? String(localized: "No model selected")) · \(resolved?.name ?? String(localized: "No matching configuration"))\n生效 1 项 · 人设正文 \(body.utf8.count) B"),
            style: .headline,
        )
        summary.accessibilityIdentifier = "persona-preview-summary"
        let note = label(
            String(localized: "按全局默认模型预览；项目单独选择模型时会在实际发送时重新匹配。修改从下一条消息起生效。"),
            style: .footnote,
            color: .secondaryLabel,
        )
        let viewer = UITextView()
        viewer.text = body
        viewer.isEditable = false
        viewer.isSelectable = true
        viewer.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        viewer.textColor = .label
        viewer.backgroundColor = .secondarySystemGroupedBackground
        viewer.layer.cornerRadius = 12
        viewer.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        viewer.accessibilityIdentifier = "persona-preview-system"
        viewer.translatesAutoresizingMaskIntoConstraints = false

        let stack = UIStackView(arrangedSubviews: [summary, note, viewer])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
    }

    private func label(_ text: String, style: UIFont.TextStyle, color: UIColor = .label) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = .preferredFont(forTextStyle: style)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        return label
    }
}
