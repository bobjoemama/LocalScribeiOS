import ActivityKit
import AppIntents
import SwiftUI
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
                        Text("Local Scribe")
                            .font(.headline)
                        Text(context.state.phase.status)
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
            .widgetURL(URL(string: "localscribe://dictation"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("Local Scribe", systemImage: context.state.phase.symbol)
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
                        Text(context.state.phase.status)
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
                    .accessibilityLabel(context.state.phase.status)
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
                    .accessibilityLabel(context.state.phase.status)
            }
            .widgetURL(URL(string: "localscribe://dictation"))
        }
    }
}

private struct StopDictationButton: View {
    let sessionID: UUID

    var body: some View {
        Button(intent: StopLiveDictationIntent(sessionID: sessionID)) {
            Label("Stop", systemImage: "stop.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(.red)
        .accessibilityHint("Finish recording and copy the dictation")
    }
}

private struct ActivityPhaseSymbol: View {
    let phase: DictationActivityAttributes.Phase

    var body: some View {
        Image(systemName: phase.symbol)
            .foregroundStyle(phase == .recording ? Color.red : Color.primary)
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

private extension DictationActivityAttributes.Phase {
    var status: String {
        switch self {
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .ready: "Copied"
        case .failed: "Dictation failed. Open Local Scribe."
        }
    }

    var compactStatus: String {
        switch self {
        case .recording: "Recording"
        case .transcribing: "Transcribing"
        case .ready: "Copied"
        case .failed: "Failed"
        }
    }

    var symbol: String {
        switch self {
        case .recording: "mic.fill"
        case .transcribing: "hourglass"
        case .ready: "checkmark"
        case .failed: "exclamationmark.triangle"
        }
    }
}
