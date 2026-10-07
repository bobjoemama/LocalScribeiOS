import SwiftUI
import UIKit
import Combine
import LocalScribeCore

/// Uses the Library's existing NavigationStack and its retained NotesController.
struct NotesView: View {
    @ObservedObject var controller: NotesController
    @ObservedObject var dictation: AppController
    @Environment(\.scenePhase) private var scenePhase
    @State private var search = ""
    @State private var newNoteID: UUID?
    @State private var showNewNote = false
    @State private var deletingID: UUID?

    init(controller: NotesController, dictation: AppController, initialNoteID: UUID? = nil) {
        _controller = ObservedObject(wrappedValue: controller)
        _dictation = ObservedObject(wrappedValue: dictation)
        _newNoteID = State(initialValue: initialNoteID)
        _showNewNote = State(initialValue: initialNoteID != nil)
    }

    private var matchingNotes: [NoteEntry] { controller.matching(search) }
    private var days: [Date] {
        Set(matchingNotes.map { Calendar.autoupdatingCurrent.startOfDay(for: $0.updatedAt) }).sorted(by: >)
    }

    var body: some View {
        List {
            if controller.errorMessage != nil { NotesSaveError(controller: controller, dictation: dictation) }
            if controller.isLoading {
                ProgressView("Opening notes…").listRowBackground(AppTheme.surface)
            } else if matchingNotes.isEmpty {
                ContentUnavailableView(search.isEmpty ? "No notes" : "No matching notes",
                    systemImage: search.isEmpty ? "note.text" : "magnifyingglass",
                    description: Text(search.isEmpty ? "Create a note, then type or dictate. Your notes stay on this iPhone." : "Try another word from a title or note.").foregroundStyle(AppTheme.inkSecondary))
                    .listRowBackground(Color.clear)
            } else {
                ForEach(days, id: \.self) { day in
                    Section {
                        ForEach(matchingNotes.filter { Calendar.autoupdatingCurrent.isDate($0.updatedAt, inSameDayAs: day) }) { note in
                            NavigationLink {
                                NoteEditor(controller: controller, dictation: dictation, noteID: note.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                                        Text(note.title).font(.body.weight(.semibold)).foregroundStyle(AppTheme.ink).lineLimit(2)
                                        Spacer(minLength: 0)
                                        Text(note.updatedAt, style: .time).font(.footnote).monospacedDigit()
                                            .foregroundStyle(AppTheme.inkSecondary)
                                    }
                                    if !note.preview.isEmpty {
                                        Text(note.preview).font(.subheadline).foregroundStyle(AppTheme.inkSecondary).lineLimit(2)
                                    }
                                }.padding(.vertical, 5)
                            }
                            .listRowBackground(AppTheme.surface)
                            .swipeActions(allowsFullSwipe: false) {
                                Button("Delete", role: .destructive) { deletingID = note.id }
                                ShareLink(item: note.text) { Label("Share", systemImage: "square.and.arrow.up") }.tint(AppTheme.accent)
                                Button { UIPasteboard.general.string = note.text } label: { Label("Copy", systemImage: "doc.on.doc") }.tint(AppTheme.inkSecondary)
                            }
                            .contextMenu {
                                Button { UIPasteboard.general.string = note.text } label: { Label("Copy", systemImage: "doc.on.doc") }
                                ShareLink(item: note.text) { Label("Share", systemImage: "square.and.arrow.up") }
                                Button("Delete", systemImage: "trash", role: .destructive) { deletingID = note.id }
                            }
                        }
                    } header: { Text(noteDayLabel(day)).foregroundStyle(AppTheme.inkSecondary) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scribeForm()
        .navigationTitle("Notes")
        .searchable(text: $search, prompt: "Search notes")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    newNoteID = controller.create()
                    search = ""
                    showNewNote = true
                } label: { Label("Create a note", systemImage: "square.and.pencil") }
                .disabled(controller.isLoading)
            }
        }
        .navigationDestination(isPresented: $showNewNote) {
            if let newNoteID { NoteEditor(controller: controller, dictation: dictation, noteID: newNoteID) }
        }
        .confirmationDialog("Delete this note?", isPresented: Binding(get: { deletingID != nil }, set: { if !$0 { deletingID = nil } }), titleVisibility: .visible) {
            Button("Delete note", role: .destructive) {
                if let deletingID { controller.delete(deletingID); Task { await controller.flush() } }
                deletingID = nil
            }
        } message: { Text("This cannot be undone.") }
        .onDisappear { Task { await controller.flush() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await controller.flush() } }
            if phase == .active, controller.hasUnsavedChanges { Task { await controller.retrySave() } }
        }
    }

    private func noteDayLabel(_ date: Date) -> String {
        let calendar = Calendar.autoupdatingCurrent
        if calendar.isDateInToday(date) { return "Today" }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(date: .complete, time: .omitted)
    }
}

