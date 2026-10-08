import ActivityKit
import Foundation

struct DictationActivityAttributes: ActivityAttributes, Sendable {
  enum Phase: String, Codable, Hashable, Sendable {
    case recording, transcribing, ready, cancelled, failed

    var status: String {
      switch self {
      case .recording: "Recording"
      case .transcribing: "Transcribing"
      case .ready: "Ready"
      case .cancelled: "Cancelled"
      case .failed: "Dictation failed"
      }
    }

    var compactStatus: String {
      self == .failed ? "Failed" : status
    }

    var symbol: String {
      switch self {
      case .recording: "mic.fill"
      case .transcribing: "waveform"
      case .ready: "checkmark"
      case .cancelled: "xmark"
      case .failed: "exclamationmark.triangle"
      }
    }
  }
  struct ContentState: Codable, Hashable, Sendable {
    var phase: Phase
    var elapsed: TimeInterval
    var message: String?
    var transcriptTail: String? = nil

    var status: String {
      guard phase == .failed, let message, !message.isEmpty else { return phase.status }
      return message
    }
  }
  let sessionID: UUID
  let startedAt: Date
  let modelName: String
}
