import SwiftUI
import UIKit

/// Hands the bundled, preconfigured file to an installed document handler.
/// Opening the menu does not confirm that Shortcuts imported or ran the file.
@MainActor
final class ActionButtonShortcutInstaller: NSObject, ObservableObject {
  @Published private(set) var errorMessage: String?
  weak var anchor: UIView?
  private var document: UIDocumentInteractionController?

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
        errorMessage = "Install Apple's Shortcuts app, then try Add Shortcut again."
      }
    } catch {
      errorMessage = "The shortcut file could not be prepared. Try again."
    }
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
