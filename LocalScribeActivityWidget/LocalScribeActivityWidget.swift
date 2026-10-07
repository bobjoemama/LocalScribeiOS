import ActivityKit
import AppIntents
import SwiftUI
import UIKit
import WidgetKit

@main
struct LocalScribeActivityWidgetBundle: WidgetBundle {
  var body: some Widget {
    LocalScribeLiveActivity()
  }
}

struct LocalScribeLiveActivity: Widget {
  var body: some WidgetConfiguration {
    ActivityConfiguration(for: DictationActivityAttributes.self) { context in
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 12) {
          ActivityPhaseSymbol(phase: context.state.phase)
            .font(.title2)
            .accessibilityHidden(true)

          VStack(alignment: .leading, spacing: 3) {
            Text("LocalScribe")
              .font(.headline)
            Text(context.state.status)
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }

          Spacer(minLength: 8)

          ActivityElapsed(context: context)
            .font(.title3.monospacedDigit())
        }

        if context.state.phase == .recording {
          StopDictationButton(sessionID: context.attributes.sessionID)
        }
      }
      .padding(16)
      .activityBackgroundTint(Color(uiColor: .systemBackground))
      .widgetURL(URL(string: "localscribe://dictation"))
    } dynamicIsland: { context in
      DynamicIsland {
        DynamicIslandExpandedRegion(.leading) {
          HStack(spacing: 6) {
            ActivityPhaseSymbol(phase: context.state.phase)
              .accessibilityHidden(true)
            Text("LocalScribe")
          }
          .font(.headline)
        }
        DynamicIslandExpandedRegion(.trailing) {
          ActivityElapsed(context: context)
            .font(.headline.monospacedDigit())
        }
        DynamicIslandExpandedRegion(.bottom) {
          VStack(alignment: .leading, spacing: 12) {
            if let tail = context.state.transcriptTail, !tail.isEmpty {
              Text(tail)
                .font(.subheadline)
                .lineLimit(6)
                .truncationMode(.head)
                .privacySensitive()
                .accessibilityLabel("Latest dictation")
                .accessibilityValue(tail)
            }
            Text(context.state.status)
              .font(.subheadline)
              .foregroundStyle(.secondary)
            if context.state.phase == .recording {
              StopDictationButton(sessionID: context.attributes.sessionID)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      } compactLeading: {
        ActivityPhaseSymbol(phase: context.state.phase)
          .accessibilityLabel(context.state.status)
      } compactTrailing: {
        if context.state.phase == .recording {
          ActivityElapsed(context: context)
            .font(.caption2.monospacedDigit())
            .frame(maxWidth: 64)
        } else {
          Text(context.state.phase.compactStatus)
            .font(.caption2)
        }
      } minimal: {
        ActivityPhaseSymbol(phase: context.state.phase)
          .accessibilityLabel(context.state.status)
      }
      .keylineTint(context.state.phase == .recording ? ActivityColors.recording : nil)
      .widgetURL(URL(string: "localscribe://dictation"))
    }
  }
}

private struct StopDictationButton: View {
  let sessionID: UUID

  var body: some View {
    Button(intent: StopLiveDictationIntent(sessionID: sessionID)) {
      Label("Stop", systemImage: "stop.fill")
        .frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.borderedProminent)
    .tint(ActivityColors.recording)
    .foregroundStyle(ActivityColors.onRecording)
    .accessibilityHint("Finish recording and copy the dictation")
  }
}

#if DEBUG
  #Preview(
    "Lock Screen phases", as: .content,
    using: DictationActivityAttributes(
      sessionID: UUID(), startedAt: Date().addingTimeInterval(-42), modelName: "Parakeet Realtime"
    )
  ) {
    LocalScribeLiveActivity()
  } contentStates: {
    DictationActivityAttributes.ContentState(
      phase: .recording, elapsed: 42, message: nil,
      transcriptTail: "Please send the updated notes today.")
    DictationActivityAttributes.ContentState(phase: .transcribing, elapsed: 42, message: nil)
    DictationActivityAttributes.ContentState(phase: .ready, elapsed: 42, message: nil)
    DictationActivityAttributes.ContentState(phase: .cancelled, elapsed: 42, message: nil)
    DictationActivityAttributes.ContentState(
      phase: .failed, elapsed: 0, message: "Microphone unavailable")
  }

  #Preview(
    "Expanded Island phases", as: .dynamicIsland(.expanded),
    using: DictationActivityAttributes(
      sessionID: UUID(), startedAt: Date().addingTimeInterval(-42), modelName: "Parakeet Realtime"
    )
  ) {
    LocalScribeLiveActivity()
  } contentStates: {
    DictationActivityAttributes.ContentState(
      phase: .recording, elapsed: 42, message: nil,
      transcriptTail:
        "Please send the updated notes today. Add the new measurements. I'll review them this afternoon."
    )
    DictationActivityAttributes.ContentState(
      phase: .transcribing, elapsed: 42, message: nil,
      transcriptTail: "Please send the updated notes today.")
    DictationActivityAttributes.ContentState(
      phase: .ready, elapsed: 42, message: nil,
      transcriptTail: "Please send the updated notes today.")
    DictationActivityAttributes.ContentState(phase: .cancelled, elapsed: 42, message: nil)
    DictationActivityAttributes.ContentState(
      phase: .failed, elapsed: 0, message: "Microphone unavailable")
  }
#endif

private struct ActivityPhaseSymbol: View {
  let phase: DictationActivityAttributes.Phase

  var body: some View {
    Image(systemName: phase.symbol)
      .foregroundStyle(color)
  }

  private var color: Color {
    switch phase {
    case .recording: ActivityColors.recording
    case .ready: ActivityColors.success
    case .failed: ActivityColors.error
    case .transcribing, .cancelled: Color.primary
    }
  }
}

private struct ActivityElapsed: View {
  let context: ActivityViewContext<DictationActivityAttributes>

  var body: some View {
    if context.state.phase == .recording {
      Text(context.attributes.startedAt, style: .timer)
        .accessibilityLabel("Recording duration")
        .accessibilityValue(Text(context.attributes.startedAt, style: .timer))
    } else {
      Text(Self.duration(context.state.elapsed))
        .accessibilityLabel("Recorded duration")
        .accessibilityValue(Self.duration(context.state.elapsed))
    }
  }

  private static func duration(_ elapsed: TimeInterval) -> String {
    let seconds = elapsed.isFinite ? Int(min(max(0, elapsed), 359_999)) : 0
    if seconds >= 3_600 {
      return String(format: "%d:%02d:%02d", seconds / 3_600, seconds / 60 % 60, seconds % 60)
    }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
  }
}

private enum ActivityColors {
  // Extensions have their own bundles; these dynamic colors do not depend on
  // the containing app's asset catalog or on a stored appearance preference.
  static let recording = dynamic(light: 0xD3352A, dark: 0xFF5F52)
  static let onRecording = dynamic(light: 0xFFFFFF, dark: 0x141312)
  static let success = dynamic(light: 0x2E7D4F, dark: 0x5CC587)
  static let error = dynamic(light: 0xB42318, dark: 0xF2655B)

  private static func dynamic(light: UInt32, dark: UInt32) -> Color {
    Color(
      uiColor: UIColor { traits in
        let value = traits.userInterfaceStyle == .dark ? dark : light
        return UIColor(
          red: CGFloat(value >> 16 & 0xFF) / 255,
          green: CGFloat(value >> 8 & 0xFF) / 255,
          blue: CGFloat(value & 0xFF) / 255, alpha: 1)
      })
  }
}
