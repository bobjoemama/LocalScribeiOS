import SwiftUI
import UIKit
import LocalScribeCore
import AppIntents

enum LibraryDestination: Hashable { case dictionary, snippets, notes }

struct LibraryView: View {
    @ObservedObject var controller: AppController
    @ObservedObject var notes: NotesController
    @Binding var path: [LibraryDestination]
    let openSavedData: () -> Void
    var body: some View {
        NavigationStack(path: $path) {
            List {
                NavigationLink(value: LibraryDestination.dictionary) { libraryRow("Dictionary", symbol: "textformat.abc", count: controller.dictionary.count) }.listRowBackground(AppTheme.surface)
                NavigationLink(value: LibraryDestination.snippets) { libraryRow("Snippets", symbol: "text.badge.plus", count: controller.snippets.count) }.listRowBackground(AppTheme.surface)
                NavigationLink(value: LibraryDestination.notes) { libraryRow("Notes", symbol: "note.text", count: notes.notes.count) }.listRowBackground(AppTheme.surface)
            }
            .listStyle(.insetGrouped)
            .scribeForm()
            .navigationTitle("Library")
            .navigationDestination(for: LibraryDestination.self) { destination in
                switch destination {
                case .dictionary: DictionaryView(controller: controller, openSavedData: openSavedData)
                case .snippets: SnippetsView(controller: controller, openSavedData: openSavedData)
                case .notes: NotesView(controller: notes, dictation: controller)
                }
            }
        }
    }

    private func libraryRow(_ title: String, symbol: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: symbol).foregroundStyle(AppTheme.ink)
            Spacer()
            Text(count.formatted()).monospacedDigit().foregroundStyle(AppTheme.inkSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}
