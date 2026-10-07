import SwiftUI
import UIKit
import LocalScribeCore

struct NativeHistoryView: View {
    @ObservedObject var controller: AppController
    var openSavedData: (() -> Void)? = nil
    @State private var search = ""
    @State private var selectedEntry: TranscriptEntry?
    @State private var deletingEntry: TranscriptEntry?
    @State private var confirmingClear = false
    @State private var operationError: String?

    private var visible: [TranscriptEntry] {
        controller.history.filter {
            search.isEmpty || $0.text.localizedCaseInsensitiveContains(search)
                || $0.model.name.localizedCaseInsensitiveContains(search)
        }.sorted { $0.createdAt > $1.createdAt }
    }
    private var days: [HistoryDay] {
        let calendar = Calendar.autoupdatingCurrent
        let grouped = Dictionary(grouping: visible) { calendar.startOfDay(for: $0.createdAt) }
        return grouped.keys.sorted(by: >).map { HistoryDay(date: $0, entries: grouped[$0] ?? []) }
    }

    var body: some View {
        NavigationStack {
            List {
                if controller.unreadableSavedData.contains(.history) {
                    Section {
                        Text("Your saved history could not be opened.").foregroundStyle(AppTheme.error)
                        if let openSavedData { Button("Manage saved data", action: openSavedData) }
                    }.listRowBackground(AppTheme.errorSoft)
                }
                ForEach(days) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            historyRow(entry).listRowBackground(AppTheme.surface)
                        }
                    } header: {
                        Text(dayLabel(day.date)).foregroundStyle(AppTheme.inkSecondary)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scribeForm()
            .overlay {
                if controller.history.isEmpty && !controller.unreadableSavedData.contains(.history) {
                    ContentUnavailableView("No transcripts yet", systemImage: "clock", description: Text("Finished dictations are saved here while history is on.").foregroundStyle(AppTheme.inkSecondary))
                } else if visible.isEmpty && !controller.unreadableSavedData.contains(.history) {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search transcripts")
            .navigationTitle("History")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        NavigationLink("Usage", destination: HistoryUsageView(controller: controller))
                        ShareLink(item: exportText(visible)) {
                            Label(search.isEmpty ? "Export history" : "Export search results", systemImage: "square.and.arrow.up")
                        }.disabled(visible.isEmpty)
                        Button("Clear all history", systemImage: "trash", role: .destructive) {
                            confirmingClear = true
                        }.disabled(controller.history.isEmpty || !controller.canEditHistory)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }.accessibilityLabel("History actions")
                }
            }
            .sheet(item: $selectedEntry) { entry in
                HistoryTranscriptEditor(entry: entry, canSave: controller.canEditHistory) { text in
                    try controller.replaceHistory(id: entry.id, text: text)
                    // Reveal the saved edit even if it no longer matches this search.
                    search = ""
                }
            }
            .alert("Delete transcript?", isPresented: Binding(
                get: { deletingEntry != nil },
                set: { if !$0 { deletingEntry = nil } }
            )) {
                Button("Cancel", role: .cancel) { deletingEntry = nil }
                Button("Delete", role: .destructive) {
                    guard let entry = deletingEntry else { return }
                    deletingEntry = nil
                    perform { try controller.deleteHistory(ids: [entry.id]) }
                }.disabled(!controller.canEditHistory)
            } message: {
                Text("This saved transcript will be permanently deleted.")
            }
            .alert("Clear all history?", isPresented: $confirmingClear) {
                Button("Cancel", role: .cancel) {}
                Button("Delete all", role: .destructive) { perform { try controller.clearHistory() } }
                    .disabled(!controller.canEditHistory)
            } message: {
                Text("Delete all \(controller.history.count) saved transcripts? This cannot be undone. Search does not limit this action.")
            }
            .alert("History could not be changed", isPresented: Binding(
                get: { operationError != nil },
                set: { if !$0 { operationError = nil } }
            )) {
                Button("OK") { operationError = nil }
            } message: { Text(operationError ?? "") }
        }
    }

    private func historyRow(_ entry: TranscriptEntry) -> some View {
        Button { selectedEntry = entry } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.text).foregroundStyle(AppTheme.ink).lineLimit(3).multilineTextAlignment(.leading)
                Text("\(entry.createdAt.formatted(date: .omitted, time: .shortened)) · \(entry.model.name) · \(historyDuration(entry.duration))")
                    .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.padding(.vertical, 4).frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens the saved transcript")
        .contextMenu {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.text }
            ShareLink(item: entry.text) { Label("Share", systemImage: "square.and.arrow.up") }
            Button("Edit", systemImage: "pencil") { selectedEntry = entry }.disabled(!controller.canEditHistory)
            Button("Delete", systemImage: "trash", role: .destructive) { deletingEntry = entry }
                .disabled(!controller.canEditHistory)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("Delete", systemImage: "trash", role: .destructive) { deletingEntry = entry }
                .disabled(!controller.canEditHistory)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = entry.text }.tint(AppTheme.accent)
        }
    }

    private func perform(_ change: () throws -> Void) {
        do { try change() }
        catch { operationError = error.localizedDescription }
    }
    private func dayLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .complete, time: .omitted)
    }
    private func exportText(_ entries: [TranscriptEntry]) -> String {
        entries.map {
            "\($0.createdAt.ISO8601Format()) · \($0.model.name) · \(historyDuration($0.duration))\n\($0.text)"
        }.joined(separator: "\n\n—\n\n")
    }
    private struct HistoryDay: Identifiable {
        let date: Date
        let entries: [TranscriptEntry]
        var id: Date { date }
    }
}