private struct NotesSaveError: View {
    @ObservedObject var controller: NotesController
    @ObservedObject var dictation: AppController
    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                Label("Notes couldn’t be saved", systemImage: "exclamationmark.triangle").font(.body.weight(.semibold)).foregroundStyle(AppTheme.error)
                Text(controller.errorMessage ?? "").font(.subheadline).foregroundStyle(AppTheme.inkSecondary)
                Button("Retry saving") { Task { await controller.retrySave() } }.disabled(controller.isSaving || controller.isLoading)
                NavigationLink("Manage saved data") { SavedDataView(controller: dictation, notes: controller) }
            }.padding(.vertical, 6)
        }.listRowBackground(AppTheme.errorSoft)
    }
}

private struct NoteEditor: View {
    @ObservedObject var controller: NotesController
    @ObservedObject var dictation: AppController
    let noteID: UUID
    @StateObject private var recording: NoteDictationSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @FocusState private var editing: Bool
    @State private var confirmDelete = false

    init(controller: NotesController, dictation: AppController, noteID: UUID) {
        self.controller = controller
        self.dictation = dictation
        self.noteID = noteID
        _recording = StateObject(wrappedValue: NoteDictationSession(notes: controller, dictation: dictation, noteID: noteID))
    }
    private var note: NoteEntry? { controller.note(noteID) }
    private var text: Binding<String> {
        Binding(get: { controller.note(noteID)?.text ?? "" }, set: { controller.update(noteID, text: $0) })
    }
    private var canRecord: Bool {
        dictation.phase == .idle && !dictation.keyboardSessionActive && !dictation.actionButtonRecording
            && dictation.downloadingModel == nil && dictation.installedModels.contains(dictation.selectedModel) && !recording.isStarting
    }

    private var dictationStatus: String {
        if recording.isStarting { return "Starting dictation…" }
        if recording.ownsRecording {
            if let status = dictation.modelStatus { return status }
            return dictation.phase == .recording ? "Recording" : "Finishing dictation…"
        }
        return dictation.selectedModel.name
    }

    var body: some View {
        VStack(spacing: 0) {
            if controller.errorMessage != nil {
                VStack(alignment: .leading, spacing: 8) {
                    Text(controller.errorMessage ?? "").font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    NavigationLink("Manage saved data") { SavedDataView(controller: dictation, notes: controller) }
                    Button("Retry saving") { Task { await controller.retrySave() } }
                        .disabled(controller.isSaving || controller.isLoading)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(AppTheme.errorSoft)
                Divider().overlay(AppTheme.separator)
            }
            TextEditor(text: text).focused($editing)
                .font(.body).lineSpacing(4)
                .scrollContentBackground(.hidden).scrollDismissesKeyboard(.interactively)
                .foregroundStyle(AppTheme.ink)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .accessibilityLabel("Note text")
            if recording.ownsRecording, !dictation.partialText.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recording").font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    // TextEditor cannot display a non-editable attributed segment.
                    // Keep the current live tail separate until the owned result is final.
                    Text(DictationTranscriptTail.make(from: dictation.partialText)).font(.body).lineSpacing(4)
                        .foregroundStyle(AppTheme.ink)
                        .lineLimit(5).truncationMode(.head).textSelection(.enabled)
                        .accessibilityAddTraits(.updatesFrequently)
                }.frame(maxWidth: .infinity, alignment: .leading).padding()
                    .background(AppTheme.surfaceInset)
            }
        }
        .background(AppTheme.surface)
        .tint(AppTheme.accent)
        .navigationTitle(note?.title ?? "Note")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button { UIPasteboard.general.string = note?.text ?? "" } label: { Label("Copy", systemImage: "doc.on.doc") }
                    ShareLink(item: note?.text ?? "") { Label("Share", systemImage: "square.and.arrow.up") }
                    Button("Delete note", systemImage: "trash", role: .destructive) { confirmDelete = true }.disabled(recording.ownsRecording || recording.isStarting)
                } label: { Label("Note actions", systemImage: "ellipsis.circle") }
            }
            if editing {
                ToolbarItem(placement: .keyboard) { Button("Done") { editing = false; Task { await controller.flush() } } }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(dictationStatus).font(.subheadline)
                    Text(controller.errorMessage != nil ? "Save failed" : controller.isSaving ? "Saving…" : controller.hasUnsavedChanges ? "Unsaved changes" : controller.isSaved(noteID) ? "Saved" : "New note")
                        .font(.footnote).foregroundStyle(controller.errorMessage != nil ? AppTheme.error : AppTheme.inkSecondary)
                }
                Spacer(minLength: 4)
                if recording.ownsRecording || recording.isStarting {
                    if dictation.phase == .transcribing {
                        ProgressView().accessibilityLabel("Finishing dictation")
                    } else {
                        Button { Task { await recording.stop() } } label: { Label("Stop", systemImage: "stop.fill") }
                            .buttonStyle(.borderedProminent).controlSize(.large).tint(AppTheme.recording)
                            .foregroundStyle(AppTheme.onRecording)
                            .frame(minHeight: 44)
                    }
                } else {
                    Button { editing = false; Task { await recording.start() } } label: { Label("Dictate", systemImage: "mic.fill") }
                        .buttonStyle(.borderedProminent).controlSize(.large).foregroundStyle(AppTheme.onAccent).frame(minHeight: 44).disabled(!canRecord)
                }
            }.padding().background(.regularMaterial)
        }
        .confirmationDialog("Delete this note?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete note", role: .destructive) {
                controller.delete(noteID)
                Task { await controller.flush() }
                dismiss()
            }
        } message: { Text("This cannot be undone.") }
        .onAppear { recording.isVisible = true; if note?.text.isEmpty == true { editing = true } }
        .onDisappear { recording.finishWhenLeaving() }
        .onChange(of: dictation.phase) { _, phase in if phase == .idle { recording.receiveCompletion() } }
        .onChange(of: dictation.completedRecordingID) { _, _ in recording.receiveCompletion() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { Task { await controller.flush() } }
            if phase == .active, controller.hasUnsavedChanges { Task { await controller.retrySave() } }
        }
    }
}

