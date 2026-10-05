import UIKit
import UniformTypeIdentifiers

/// A lightweight text keyboard. Microphone and model inference stay in the containing app.
final class KeyboardViewController: UIInputViewController {
    private enum SecondaryAction { case cancel, copy }
    private var secondaryAction: SecondaryAction?
    private let secondaryActionButton = UIButton(type: .system)
    private enum Layout { case letters, numbers, symbols }
    private var layout: Layout = .letters
    private var shifted = true
    private var capsLocked = false
    private var lastShiftTap = Date.distantPast
    private var pollTimer: Timer?
    private var deleteTimer: Timer?
    private var store: SharedKeyboardStore?
    private var status: KeyboardSessionStatus?
    private var autoInsertionTarget = KeyboardAutoInsertionTarget()
    private var pendingCommand: KeyboardCommand?
    private var lastCopiedUtterance: UUID?
    private var isVisible = false
    private let rows = UIStackView()
    private let headline = UILabel()
    private let detail = UILabel()
    private let dictateButton = UIButton(type: .system)
    private let activityIndicator = UIActivityIndicatorView(style: .medium)
    private let root = UIStackView()
    private var heightConstraint: NSLayoutConstraint?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .secondarySystemBackground
        view.tintColor = .systemBlue
        root.axis = .vertical
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            root.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            root.topAnchor.constraint(equalTo: view.topAnchor, constant: 10),
            root.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6)
        ])
        heightConstraint = view.heightAnchor.constraint(equalToConstant: 288)
        heightConstraint?.priority = .defaultHigh
        heightConstraint?.isActive = true
        makeDictationHeader()
        rows.axis = .vertical
        rows.spacing = 7
        rows.distribution = .fillEqually
        root.addArrangedSubview(rows)
        buildKeys()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        refreshBridge()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshBridge() }
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        pollTimer?.invalidate()
        pollTimer = nil
        deleteTimer?.invalidate()
        deleteTimer = nil
        // Changing fields/apps requires an explicit insert; never surprise a new text field.
        autoInsertionTarget.invalidate()
        pendingCommand = nil
    }

    override func textDidChange(_ textInput: (any UITextInput)?) {
        super.textDidChange(textInput)
        invalidateAutomaticInsertionForInputChange()
    }

    override func selectionDidChange(_ textInput: (any UITextInput)?) {
        super.selectionDidChange(textInput)
        invalidateAutomaticInsertionForInputChange()
    }

    private func invalidateAutomaticInsertionForInputChange() {
        // Apple identifies documents, not individual fields within a custom host document.
        // Any input/selection callback while dictating requires an explicit final insert.
        // This checks identity only; it never reads host text or selected text.
        autoInsertionTarget.observeDocument(textDocumentProxy.documentIdentifier)
        autoInsertionTarget.invalidate()
        refreshBridge()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let compact = view.bounds.width > 550 && view.bounds.height < 330
        let desiredHeight: CGFloat = compact ? 240 : 288
        if heightConstraint?.constant != desiredHeight { heightConstraint?.constant = desiredHeight }
    }

    private func makeDictationHeader() {
        let panel = UIStackView()
        panel.axis = .horizontal
        panel.alignment = .center
        panel.spacing = 10
        panel.isLayoutMarginsRelativeArrangement = true
        panel.layoutMargins = UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        panel.heightAnchor.constraint(equalToConstant: 60).isActive = true
        let copy = UIStackView()
        copy.axis = .vertical
        copy.spacing = 2
        headline.font = .systemFont(ofSize: 15, weight: .semibold)
        headline.textColor = .label
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabel
        detail.numberOfLines = 2
        copy.addArrangedSubview(headline)
        copy.addArrangedSubview(detail)
        panel.addArrangedSubview(copy)
        activityIndicator.hidesWhenStopped = true
        panel.addArrangedSubview(activityIndicator)
        dictateButton.configuration = .tinted()
        dictateButton.setContentHuggingPriority(.required, for: .horizontal)
        dictateButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        dictateButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        dictateButton.addTarget(self, action: #selector(dictationTapped), for: .touchUpInside)
        panel.addArrangedSubview(dictateButton)
        secondaryActionButton.configuration = .plain()
        secondaryActionButton.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        secondaryActionButton.setContentHuggingPriority(.required, for: .horizontal)
        secondaryActionButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        secondaryActionButton.addTarget(self, action: #selector(secondaryActionTapped), for: .touchUpInside)
        panel.addArrangedSubview(secondaryActionButton)
        root.addArrangedSubview(panel)
    }

    private func buildKeys() {
        rows.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let keyRows: [[String]]
        switch layout {
        case .letters:
            keyRows = [Array("qwertyuiop").map(String.init), Array("asdfghjkl").map(String.init), Array("zxcvbnm").map(String.init)]
        case .numbers:
            keyRows = [Array("1234567890").map(String.init), ["-", "/", ":", ";", "(", ")", "$", "&", "@", "\""], [".", ",", "?", "!", "'"]]
        case .symbols:
            keyRows = [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="], ["_", "\\", "|", "~", "<", ">", "€", "£", "¥", "•"], [".", ",", "?", "!", "'"]]
        }
        for (index, keys) in keyRows.enumerated() {
            let row = rowStack()
            if index == 1 && layout == .letters {
                row.isLayoutMarginsRelativeArrangement = true
                row.layoutMargins = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
            }
            if index == 2 {
                let modifier = makeKey(layout == .letters ? "" : (layout == .numbers ? "#+=" : "123"), secondary: true)
                modifier.accessibilityLabel = layout == .letters ? (capsLocked ? "Caps lock on" : "Shift") : "More symbols"
                if layout == .letters {
                    modifier.setImage(UIImage(systemName: capsLocked ? "capslock.fill" : (shifted ? "shift.fill" : "shift")), for: .normal)
                }
                if layout == .letters && shifted { modifier.backgroundColor = .systemGray3 }
                modifier.addTarget(self, action: #selector(modifierTapped), for: .touchUpInside)
                row.addArrangedSubview(modifier)
            }
            for key in keys {
                let title = layout == .letters && shifted ? key.uppercased() : key
                let button = makeKey(title)
                button.addAction(UIAction { [weak self] _ in self?.type(title) }, for: .touchUpInside)
                row.addArrangedSubview(button)
            }
            if index == 2 { row.addArrangedSubview(deleteKey()) }
            rows.addArrangedSubview(row)
        }
        let bottom = rowStack()
        bottom.distribution = .fill
        let mode = makeKey(layout == .letters ? "123" : "ABC", secondary: true)
        mode.widthAnchor.constraint(equalToConstant: 48).isActive = true
        mode.accessibilityLabel = layout == .letters ? "Numbers" : "Letters"
        mode.addTarget(self, action: #selector(layoutTapped), for: .touchUpInside)
        bottom.addArrangedSubview(mode)
        if needsInputModeSwitchKey {
            let globe = makeKey("", secondary: true)
            globe.setImage(UIImage(systemName: "globe"), for: .normal)
            globe.widthAnchor.constraint(equalToConstant: 38).isActive = true
            globe.accessibilityLabel = "Next keyboard. Touch and hold to choose keyboard."
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            bottom.addArrangedSubview(globe)
        }
        let space = makeKey("space")
        space.titleLabel?.font = .systemFont(ofSize: 15, weight: .regular)
        space.addAction(UIAction { [weak self] _ in self?.type(" ") }, for: .touchUpInside)
        space.setContentHuggingPriority(.defaultLow, for: .horizontal)
        bottom.addArrangedSubview(space)
        let enter = makeKey("return", secondary: true)
        enter.titleLabel?.font = .systemFont(ofSize: 14, weight: .medium)
        enter.widthAnchor.constraint(equalToConstant: 72).isActive = true
        enter.addAction(UIAction { [weak self] _ in self?.type("\n") }, for: .touchUpInside)
        bottom.addArrangedSubview(enter)
        rows.addArrangedSubview(bottom)
    }

    private func rowStack() -> UIStackView {
        let row = UIStackView()
        row.axis = .horizontal
        row.spacing = 5
        row.distribution = .fillEqually
        return row
    }

    private func makeKey(_ title: String, secondary: Bool = false) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.setTitleColor(.label, for: .normal)
        button.titleLabel?.font = .systemFont(ofSize: 21, weight: .regular)
        button.backgroundColor = secondary ? UIColor.systemFill : .tertiarySystemBackground
        button.tintColor = .label
        button.layer.cornerRadius = 7
        button.accessibilityLabel = title
        return button
    }

    private func deleteKey() -> UIButton {
        let button = makeKey("", secondary: true)
        button.setImage(UIImage(systemName: "delete.left"), for: .normal)
        button.accessibilityLabel = "Delete"
        button.addTarget(self, action: #selector(deletePressed), for: .touchDown)
        button.addTarget(self, action: #selector(deleteReleased), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        return button
    }

    private func type(_ text: String) {
        autoInsertionTarget.invalidate()
        textDocumentProxy.insertText(text)
        if layout == .letters && shifted && !capsLocked && text != " " && text != "\n" {
            shifted = false
            buildKeys()
        }
    }

    @objc private func deletePressed() {
        autoInsertionTarget.invalidate()
        textDocumentProxy.deleteBackward()
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.textDocumentProxy.deleteBackward() }
                }
            }
        }
    }

    @objc private func deleteReleased() { deleteTimer?.invalidate(); deleteTimer = nil }

    @objc private func modifierTapped() {
        if layout == .letters {
            if Date().timeIntervalSince(lastShiftTap) < 0.35 {
                capsLocked = true
                shifted = true
            } else {
                capsLocked = false
                shifted.toggle()
            }
            lastShiftTap = Date()
        } else {
            layout = layout == .numbers ? .symbols : .numbers
        }
        buildKeys()
    }

    @objc private func layoutTapped() {
        layout = layout == .letters ? .numbers : .letters
        buildKeys()
    }

    private func refreshBridge() {
        guard isVisible else { return }
        autoInsertionTarget.observeDocument(textDocumentProxy.documentIdentifier)
        guard hasFullAccess else {
            store = nil
            status = nil
            show("Dictation requires Full Access", "Enable Allow Full Access in Keyboard Settings.")
            return
        }
        do {
            if store == nil { store = try SharedKeyboardStore.appGroupStore() }
            status = try store?.readStatus()
            if let pendingCommand, Date().timeIntervalSince(pendingCommand.createdAt) > 10 {
                self.pendingCommand = nil
                autoInsertionTarget.invalidate()
            }
            guard let status, status.isLive() || status.hasDeliverableResult() else {
                show("Keyboard session off", "Open Local Scribe to enable dictation.")
                return
            }
            if let pendingCommand {
                if (pendingCommand.action == .start && status.phase == .recording && status.utteranceID == pendingCommand.utteranceID)
                    || (pendingCommand.action == .stop && status.phase != .recording)
                    || (pendingCommand.action == .cancel && status.phase != .recording && status.utteranceID != pendingCommand.utteranceID)
                    || status.phase == .failed {
                    self.pendingCommand = nil
                }
            }
            if let pendingCommand {
                switch pendingCommand.action {
                case .start: show("Starting…", "Keep this field open for automatic insertion.", busy: true)
                case .stop: show("Stopping…", "Finishing your dictation.", busy: true)
                case .cancel: show("Cancelling…", "This dictation will be discarded.", busy: true)
                }
                return
            }
            if status.hasDeliverableResult(), let utterance = status.utteranceID, let text = status.transcript,
               try store?.readReceipt()?.utteranceID != utterance {
                if autoInsertionTarget.allows(utteranceID: utterance, documentIdentifier: textDocumentProxy.documentIdentifier) {
                    if try insertResult(text, utterance: utterance, automatic: true) {
                        show("Inserted", "")
                    } else {
                        show("Dictation ready", "Insert into this text field.", action: "Insert", symbol: "text.badge.plus", secondary: .copy)
                    }
                } else {
                    show("Dictation ready", "Insert into this text field.", action: "Insert", symbol: "text.badge.plus", secondary: .copy)
                }
                return
            }
            if !status.canRecord(), status.hasDeliverableResult() {
                let copied = status.utteranceID == lastCopiedUtterance
                show(copied ? "Copied" : "Inserted", copied ? "Paste your dictation in any app." : "Microphone off.")
                return
            }
            if !status.canRecord() && status.phase != .transcribing {
                show(status.phase == .failed ? "Dictation unavailable" : "Transcribing…",
                     status.message ?? "Microphone off.", busy: status.phase != .failed)
                return
            }
            switch status.phase {
            case .recording:
                show("Recording", "Tap Stop when finished.", action: "Stop", symbol: "stop.fill", enabled: pendingCommand == nil, secondary: .cancel)
            case .transcribing:
                show("Transcribing…", status.canRecord() ? "On-device transcription." : "Microphone off.", busy: true)
            case .failed:
                show("Dictation unavailable", status.message ?? "Open Local Scribe to resume.", action: "Record", symbol: "mic.fill")
            case .ready:
                let minutes = max(1, Int(ceil((status.expiresAt?.timeIntervalSinceNow ?? 0) / 60)))
                let copied = status.utteranceID != nil && status.utteranceID == lastCopiedUtterance
                show(copied ? "Copied" : "Dictation", copied ? "Paste your dictation in any app." : "Session ends in \(minutes)m", action: "Record", symbol: "mic.fill", enabled: pendingCommand == nil)
            case .inactive:
                show("Keyboard session off", "Open Local Scribe to enable dictation.")
            }
        } catch {
            show("Dictation unavailable", "Open Local Scribe to check shared access.")
        }
    }

    private func show(_ title: String, _ subtitle: String, action: String? = nil, symbol: String? = nil, busy: Bool = false, enabled: Bool = true, secondary: SecondaryAction? = nil) {
        headline.text = title
        detail.text = subtitle
        detail.isHidden = subtitle.isEmpty
        var configuration = UIButton.Configuration.tinted()
        configuration.title = action
        configuration.image = symbol.flatMap { UIImage(systemName: $0) }
        configuration.imagePadding = 6
        configuration.cornerStyle = .medium
        configuration.baseForegroundColor = action == "Stop" ? .systemRed : .systemBlue
        dictateButton.configuration = configuration
        dictateButton.isHidden = action == nil
        dictateButton.isEnabled = enabled
        dictateButton.accessibilityLabel = action
        dictateButton.accessibilityHint = subtitle
        secondaryAction = secondary
        var secondaryConfiguration = UIButton.Configuration.plain()
        secondaryConfiguration.title = secondary == .cancel ? "Cancel" : "Copy"
        secondaryConfiguration.baseForegroundColor = secondary == .cancel ? .systemRed : .systemBlue
        secondaryActionButton.configuration = secondaryConfiguration
        secondaryActionButton.isHidden = secondary == nil
        secondaryActionButton.isEnabled = enabled && pendingCommand == nil
        secondaryActionButton.accessibilityLabel = secondaryConfiguration.title
        secondaryActionButton.accessibilityHint = secondary == .cancel ? "Discard this dictation without inserting text." : "Copy this dictation instead of inserting it."
        if busy { activityIndicator.startAnimating() } else { activityIndicator.stopAnimating() }
    }

    @objc private func dictationTapped() {
        autoInsertionTarget.observeDocument(textDocumentProxy.documentIdentifier)
        guard hasFullAccess, pendingCommand == nil, let status, status.isLive() || status.hasDeliverableResult(),
              let sessionID = status.sessionID, let store else { return }
        do {
            if status.hasDeliverableResult(), let utterance = status.utteranceID, let text = status.transcript,
               try store.readReceipt()?.utteranceID != utterance {
                try insertResult(text, utterance: utterance)
                refreshBridge()
                return
            }
            guard status.canRecord() else { return }
            let isStop = status.phase == .recording
            guard isStop || status.phase == .ready || status.phase == .failed else { return }
            let utterance = isStop ? status.utteranceID : UUID()
            guard let utterance else { return }
            let command = KeyboardCommand(sessionID: sessionID, utteranceID: utterance, action: isStop ? .stop : .start)
            try store.writeCommand(command)
            pendingCommand = command
            if !isStop {
                autoInsertionTarget.arm(utteranceID: utterance, documentIdentifier: textDocumentProxy.documentIdentifier)
            }
            show(isStop ? "Stopping…" : "Starting…", "Keep this text field open to insert automatically.", busy: true)
        } catch {
            show("Dictation unavailable", "Open Local Scribe to check shared access.")
        }
    }

    @objc private func secondaryActionTapped() {
        guard hasFullAccess, pendingCommand == nil, let status, let store else { return }
        do {
            switch secondaryAction {
            case .copy:
                autoInsertionTarget.invalidate()
                guard let delivery = try store.claimPendingResult(status) else { refreshBridge(); return }
                lastCopiedUtterance = delivery.utteranceID
                UIPasteboard.general.setItems([[UTType.utf8PlainText.identifier: delivery.text]], options: [.localOnly: true])
                show("Copied", "Paste your dictation in any app.")
            case .cancel:
                guard let session = status.sessionID, let utterance = status.utteranceID else { return }
                let command = KeyboardCommand(sessionID: session, utteranceID: utterance, action: .cancel)
                guard command.isValid(for: status) else { refreshBridge(); return }
                autoInsertionTarget.invalidate()
                try store.writeCommand(command)
                pendingCommand = command
                show("Cancelling…", "This dictation will be discarded.", busy: true)
            case nil: break
            }
        } catch {
            show("Dictation unavailable", "Open Local Scribe to check shared access.")
        }
    }

    @discardableResult
    private func insertResult(_ text: String, utterance: UUID, automatic: Bool = false) throws -> Bool {
        guard let store, let status, status.utteranceID == utterance, status.transcript == text else { return false }
        if automatic {
            autoInsertionTarget.observeDocument(textDocumentProxy.documentIdentifier)
            guard autoInsertionTarget.allows(utteranceID: utterance, documentIdentifier: textDocumentProxy.documentIdentifier) else { return false }
        }
        // Claim before insertion prevents duplicate insertion after a process restart.
        // TextDocumentProxy and file IO cannot form an atomic transaction: a crash between
        // these operations may lose the insertion, but never deliberately replays it.
        guard let delivery = try store.claimPendingResult(status) else { return false }
        textDocumentProxy.insertText(delivery.text)
        autoInsertionTarget.invalidate()
        pendingCommand = nil
        return true
    }

    isolated deinit {
        pollTimer?.invalidate()
        deleteTimer?.invalidate()
    }
}
