import LocalScribeCore
import SwiftUI
import UIKit

struct DictionaryView: View {
    @ObservedObject var controller: AppController
    var openSavedData: (() -> Void)? = nil
    @State private var search = ""
    @State private var editor: PersonalizationEditorRequest?
    @State private var deleting: DictionaryRule?
    @State private var errorMessage: String?

    private var rules: [DictionaryRule] {
        controller.dictionary.filter {
            search.isEmpty || $0.heard.localizedCaseInsensitiveContains(search) || $0.replacement.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            if !controller.canEditDictionary {
                Section {
                    Text("Your saved dictionary could not be opened.")
                    if let openSavedData { Button("Manage saved data", action: openSavedData) }
                }
            }
            Section {
                ForEach(rules) { rule in
                    Button {
                        if controller.canEditDictionary { editor = .correction(rule) }
                    } label: {
                        PersonalizationRow(title: rule.heard, output: rule.replacement, isEnabled: rule.isEnabled)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(controller.canEditDictionary ? "Edit correction" : "Editing is unavailable")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { deleting = rule }
                            .disabled(!controller.canEditDictionary)
                        Button("Edit") { editor = .correction(rule) }
                            .disabled(!controller.canEditDictionary)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editor = .correction(rule) }
                            .disabled(!controller.canEditDictionary)
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = rule }
                            .disabled(!controller.canEditDictionary)
                    }
                }
            } footer: {
                Text("Replaces whole spoken phrases, without regard to capitalization.")
            }
        }
        .overlay {
            if rules.isEmpty && controller.canEditDictionary {
                ContentUnavailableView(search.isEmpty ? "No corrections" : "No results", systemImage: search.isEmpty ? "text.book.closed" : "magnifyingglass", description: Text(search.isEmpty ? "Add how a word or phrase should be written." : "Try another word or phrase."))
            }
        }
        .navigationTitle("Dictionary")
        .searchable(text: $search, prompt: "Search corrections")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add correction", systemImage: "plus") { editor = .correction(nil) }
                    .labelStyle(.iconOnly)
                    .disabled(!controller.canEditDictionary)
            }
        }
        .sheet(item: $editor) { request in
            PersonalizationEditor(controller: controller, request: request) { search = "" }
        }
        .confirmationDialog("Delete correction?", isPresented: deletionPresented, titleVisibility: .visible) {
            if let rule = deleting {
                Button("Delete", role: .destructive) {
                    do { try controller.deleteDictionaryRule(id: rule.id) }
                    catch { errorMessage = error.localizedDescription }
                    deleting = nil
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "“\($0.heard)” will no longer be replaced." } ?? "")
        }
        .alert("Could not delete correction", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

struct SnippetsView: View {
    @ObservedObject var controller: AppController
    var openSavedData: (() -> Void)? = nil
    @State private var search = ""
    @State private var editor: PersonalizationEditorRequest?
    @State private var deleting: SpokenSnippet?
    @State private var errorMessage: String?

    private var snippets: [SpokenSnippet] {
        controller.snippets.filter {
            search.isEmpty || $0.trigger.localizedCaseInsensitiveContains(search) || $0.expansion.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List {
            if !controller.canEditSnippets {
                Section {
                    Text("Your saved snippets could not be opened.")
                    if let openSavedData { Button("Manage saved data", action: openSavedData) }
                }
            }
            Section {
                ForEach(snippets) { snippet in
                    Button {
                        if controller.canEditSnippets { editor = .snippet(snippet) }
                    } label: {
                        PersonalizationRow(title: snippet.trigger, output: snippet.expansion, isEnabled: snippet.isEnabled)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(controller.canEditSnippets ? "Edit snippet" : "Editing is unavailable")
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", role: .destructive) { deleting = snippet }
                            .disabled(!controller.canEditSnippets)
                        Button("Edit") { editor = .snippet(snippet) }
                            .disabled(!controller.canEditSnippets)
                    }
                    .contextMenu {
                        Button("Edit", systemImage: "pencil") { editor = .snippet(snippet) }
                            .disabled(!controller.canEditSnippets)
                        Button("Copy text", systemImage: "doc.on.doc") { UIPasteboard.general.string = snippet.expansion }
                        ShareLink(item: snippet.expansion) { Label("Share", systemImage: "square.and.arrow.up") }
                        Button("Delete", systemImage: "trash", role: .destructive) { deleting = snippet }
                            .disabled(!controller.canEditSnippets)
                    }
                }
            } footer: {
                Text("Expands a whole spoken phrase into saved text, without regard to capitalization. Line breaks are preserved.")
            }
        }
        .overlay {
            if snippets.isEmpty && controller.canEditSnippets {
                ContentUnavailableView(search.isEmpty ? "No snippets" : "No results", systemImage: search.isEmpty ? "text.alignleft" : "magnifyingglass", description: Text(search.isEmpty ? "Save text to insert with a spoken phrase." : "Try another word or phrase."))
            }
        }
        .navigationTitle("Snippets")
        .searchable(text: $search, prompt: "Search snippets")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add snippet", systemImage: "plus") { editor = .snippet(nil) }
                    .labelStyle(.iconOnly)
                    .disabled(!controller.canEditSnippets)
            }
        }
        .sheet(item: $editor) { request in
            PersonalizationEditor(controller: controller, request: request) { search = "" }
        }
        .confirmationDialog("Delete snippet?", isPresented: deletionPresented, titleVisibility: .visible) {
            if let snippet = deleting {
                Button("Delete", role: .destructive) {
                    do { try controller.deleteSnippet(id: snippet.id) }
                    catch { errorMessage = error.localizedDescription }
                    deleting = nil
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: {
            Text(deleting.map { "“\($0.trigger)” will no longer expand into saved text." } ?? "")
        }
        .alert("Could not delete snippet", isPresented: errorPresented) {
            Button("OK") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var deletionPresented: Binding<Bool> {
        Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
    }
    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
}

private struct PersonalizationRow: View {
    let title: String
    let output: String
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).foregroundStyle(isEnabled ? .primary : .secondary)
            Text(output).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            if !isEnabled { Text("Disabled").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 4)
    }
}

private struct PersonalizationEditorRequest: Identifiable {
    enum Entry { case correction(DictionaryRule?), snippet(SpokenSnippet?) }
    let id = UUID()
    let entry: Entry
    static func correction(_ rule: DictionaryRule?) -> Self { Self(entry: .correction(rule)) }
    static func snippet(_ snippet: SpokenSnippet?) -> Self { Self(entry: .snippet(snippet)) }
}

private struct PersonalizationEditor: View {
    @ObservedObject var controller: AppController
    let request: PersonalizationEditorRequest
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var trigger: String
    @State private var output: String
    @State private var enabled: Bool
    @State private var errorMessage: String?
    @State private var confirmingDiscard = false
    @FocusState private var focus: Field?
    private enum Field { case trigger, output }

    init(controller: AppController, request: PersonalizationEditorRequest, onSaved: @escaping () -> Void) {
        self.controller = controller
        self.request = request
        self.onSaved = onSaved
        switch request.entry {
        case .correction(let rule):
            _trigger = State(initialValue: rule?.heard ?? "")
            _output = State(initialValue: rule?.replacement ?? "")
            _enabled = State(initialValue: rule?.isEnabled ?? true)
        case .snippet(let snippet):
            _trigger = State(initialValue: snippet?.trigger ?? "")
            _output = State(initialValue: snippet?.expansion ?? "")
            _enabled = State(initialValue: snippet?.isEnabled ?? true)
        }
    }

    private var isSnippet: Bool { if case .snippet = request.entry { true } else { false } }
    private var isNew: Bool {
        switch request.entry {
        case .correction(let rule): rule == nil
        case .snippet(let snippet): snippet == nil
        }
    }
    private var hasChanges: Bool {
        switch request.entry {
        case .correction(let rule):
            trigger != (rule?.heard ?? "") || output != (rule?.replacement ?? "") || enabled != (rule?.isEnabled ?? true)
        case .snippet(let snippet):
            trigger != (snippet?.trigger ?? "") || output != (snippet?.expansion ?? "") || enabled != (snippet?.isEnabled ?? true)
        }
    }
    private var canEdit: Bool { isSnippet ? controller.canEditSnippets : controller.canEditDictionary }
    private var validDraft: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(isSnippet ? "Spoken phrase" : "Say").font(.subheadline).foregroundStyle(.secondary)
                        TextField("Word or phrase", text: $trigger, axis: .vertical)
                            .lineLimit(1...3).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .trigger)
                            .accessibilityLabel(isSnippet ? "Spoken phrase" : "Say")
                    }
                    if isSnippet {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Text").font(.subheadline).foregroundStyle(.secondary)
                            TextEditor(text: $output).font(.body).frame(minHeight: 180)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .output).accessibilityLabel("Snippet text")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Replace with").font(.subheadline).foregroundStyle(.secondary)
                            TextField("Written form", text: $output, axis: .vertical)
                                .lineLimit(1...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .output).accessibilityLabel("Replace with")
                        }
                    }
                    Toggle("Enabled", isOn: $enabled)
                }
                .disabled(!canEdit)
                if !canEdit {
                    Section { Text("Editing is currently unavailable. Your draft is kept here.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle(isSnippet ? (isNew ? "New snippet" : "Edit snippet") : (isNew ? "New correction" : "Edit correction"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if hasChanges { confirmingDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canEdit || !validDraft)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .alert("Could not save", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("OK") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
    }

    private func save() {
        errorMessage = nil
        do {
            switch request.entry {
            case .correction(let rule):
                try controller.upsertDictionaryRule(id: rule?.id, heard: trigger, replacement: output, isEnabled: enabled)
            case .snippet(let snippet):
                try controller.upsertSnippet(id: snippet?.id, trigger: trigger, expansion: output, isEnabled: enabled)
            }
            onSaved()
            dismiss()
        } catch { errorMessage = error.localizedDescription }
    }
}
