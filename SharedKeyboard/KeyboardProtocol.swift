import Foundation

/// Only dictation control and its pending result cross this boundary. Typed host text never does.
public enum KeyboardSessionPhase: String, Codable, Sendable {
    case inactive, ready, recording, transcribing, failed
}

public struct KeyboardCommand: Codable, Equatable, Sendable {
    public enum Action: String, Codable, Sendable { case start, stop, cancel }
    public let id: UUID
    public let sessionID: UUID
    public let utteranceID: UUID
    public let action: Action
    public let createdAt: Date

    public init(id: UUID = UUID(), sessionID: UUID, utteranceID: UUID, action: Action, createdAt: Date = Date()) {
        self.id = id
        self.sessionID = sessionID
        self.utteranceID = utteranceID
        self.action = action
        self.createdAt = createdAt
    }

    public func isValid(for status: KeyboardSessionStatus, now: Date = Date()) -> Bool {
        let age = now.timeIntervalSince(createdAt)
        guard age >= -1 && age <= 10, status.sessionID == sessionID, status.canRecord(at: now) else { return false }
        switch action {
        case .start: return true
        case .stop, .cancel: return status.phase == .recording && status.utteranceID == utteranceID
        }
    }
}

public struct KeyboardSessionStatus: Codable, Equatable, Sendable {
    public let sessionID: UUID?
    public let expiresAt: Date?
    public let deliveryExpiresAt: Date?
    public let heartbeatAt: Date
    public let phase: KeyboardSessionPhase
    public let utteranceID: UUID?
    public let transcript: String?
    public let message: String?

    public init(sessionID: UUID? = nil, expiresAt: Date? = nil, deliveryExpiresAt: Date? = nil, heartbeatAt: Date = Date(), phase: KeyboardSessionPhase = .inactive, utteranceID: UUID? = nil, transcript: String? = nil, message: String? = nil) {
        self.sessionID = sessionID
        self.expiresAt = expiresAt
        self.deliveryExpiresAt = deliveryExpiresAt
        self.heartbeatAt = heartbeatAt
        self.phase = phase
        self.utteranceID = utteranceID
        self.transcript = transcript
        self.message = message
    }

    /// A five-minute lease alone isn't proof that the containing app is still running.
    public func isLive(at now: Date = Date()) -> Bool {
        guard sessionID != nil,
              (expiresAt.map { $0 > now } ?? false) || (deliveryExpiresAt.map { $0 > now } ?? false) else { return false }
        let heartbeatAge = now.timeIntervalSince(heartbeatAt)
        return heartbeatAge >= -1 && heartbeatAge <= 3 && phase != .inactive
    }

    /// A finishing/result lease grants insertion only, never more microphone access.
    public func canRecord(at now: Date = Date()) -> Bool {
        isLive(at: now) && (expiresAt.map { $0 > now } ?? false)
    }

    /// Final text can be inserted after the containing app suspends. Its own short lease
    /// authorizes delivery only; stale heartbeats still reject microphone commands.
    public func hasDeliverableResult(at now: Date = Date()) -> Bool {
        guard sessionID != nil, utteranceID != nil, let deliveryExpiresAt,
              deliveryExpiresAt > now, let transcript else { return false }
        return !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// A delivery claimed by the keyboard. Contains only this utterance's local ASR result.
public struct KeyboardPendingDelivery: Equatable, Sendable {
    public let utteranceID: UUID
    public let text: String
}

public struct KeyboardDeliveryReceipt: Codable, Equatable, Sendable {
    public let utteranceID: UUID
    public let consumedAt: Date
    public init(utteranceID: UUID, consumedAt: Date = Date()) {
        self.utteranceID = utteranceID
        self.consumedAt = consumedAt
    }
}

/// Ephemeral keyboard-only delivery intent. Never persist document identity in the App Group.
public struct KeyboardAutoInsertionTarget: Equatable, Sendable {
    private var utteranceID: UUID?
    private var documentIdentifier: UUID?

    public init() {}

    public mutating func arm(utteranceID: UUID, documentIdentifier: UUID) {
        self.utteranceID = utteranceID
        self.documentIdentifier = documentIdentifier
    }

    public mutating func invalidate() {
        utteranceID = nil
        documentIdentifier = nil
    }

    /// A switch away and back does not restore consent to insert automatically.
    public mutating func observeDocument(_ currentIdentifier: UUID) {
        if let documentIdentifier, documentIdentifier != currentIdentifier { invalidate() }
    }

    public func allows(utteranceID: UUID, documentIdentifier: UUID) -> Bool {
        self.utteranceID == utteranceID && self.documentIdentifier == documentIdentifier
    }
}

/// Small atomic JSON snapshots are shared; audio and typed text remain outside this directory.
public final class SharedKeyboardStore {
    public static let appGroup = "group.com.devesh.localscribe.ios"
    private let directory: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    public init(directory: URL) throws {
        self.directory = directory.appendingPathComponent("KeyboardBridge", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var bridgeDirectory = self.directory
        try bridgeDirectory.setResourceValues(resourceValues)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: self.directory.path)
        #endif
    }

    #if os(iOS)
    public static func appGroupStore() throws -> SharedKeyboardStore {
        guard let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) else {
            throw StoreError.unavailable
        }
        return try SharedKeyboardStore(directory: url)
    }
    #endif

    public enum StoreError: Error { case unavailable }

    public func readStatus() throws -> KeyboardSessionStatus? { try read("status.json") }
    public func writeStatus(_ status: KeyboardSessionStatus) throws { try write(status, to: "status.json") }
    public func readCommand() throws -> KeyboardCommand? { try read("command.json") }
    public func writeCommand(_ command: KeyboardCommand) throws { try write(command, to: "command.json") }
    public func readReceipt() throws -> KeyboardDeliveryReceipt? { try read("receipt.json") }
    public func writeReceipt(_ receipt: KeyboardDeliveryReceipt) throws { try write(receipt, to: "receipt.json") }

    /// Claim before insert/copy so a copied result cannot be inserted by a later poll.
    /// File IO and host insertion/clipboard writes cannot form one atomic transaction.
    public func claimPendingResult(_ status: KeyboardSessionStatus, now: Date = Date()) throws -> KeyboardPendingDelivery? {
        guard status.hasDeliverableResult(at: now), let utterance = status.utteranceID,
              let text = status.transcript, try readReceipt()?.utteranceID != utterance else { return nil }
        try writeReceipt(KeyboardDeliveryReceipt(utteranceID: utterance, consumedAt: now))
        return KeyboardPendingDelivery(utteranceID: utterance, text: text)
    }

    private func read<T: Decodable>(_ name: String) throws -> T? {
        let url = directory.appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(T.self, from: Data(contentsOf: url))
    }

    private func write<T: Encodable>(_ value: T, to name: String) throws {
        let data = try encoder.encode(value)
        #if os(iOS)
        try data.write(to: directory.appendingPathComponent(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: directory.appendingPathComponent(name), options: .atomic)
        #endif
    }
}
