import SwiftUI
import UIKit

/// Hands the bundled, preconfigured file to an installed document handler.
/// Opening the menu does not confirm that Shortcuts imported or ran the file.
@MainActor
final class ActionButtonShortcutInstaller: NSObject, ObservableObject {
  @Published private(set) var errorMessage: String?
  weak var anchor: UIView?
  private var document: UIDocumentInteractionController?
  private var shareSheet: UIActivityViewController?

  func present() {
    errorMessage = nil
    guard let anchor, anchor.window != nil else {
      errorMessage = "The shortcut could not be opened. Try again."
      return
    }
    guard
      let source = Bundle.main.url(
        forResource: "LocalScribe Action Button", withExtension: "shortcut",
        subdirectory: "shortcuts"
      )
    else {
      errorMessage = "The shortcut file is missing from this version of LocalScribe."
      return
    }
    do {
      let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "LocalScribeShortcutSetup", isDirectory: true
      )
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent(source.lastPathComponent)
      try Data(contentsOf: source).write(to: file, options: .atomic)
      document?.dismissMenu(animated: false)
      let document = UIDocumentInteractionController(url: file)
      document.uti = "com.apple.shortcut"
      document.name = "LocalScribe Action Button"
      self.document = document
      if !document.presentOpenInMenu(from: anchor.bounds, in: anchor, animated: true) {
        presentShareSheet(for: file, from: anchor)
      }
    } catch {
      errorMessage = "The shortcut file could not be prepared. Try again."
    }
  }

  private func presentShareSheet(for file: URL, from anchor: UIView) {
    var responder: UIResponder? = anchor
    var nearestController: UIViewController?
    while let current = responder {
      if let controller = current as? UIViewController {
        nearestController = controller
        break
      }
      responder = current.next
    }
    guard var presenter = nearestController ?? anchor.window?.rootViewController else {
      errorMessage = "The shortcut menu could not be opened. Try again."
      return
    }
    while let presented = presenter.presentedViewController, !presented.isBeingDismissed {
      presenter = presented
    }
    guard presenter.viewIfLoaded?.window === anchor.window,
      !presenter.isBeingDismissed, !presenter.isBeingPresented
    else {
      errorMessage = "The shortcut menu could not be opened. Try again."
      return
    }
    let shareSheet = UIActivityViewController(activityItems: [file], applicationActivities: nil)
    shareSheet.popoverPresentationController?.sourceView = anchor
    shareSheet.popoverPresentationController?.sourceRect = anchor.bounds
    self.shareSheet = shareSheet
    presenter.present(shareSheet, animated: true)
  }
}

struct ActionButtonShortcutAnchor: UIViewRepresentable {
  let installer: ActionButtonShortcutInstaller

  func makeUIView(context: Context) -> UIView {
    let view = UIView()
    view.isUserInteractionEnabled = false
    installer.anchor = view
    return view
  }

  func updateUIView(_ uiView: UIView, context: Context) {
    installer.anchor = uiView
  }
}
