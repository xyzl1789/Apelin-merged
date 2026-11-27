import ApelinCore
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
    @objc private dynamic var savedText = ""

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
        savedText = Preferences.PromptInjection.projectText(project)
        textView.text = savedText
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

        var previewConfiguration = UIButton.Configuration.plain()
        previewConfiguration.title = String(localized: "查看项目说明文件（只读）")
        previewConfiguration.image = UIImage(systemName: "doc.text.magnifyingglass")
        previewConfiguration.imagePadding = 6
        let previewButton = UIButton(configuration: previewConfiguration, primaryAction: UIAction { [weak self] _ in
            self?.previewFile()
        })
        previewButton.accessibilityIdentifier = "project-instructions-file-preview"
        previewButton.accessibilityHint = String(localized: "查看代理实际读取的 AGENTS.md 或 CLAUDE.md，不会修改文件。")
        previewButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true

        let stack = UIStackView(arrangedSubviews: [hint, textView, previewButton, clearButton])
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

    @objc private dynamic func save() {
        do {
            try Preferences.PromptInjection.setProjectText(textView.text, for: project, replacing: savedText)
            savedText = Preferences.PromptInjection.projectText(project)
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
            return
        }
        SPIndicator.present(title: String(localized: "Saved"), preset: .done, haptic: .success)
        if let navigation = navigationController {
            navigation.popViewController(animated: true)
        } else {
            dismiss(animated: true)
        }
    }

    @objc private dynamic func previewFile() {
        view.endEditing(true)
        do {
            let root = try ProjectActions.directory(named: project)
            Task { [weak self] in
                let reading = await Task.detached {
                    ProjectInstructionsFile.read(projectRoot: root)
                }.value
                guard let self else { return }
                guard let reading else {
                    presentNotice(
                        title: "未找到项目说明",
                        message: "项目内没有可读取的 AGENTS.md 或 CLAUDE.md，空文件和指向项目外的链接不会载入。",
                    )
                    return
                }
                let controller = ChatCompactionController(
                    summary: reading.text,
                    title: String(localized: "\(reading.file)（只读）"),
                )
                navigationController?.pushViewController(controller, animated: true)
            }
        } catch {
            presentNotice(title: "Error", message: error.readableMessage)
        }
    }

    /// Clearing wipes the project's own text only; the instructions for every
    /// chat stay as they are.
    @objc private dynamic func confirmClear() {
        let alert = UIAlertController(
            title: String(localized: "Clear this project's instructions?"),
            message: String(localized: "The instructions shared by every chat stay as they are."),
            preferredStyle: .alert,
        )
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "Clear"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            do {
                try Preferences.PromptInjection.setProjectText("", for: project, replacing: savedText)
                savedText = ""
                textView.text = ""
            } catch {
                presentNotice(title: "Error", message: error.readableMessage)
            }
        })
        present(alert, animated: true)
    }
}