/// Owns one recording UUID, including its completion after the editor closes.
/// Keyboard/Action Button completions cannot be inserted into an unrelated note.
@MainActor
private final class NoteDictationSession: ObservableObject {
    @Published private(set) var isStarting = false
    @Published private(set) var ownedID: UUID?
    var isVisible = true
    private let notes: NotesController
    private let dictation: AppController
    private let noteID: UUID
    private var leavingTask: Task<Void, Never>?
    private var completionObservation: AnyCancellable?
    private var cancelStartRequested = false
    var ownsRecording: Bool { ownedID != nil }

    init(notes: NotesController, dictation: AppController, noteID: UUID) {
        self.notes = notes; self.dictation = dictation; self.noteID = noteID
        // AppController publishes this synchronously on the main actor, before
        // returning to idle. Snapshot its result before any next session clears it.
        completionObservation = dictation.$completedRecordingID.sink { [weak self] completed in
            guard let self, let completed, self.ownedID == completed else { return }
            self.ownedID = nil
            self.notes.appendDictation(self.dictation.transcript, to: self.noteID)
            Task { await self.notes.flush() }
        }
    }
    func start() async {
        guard !isStarting, ownedID == nil, notes.note(noteID) != nil,
              dictation.phase == .idle, !dictation.keyboardSessionActive, !dictation.actionButtonRecording else { return }
        isStarting = true
        cancelStartRequested = false
        await dictation.startRecording()
        isStarting = false
        // Cancellation invalidates the pending startup before it owns a UUID.
        // Another owner can record while that old permission await finishes.
        // Never adopt the controller's current session after a canceled start.
        if !cancelStartRequested {
            ownedID = dictation.currentRecordingID
        }
        if !isVisible { finishWhenLeaving() }
    }
    func stop() async {
        if isStarting {
            cancelStartRequested = true
            if dictation.phase == .preparing, !dictation.keyboardSessionActive, !dictation.actionButtonRecording {
                await dictation.cancelPreparation()
            }
            return
        }
        guard let id = ownedID else { return }
        if dictation.currentRecordingID == id, dictation.phase == .recording {
            await dictation.stopRecording()
        }
        receiveCompletion()
        _ = await notes.flush()
    }
    func receiveCompletion() {
        guard let id = ownedID else { return }
        if dictation.currentRecordingID == id, dictation.phase != .idle { return }
        ownedID = nil
        guard dictation.completedRecordingID == id else { return }
        notes.appendDictation(dictation.transcript, to: noteID)
        Task { await notes.flush() }
    }
    func finishWhenLeaving() {
        isVisible = false
        guard !isStarting, leavingTask == nil else { return }
        leavingTask = Task {
            await stop()
            // An interruption or another Stop may already be processing this
            // owned session. Retain its destination until that session settles.
            while let id = ownedID, dictation.currentRecordingID == id, dictation.phase != .idle {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
            }
            receiveCompletion()
            notes.discardEmptyDraft(noteID)
            _ = await notes.flush()
            leavingTask = nil
        }
    }
}

#if DEBUG && targetEnvironment(simulator)
private extension NoteEditor {
    init(designPreviewController controller: NotesController, dictation: AppController,
        noteID: UUID, dialog: DesignPreviewConfiguration.Dialog?) {
        self.init(controller: controller, dictation: dictation, noteID: noteID)
        if dialog == .delete { _confirmDelete = State(initialValue: true) }
    }
}

@MainActor
func designPreviewNoteEditor(controller: NotesController, dictation: AppController,
    noteID: UUID, dialog: DesignPreviewConfiguration.Dialog?) -> some View {
    NoteEditor(designPreviewController: controller, dictation: dictation, noteID: noteID, dialog: dialog)
}
#endif
