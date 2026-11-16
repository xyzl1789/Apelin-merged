import ApelinProtocol
import UIKit

/// The automatic assistant as the conversation's own menu entry, in the
/// conversation's More (…) menu: the two switches, the measurement that picks
/// the fastest model, and the exclusions both honour.
///
/// The state is read when the menu opens, never captured when it is built: a
/// switch toggled here must not keep showing its old value, and the chat it
/// belongs to may not even have existed when the button was made.
enum AutoAssistantMenu {
    /// The submenu for one conversation: its own settings, with what it
    /// inherits from the conversation that opened it said under the switch.
    @MainActor
    static func menu(for id: UUID, in controller: UIViewController) -> UIMenu {
        let settings = AutoAssistantPolicy.current(for: id)

        let switching = UIAction(
            title: String(localized: "Switch Model on Failure"),
            image: UIImage(systemName: "arrow.triangle.swap"),
            state: settings.switchOnFailure ? .on : .off,
        ) { _ in
            var next = AutoAssistantPolicy.current(for: id)
            next.switchOnFailure.toggle()
            AutoAssistantPolicy.set(next, for: id)
        }
        let retrying = UIAction(
            title: String(localized: "Retry on Timeout"),
            image: UIImage(systemName: "clock.arrow.circlepath"),
            state: settings.retryOnTimeout ? .on : .off,
        ) { _ in
            var next = AutoAssistantPolicy.current(for: id)
            next.retryOnTimeout.toggle()
            AutoAssistantPolicy.set(next, for: id)
        }
        // 设置读出来就是这条对话实际生效的（含从开启它的对话继承来的），
        // 所以开关的选中态如实反映它，不需要另加说明文字。
        let title = String(localized: "Auto Assistant")

        let measure = UIAction(
            title: String(localized: "Measure Now and Use Fastest"),
            image: UIImage(systemName: "speedometer"),
        ) { [weak controller] _ in
            guard let controller else { return }
            measureAndUseFastest(for: id, from: controller)
        }
        let providers = UIAction(
            title: String(localized: "Excluded Providers"),
            image: UIImage(systemName: "person.crop.circle.badge.xmark"),
        ) { [weak controller] _ in
            controller?.navigationController?.pushViewController(
                ExcludedProvidersController(style: .insetGrouped), animated: true,
            )
        }
        let excluded = UIAction(
            title: String(localized: "Excluded Models"),
            image: UIImage(systemName: "minus.circle"),
        ) { [weak controller] _ in
            controller?.navigationController?.pushViewController(
                ExcludedModelsController(style: .insetGrouped), animated: true,
            )
        }

        return UIMenu(
            title: title,
            image: UIImage(systemName: "wand.and.stars"),
            children: [
                UIMenu(options: .displayInline, children: [switching, retrying]),
                UIMenu(options: .displayInline, children: [measure]),
                UIMenu(options: .displayInline, children: [providers, excluded]),
            ],
        )
    }

    /// Measures every enabled, non-excluded model and leaves this conversation
    /// on the fastest one: the conversation it was asked from, not the app's
    /// default, which the reader may never open next.
    private static func measureAndUseFastest(for id: UUID, from controller: UIViewController) {
        Task { @MainActor in
            do {
                let selected = try await ProgressCard.run(
                    title: String(localized: "Measuring Models"),
                    message: String(localized: "Testing each signed-in model…"),
                    cancellable: true,
                    from: controller,
                ) { update in
                    try await ModelSpeedPicker.pickFastest(progress: { measured, total in
                        update(ProgressCard.Status(
                            subtitle: String(localized: "Testing each signed-in model…"),
                            fraction: Double(measured) / Double(max(total, 1)),
                            count: "\(measured) / \(total)",
                        ))
                    })
                }
                guard !Task.isCancelled else { return }
                guard let selected else {
                    controller.presentNotice(
                        title: "No Model Available",
                        message: "None of the signed-in models answered, or all were excluded.",
                    )
                    return
                }
                ComposerModelSelection.choose(selected, for: id)
                ComposerModelSelection.rememberSelection(selected)
                controller.presentNotice(
                    title: "Fastest Model Selected",
                    message: String(
                        format: String(localized: "Now using %@ from %@."),
                        selected.model,
                        selected.provider.displayName,
                    ),
                )
            } catch is CancellationError {
                // The reader cancelled: nothing to say.
            } catch {
                controller.presentNotice(title: "Unable to Measure Models", message: error.readableMessage)
            }
        }
    }
}
