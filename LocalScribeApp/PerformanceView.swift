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
                    Text("Finish a dictation to measure its word error rate.").foregroundStyle(.secondary)
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
                        Text("Use a reference of 8,000 characters or fewer.").font(.footnote).foregroundStyle(.secondary)
                    }
                    if let score, let rate = score.rate {
                        LabeledContent("Word error rate", value: String(format: "%.1f%%", rate * 100))
                        LabeledContent("Substitutions", value: "\(score.substitutions)")
                        LabeledContent("Missing words", value: "\(score.deletions)")
                        LabeledContent("Extra words", value: "\(score.insertions)")
                        LabeledContent("Reference words", value: "\(score.referenceWordCount)")
                    }
                }
            } header: {
                Text("Recognition accuracy")
            } footer: {
                Text("Enter the words you spoke to compare them with the raw model output, before dictionary corrections. Case and punctuation are ignored.")
            }
            if controller.performanceReports.isEmpty {
                Section("Performance") {
                    Text("No measurements yet. Model loading and transcription results appear after a dictation.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ForEach(controller.performanceReports.reversed()) { item in
                    Section(item.model.name + " · " + stageName(item.stage)) {
                        LabeledContent("Status", value: item.successful ? "Completed" : "Failed")
                        LabeledContent("Elapsed time", value: String(format: "%.3f s", item.resources.elapsedSeconds))
                        if let audio = item.resources.audioSeconds {
                            LabeledContent("Audio duration", value: String(format: "%.1f s", audio))
                        }
                        if let ratio = item.resources.realTimeFactor {
                            LabeledContent("Time / audio duration", value: String(format: "%.3f", ratio))
                        }
                        if let cpu = item.resources.averageActiveCPUCores {
                            LabeledContent("Average active CPU cores", value: String(format: "%.2f", cpu))
                        }
                        if let peak = item.resources.sampledPeakPhysicalFootprintBytes {
                            LabeledContent("Sampled peak memory", value: memory(peak))
                        }
                        if let baseline = item.resources.initialPhysicalFootprintBytes {
                            LabeledContent("Starting memory", value: memory(baseline))
                        }
                        if let final = item.resources.finalPhysicalFootprintBytes {
                            LabeledContent("Finishing memory", value: memory(final))
                        }
                        LabeledContent("Thermal state", value: item.resources.initialThermalState.rawValue + " → " + item.resources.finalThermalState.rawValue)
                        DisclosureGroup("Requested compute configuration") {
                            Text(item.requestedBackend).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section {
                NavigationLink("Measurement details") { MeasurementDetailsView() }
            } footer: {
                Text("Measurements cover the whole app and remain in this session. GPU and Neural Engine utilization require device profiling.")
            }
        }
        .onChange(of: controller.rawTranscript) { _, _ in evaluate = false }
        .navigationTitle("Performance & accuracy").navigationBarTitleDisplayMode(.inline)
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
            Section("Word error rate") {
                Text("Case and punctuation are ignored. Numbers and contractions are not expanded. Published benchmarks may use different text normalization, so their scores are not directly comparable.")
            }
            Section("CPU and memory") {
                Text("CPU time and memory include the interface and measurement overhead. Peak memory is sampled every 50 milliseconds and can miss brief spikes.")
                Text("One active CPU core means one core’s worth of CPU time during the measurement. A lower time/audio ratio means faster transcription.")
            }
            Section("Hardware profiling") {
                Text("Use Instruments on a physical device to measure hardware utilization, power, and system memory pressure. The requested compute configuration does not prove which operations ran on the Neural Engine.")
            }
            Section("Model memory") {
                Text("Models stay loaded for 60 seconds between foreground dictations, then unload. An inactive background app releases its model. A keyboard microphone session keeps the model available until the session ends or iOS requests memory.")
            }
        }.navigationTitle("Measurement details").navigationBarTitleDisplayMode(.inline)
    }
}
