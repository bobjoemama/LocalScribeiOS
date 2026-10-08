import SwiftUI
import UIKit

/// Hands the bundled, Apple-signed shortcut to an installed document handler.
/// Choosing a handler does not confirm that the user added the shortcut.
struct ActionButtonShortcutInstallButton: UIViewRepresentable {
    let onError: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onError: onError) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle("Add Action Button Shortcut", for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .body)
        button.titleLabel?.adjustsFontForContentSizeCategory = true
        button.titleLabel?.numberOfLines = 0
        button.contentHorizontalAlignment = .leading
        button.tintColor = UIColor(AppTheme.accent)
        button.addAction(UIAction { [weak coordinator = context.coordinator, weak button] _ in
            guard let button else { return }
            coordinator?.present(from: button)
        }, for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.onError = onError
    }

    static func dismantleUIView(_ button: UIButton, coordinator: Coordinator) {
        coordinator.document?.dismissMenu(animated: false)
    }

    @MainActor
    final class Coordinator: NSObject, UIDocumentInteractionControllerDelegate {
        var onError: (String) -> Void
        // UIKit does not retain this controller for the entire interaction.
        var document: UIDocumentInteractionController?

        init(onError: @escaping (String) -> Void) { self.onError = onError }

        func present(from button: UIButton) {
            guard button.window != nil else { return }
            guard let url = Bundle.main.url(forResource: "LocalScribeActionButton", withExtension: "shortcut") else {
                onError("The Action Button shortcut file is missing. Reinstall LocalScribe, then try again.")
                return
            }
            document?.dismissMenu(animated: false)
            let document = UIDocumentInteractionController(url: url)
            document.name = "LocalScribe Action Button"
            document.delegate = self
            self.document = document
            if !document.presentOpenInMenu(from: button.bounds, in: button, animated: true) {
                onError("No app can open the shortcut file. Install Apple's Shortcuts app, then try again.")
            }
        }
    }
}
