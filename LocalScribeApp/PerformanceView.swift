import SwiftUI
import LocalScribeCore

struct PerformanceView: View {
    @ObservedObject var controller: AppController
    @State private var reference = ""
    @State private var evaluate = false
    private var score: WordErrorRateResult? {
        guard evaluate else { return nil }
        return WordErrorRate.evaluate(reference: reference, hypothesis: controller.rawTranscript)
    }
    var body: some View {
        Form {
            Section {
                if controller.rawTranscript.isEmpty {
                    Text("Finish a dictation to measure its word error rate.").foregroundStyle(AppTheme.inkSecondary)
                } else {
                    TextField("What you said", text: $reference, axis: .vertical)
                        .lineLimit(3...8).onChange(of: reference) { _, _ in evaluate = false }
                        .accessibilityLabel("Reference transcript for word error rate")
                    DisclosureGroup("Raw transcript") {
                        Text(controller.rawTranscript).textSelection(.enabled)
                    }
                    Button("Calculate word error rate") { evaluate = true }
                        .disabled(reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || reference.count > 8_000)
                    if reference.count > 8_000 {
                        Text("Use a reference of 8,000 characters or fewer.").font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                    }
                    if let score, let rate = score.rate {
                        LabeledContent("Word error rate") {
                            Text(String(format: "%.1f%%", rate * 100)).foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Substitutions") {
                            Text("\(score.substitutions)").foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Missing words") {
                            Text("\(score.deletions)").foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Extra words") {
                            Text("\(score.insertions)").foregroundStyle(AppTheme.inkSecondary)
                        }
                        LabeledContent("Reference words") {
                            Text("\(score.referenceWordCount)").foregroundStyle(AppTheme.inkSecondary)
                        }
                    }
                }
            } header: {
                Text("Word error rate").foregroundStyle(AppTheme.inkSecondary)
            } footer: {
                Text("Enter the words you spoke to compare them with the raw model output, before dictionary corrections. Case and punctuation are ignored.").foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
            if controller.performanceReports.isEmpty {
                Section {
                    Text("No measurements yet. Model loading and transcription results appear after a dictation.")
                        .foregroundStyle(AppTheme.inkSecondary)
                } header: { Text("Completed operations").foregroundStyle(AppTheme.inkSecondary) }.listRowBackground(AppTheme.surface)
            } else {
                ForEach(controller.performanceReports.reversed()) { item in
                    Section {
                        LabeledContent("Status") {
                            Text(item.successful ? "Completed" : "Failed")
                                .foregroundStyle(item.successful ? AppTheme.success : AppTheme.error)
                        }
                        LabeledContent("Measured", value: item.date.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Execution configuration", value: ModelMeasurementPresentation.contextName(item.executionContext))
                        LabeledContent("Elapsed time") {
                            Text(String(format: "%.3f s", item.resources.elapsedSeconds)).foregroundStyle(AppTheme.inkSecondary)
                        }
                        if let audio = item.resources.audioSeconds {
                            LabeledContent("Audio duration") {
                                Text(String(format: "%.1f s", audio)).foregroundStyle(AppTheme.inkSecondary)
                            }
                        }
                        if let ratio = item.resources.realTimeFactor {
                            LabeledContent("Time / audio duration") {
                                Text(String(format: "%.3f", ratio)).foregroundStyle(AppTheme.inkSecondary)
                            }
                        }
                        if let cpu = item.resources.averageActiveCPUCores {
                            LabeledContent("Average active CPU cores") {
                                Text(String(format: "%.2f", cpu)).foregroundStyle(AppTheme.inkSecondary)
                            }
                        }
                        if let peak = item.resources.sampledPeakPhysicalFootprintBytes {
                            LabeledContent("Sampled app peak RAM") {
                                Text(memory(peak)).foregroundStyle(AppTheme.inkSecondary)
                            }
                        }
                        if let baseline = item.resources.initialPhysicalFootprintBytes {
                            LabeledContent("Starting memory") {
                                Text(memory(baseline)).foregroundStyle(AppTheme.inkSecondary)
                            }
                        }
                        if let final = item.resources.finalPhysicalFootprintBytes {
                            LabeledContent("Finishing memory") {
                                Text(memory(final)).foregroundStyle(AppTheme.inkSecondary)
                            }
                        }
                        LabeledContent("Thermal state") {
                            Text(item.resources.initialThermalState.rawValue + " → " + item.resources.finalThermalState.rawValue).foregroundStyle(AppTheme.inkSecondary)
                        }
                        DisclosureGroup("Requested compute configuration") {
                            Text(item.requestedBackend).font(.footnote).foregroundStyle(AppTheme.inkSecondary)
                        }
                        if let phases = item.preparationPhases, !phases.isEmpty {
                            PreparationPhaseMeasurements(phases: phases)
                        }
                    } header: { Text(item.model.name + " · " + stageName(item.stage)).foregroundStyle(AppTheme.inkSecondary) }.listRowBackground(AppTheme.surface)
                }
            }
            Section {
                NavigationLink("Measurement details") { MeasurementDetailsView() }
            } footer: {
                Text("Measurements cover the whole app and remain in this session. GPU and Neural Engine utilization require device profiling.").foregroundStyle(AppTheme.inkSecondary)
            }.listRowBackground(AppTheme.surface)
        }
        .scribeForm()
        .monospacedDigit()
        .onChange(of: controller.rawTranscript) { _, _ in evaluate = false }
        .navigationTitle("Accuracy").navigationBarTitleDisplayMode(.inline)
    }
    private func stageName(_ stage: EnginePerformanceReport.Stage) -> String {
        switch stage {
        case .modelLoad: "Model loading"
        case .alreadyLoaded: "Model already loaded"
        case .transcription: "Transcription"
        }
    }
    private func memory(_ bytes: UInt64) -> String { String(format: "%.1f MiB", Double(bytes) / 1_048_576) }
}

private struct MeasurementDetailsView: View {
    var body: some View {
        Form {
            Section {
                Text("Case and punctuation are ignored. Numbers and contractions are not expanded. Published benchmarks may use different text normalization, so their scores are not directly comparable.")
            } header: { Text("Word error rate").foregroundStyle(AppTheme.inkSecondary) }.listRowBackground(AppTheme.surface)
            Section {
                Text("CPU time and memory include the interface and measurement overhead. Peak memory is sampled every 50 milliseconds and can miss brief spikes.")
                Text("One active CPU core means one core’s worth of CPU time during the measurement. A lower time/audio ratio means faster transcription.")
            } header: { Text("CPU and memory").foregroundStyle(AppTheme.inkSecondary) }.listRowBackground(AppTheme.surface)
            Section {
                Text("Use Instruments on a physical device to measure hardware utilization, power, and system memory pressure. The requested compute configuration does not prove which operations ran on the Neural Engine.")
            } header: { Text("Hardware profiling").foregroundStyle(AppTheme.inkSecondary) }.listRowBackground(AppTheme.surface)
            Section {
                Text("Keep model loaded preloads your Dictate model and retains the last-used model between dictations and when switching apps. Turn it off to release the model after dictation. Changing models replaces the loaded runtime; force quitting releases it. iOS may reclaim memory or terminate a background app. Keeping a model loaded does not keep the microphone on.")
            } header: { Text("Model memory").foregroundStyle(AppTheme.inkSecondary) }.listRowBackground(AppTheme.surface)
        }.scribeForm().navigationTitle("Measurement details").navigationBarTitleDisplayMode(.inline)
    }
}

#if DEBUG && targetEnvironment(simulator)
@MainActor
func designPreviewMeasurementDetails() -> some View { MeasurementDetailsView() }
#endif