private struct HistoryTranscriptEditor: View {
    let entry: TranscriptEntry
    let canSave: Bool
    let save: (String) throws -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var draft: String
    @State private var failure: String?
    @State private var confirmingDiscard = false
    @FocusState private var editing: Bool

    init(entry: TranscriptEntry, canSave: Bool, save: @escaping (String) throws -> Void) {
        self.entry = entry; self.canSave = canSave; self.save = save
        _draft = State(initialValue: entry.text)
    }
    private var changed: Bool { draft != entry.text }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextEditor(text: $draft).focused($editing).disabled(!canSave)
                    .font(.body).lineSpacing(4)
                    .scrollContentBackground(.hidden)
                    .scrollDismissesKeyboard(.interactively)
                    .foregroundStyle(AppTheme.ink)
                    .background(AppTheme.surface)
                    .padding(12).accessibilityLabel("Saved transcript")
                Text("\(entry.model.name) · \(entry.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 12)
                if !canSave {
                    Text("History editing is unavailable right now.")
                        .font(.footnote).foregroundStyle(AppTheme.inkSecondary).padding()
                }
            }
            .background(AppTheme.surface)
            .tint(AppTheme.accent)
            .navigationTitle("Transcript").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if changed { confirmingDiscard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        failure = nil
                        do { try save(draft); dismiss() }
                        catch { failure = error.localizedDescription }
                    }.disabled(!canSave || !changed)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { editing = false }
                }
                ToolbarItemGroup(placement: .bottomBar) {
                    Button("Copy", systemImage: "doc.on.doc") { UIPasteboard.general.string = draft }
                    Spacer()
                    ShareLink(item: draft) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            }
            .interactiveDismissDisabled(changed)
            .confirmationDialog("Discard unsaved changes?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
                Button("Keep editing", role: .cancel) {}
            }
            .alert("Could not save transcript", isPresented: Binding(
                get: { failure != nil },
                set: { if !$0 { failure = nil } }
            )) {
                Button("OK") { failure = nil }
            } message: { Text(failure ?? "") }
        }
    }
}

/// These totals describe currently retained history, not lifetime usage.
struct HistoryUsageView: View {
    @ObservedObject var controller: AppController
    private var words: Int { controller.history.reduce(0) { $0 + $1.text.split(whereSeparator: \.isWhitespace).count } }
    private var duration: TimeInterval {
        controller.history.reduce(0) { $0 + ($1.duration.isFinite ? max(0, $1.duration) : 0) }
    }
    var body: some View {
        List {
            LabeledContent("Saved transcripts") {
                Text(controller.history.count.formatted()).foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            LabeledContent("Words in saved text") {
                Text(words.formatted()).foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            LabeledContent("Recorded duration") {
                Text(historyDuration(duration)).foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            Text("Totals reflect saved history, including edits. Deleted transcripts and dictations made with history off are not counted.")
                .font(.footnote).foregroundStyle(AppTheme.inkSecondary).listRowBackground(AppTheme.surface)
        }
        .listStyle(.insetGrouped)
        .scribeForm()
        .monospacedDigit()
        .navigationTitle("Usage")
    }
}

private func historyDuration(_ seconds: TimeInterval) -> String {
    let safe = seconds.isFinite ? max(0, seconds) : 0
    let formatter = DateComponentsFormatter()
    formatter.allowedUnits = safe >= 3_600 ? [.hour, .minute, .second] : [.minute, .second]
    formatter.unitsStyle = .abbreviated
    formatter.zeroFormattingBehavior = .dropLeading
    return formatter.string(from: safe) ?? "0s"
}

#if DEBUG && targetEnvironment(simulator)
private extension HistoryTranscriptEditor {
    init(designPreviewEntry entry: TranscriptEntry, dialog: DesignPreviewConfiguration.Dialog?) {
        self.init(entry: entry, canSave: true, save: { _ in })
        if dialog == .discard {
            _draft = State(initialValue: entry.text + " Include the dates.")
            _confirmingDiscard = State(initialValue: true)
        } else if dialog == .saveError {
            _draft = State(initialValue: entry.text + " Include the dates.")
            _failure = State(initialValue: "Design preview: could not save this transcript. Your edits remain here.")
        }
    }
}

@MainActor
func designPreviewHistoryEditor(entry: TranscriptEntry, dialog: DesignPreviewConfiguration.Dialog?) -> some View {
    HistoryTranscriptEditor(designPreviewEntry: entry, dialog: dialog)
}
#endif
