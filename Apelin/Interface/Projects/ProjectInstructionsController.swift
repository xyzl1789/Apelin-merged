import SPIndicator
import UIKit

/// A project's own instructions: the words this project's conversations carry
/// after the ones every chat gets (Settings ▸ Agent ▸ Prompt Injection). Kept
/// in the device's defaults under the project's folder name, which never
/// changes, and dropped with the project itself.
@MainActor
final class ProjectInstructionsController: UIViewController {
    private let project: String
    private let textView = UITextView()

    /// `project` is the project's folder name, the stable identity it is
    /// stored under.
    init(project: String) {
        self.project = project
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("Use init(project:)")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Project Instructions")
        view.backgroundColor = .systemGroupedBackground
        textView.font = .preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.backgroundColor = .secondarySystemGroupedBackground
        textView.layer.cornerRadius = 12
        textView.layer.cornerCurve = .continuous
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.text = Preferences.PromptInjection.projectText(project)
        textView.accessibilityLabel = String(localized: "Project Instructions")

        let hint = UILabel()
        hint.font = .preferredFont(forTextStyle: .footnote)
        hint.textColor = .secondaryLabel
        hint.numberOfLines = 0
        hint.text = String(
            localized: "These instructions go with every message in this project's conversations, after the ones shared by every chat.",
        )

        var configuration = UIButton.Configuration.plain()
        configuration.title = String(localized: "Clear Instructions")
        configuration.baseForegroundColor = .systemRed
        let clearButton = UIButton(configuration: configuration, primaryAction: UIAction { [weak self] _ in
            self?.confirmClear()
        })

        let stack = UIStackView(arrangedSubviews: [hint, textView, clearButton])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        textView.setContentHuggingPriority(.defaultLow, for: .vertical)

        let save = UIBarButtonItem(
            title: String(localized: "Save"),
            primaryAction: UIAction { [weak self] _ in self?.save() },
        )
        save.style = .done
        navigationItem.rightBarButtonItem = save

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            stack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -16),
        ])
    }

    private func save() {
        Preferences.PromptInjection.setProjectText(textView.text, for: project)
        SPIndicator.present(title: String(localized: "Saved"), preset: .done, haptic: .success)
        if let navigation = navigationController {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    /// Clearing wipes the project's own text only; the instructions for every
    /// chat stay as they are.
    private func confirmClear() {
        let alert = UIAlertController(
            title: String(localized: "Clear this project's instructions?"),
            message: String(localized: "The instructions shared by every chat stay as they are."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Clear"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Preferences.PromptInjection.setProjectText("", for: project)
            textView.text = ""
        })
        present(alert, animated: true)
    }
}
