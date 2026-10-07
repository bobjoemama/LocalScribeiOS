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
                    Text(personalizationUnavailableMessage(controller)).foregroundStyle(AppTheme.error)
                    if let openSavedData { Button("Manage saved data", action: openSavedData) }
                }.listRowBackground(AppTheme.errorSoft)
            }
            Section {
                ForEach(rules) { rule in
                    Button {
                        if controller.canEditDictionary { editor = .correction(rule) }
                    } label: {
                        PersonalizationRow(title: rule.heard, output: rule.replacement, isEnabled: rule.isEnabled)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppTheme.surface)
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
                Text("Replaces a whole spoken phrase, ignoring capitalization. This changes recognized text; it does not retrain the model.").foregroundStyle(AppTheme.inkSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scribeForm()
        .overlay {
            if rules.isEmpty && controller.canEditDictionary {
                ContentUnavailableView(search.isEmpty ? "No corrections" : "No results", systemImage: search.isEmpty ? "text.book.closed" : "magnifyingglass", description: Text(search.isEmpty ? "Add how a word or phrase should be written." : "Try another word or phrase.").foregroundStyle(AppTheme.inkSecondary))
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
                    Text(personalizationUnavailableMessage(controller)).foregroundStyle(AppTheme.error)
                    if let openSavedData { Button("Manage saved data", action: openSavedData) }
                }.listRowBackground(AppTheme.errorSoft)
            }
            Section {
                ForEach(snippets) { snippet in
                    Button {
                        if controller.canEditSnippets { editor = .snippet(snippet) }
                    } label: {
                        PersonalizationRow(title: snippet.trigger, output: snippet.expansion, isEnabled: snippet.isEnabled)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(AppTheme.surface)
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
                Text("Expands a whole spoken phrase into saved text, without regard to capitalization. Line breaks are preserved.").foregroundStyle(AppTheme.inkSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scribeForm()
        .overlay {
            if snippets.isEmpty && controller.canEditSnippets {
                ContentUnavailableView(search.isEmpty ? "No snippets" : "No results", systemImage: search.isEmpty ? "text.alignleft" : "magnifyingglass", description: Text(search.isEmpty ? "Save text to insert with a spoken phrase." : "Try another word or phrase.").foregroundStyle(AppTheme.inkSecondary))
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
            Text(title).font(.body).foregroundStyle(isEnabled ? AppTheme.ink : AppTheme.inkSecondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "arrow.right").font(.caption)
                Text(output).font(.subheadline).lineLimit(2)
            }.foregroundStyle(AppTheme.inkSecondary)
            if !isEnabled { Text("Off").font(.footnote).foregroundStyle(AppTheme.inkSecondary) }
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
                        Text("Say").font(.subheadline).foregroundStyle(AppTheme.inkSecondary)
                        TextField("Word or phrase", text: $trigger, axis: .vertical)
                            .lineLimit(1...3).textInputAutocapitalization(.never).autocorrectionDisabled()
                            .focused($focus, equals: .trigger)
                            .accessibilityLabel("Say")
                    }
                    if isSnippet {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Insert").font(.subheadline).foregroundStyle(AppTheme.inkSecondary)
                            TextEditor(text: $output).font(.body).lineSpacing(4).frame(minHeight: 180)
                                .scrollContentBackground(.hidden).background(AppTheme.surface)
                                .foregroundStyle(AppTheme.ink)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .output).accessibilityLabel("Insert")
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Replace with").font(.subheadline).foregroundStyle(AppTheme.inkSecondary)
                            TextField("Written form", text: $output, axis: .vertical)
                                .lineLimit(1...5).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .focused($focus, equals: .output).accessibilityLabel("Replace with")
                        }
                    }
                    Toggle("Enabled", isOn: $enabled).tint(.green)
                } footer: {
                    Text(isSnippet
                         ? "Inserts saved text for a whole spoken phrase, ignoring capitalization. Line breaks are preserved."
                         : "Replaces a whole spoken phrase, ignoring capitalization. This changes recognized text; it does not retrain the model.").foregroundStyle(AppTheme.inkSecondary)
                }
                .listRowBackground(AppTheme.surface)
                .disabled(!canEdit)
                if !canEdit {
                    Section { Text("Editing is currently unavailable. Your draft is kept here.").foregroundStyle(AppTheme.error) }.listRowBackground(AppTheme.errorSoft)
                }
            }
            .scribeForm()
            .navigationTitle(isSnippet ? (isNew ? "New snippet" : "Edit snippet") : (isNew ? "New correction" : "Edit correction"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if hasChanges { confirmingDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(!canEdit || !validDraft || !hasChanges)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { focus = nil }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .onChange(of: canEdit) { _, allowed in if !allowed { focus = nil } }
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
        guard canEdit, validDraft, hasChanges else { return }
        focus = nil
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

@MainActor
private func personalizationUnavailableMessage(_ controller: AppController) -> String {
    let dictionaryUnavailable = controller.unreadableSavedData.contains(.dictionary)
    let snippetsUnavailable = controller.unreadableSavedData.contains(.snippets)
    let name = dictionaryUnavailable && snippetsUnavailable ? "Dictionary and snippets"
        : dictionaryUnavailable ? "Dictionary" : "Snippets"
    return "\(name) could not be opened. Dictionary and snippets are edited together; existing saved data is preserved."
}

#if DEBUG && targetEnvironment(simulator)
private extension PersonalizationEditor {
    init(designPreviewController controller: AppController, request: PersonalizationEditorRequest,
         dialog: DesignPreviewConfiguration.Dialog?) {
        self.init(controller: controller, request: request, onSaved: {})
        if dialog == .discard {
            _output = State(initialValue: "Revised synthetic draft")
            _confirmingDiscard = State(initialValue: true)
        } else if dialog == .saveError {
            _output = State(initialValue: "Revised synthetic draft")
            _errorMessage = State(initialValue: "Design preview: could not save. Your draft remains here; try again.")
        }
    }
}

@MainActor
func designPreviewPersonalizationEditor(controller: AppController, rule: DictionaryRule?,
    dialog: DesignPreviewConfiguration.Dialog?) -> some View {
    PersonalizationEditor(designPreviewController: controller, request: .correction(rule), dialog: dialog)
}

@MainActor
func designPreviewSnippetEditor(controller: AppController, snippet: SpokenSnippet?,
    dialog: DesignPreviewConfiguration.Dialog?) -> some View {
    PersonalizationEditor(designPreviewController: controller, request: .snippet(snippet), dialog: dialog)
}
#endif
