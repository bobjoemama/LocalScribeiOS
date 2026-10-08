import Foundation
import Testing
@testable import LocalScribeCore

struct ModelCatalogTests {
    @Test func addedProfilesRetainDistinctPersistedSelections() throws {
        let profiles: [SpeechModel] = [.parakeetPhononLUT6, .parakeetPhononLUT3, .moonshineSmall]
        #expect(Set(SpeechModel.allCases).count == 9)
        for model in profiles {
            let encoded = try JSONEncoder().encode(model)
            #expect(try JSONDecoder().decode(SpeechModel.self, from: encoded) == model)
            #expect(model.languages == "English")
            #expect(!model.name.isEmpty && !model.downloadSize.isEmpty && !model.detail.isEmpty)
        }
        let lut3Detail = SpeechModel.parakeetPhononLUT3.detail
        #expect(lut3Detail.contains("Default in-app encoder requests CPU and GPU"))
        #expect(lut3Detail.contains("Action Button uses the same files on CPU"))
        #expect(SpeechModel.moonshineSmall.detail.contains("CPU"))
    }

    @Test func executionContextsPreserveAcceleratorChoicesAndReuseCPUModels() {
        for model in SpeechModel.allCases {
            #expect(ModelExecutionContext.foreground.normalized(for: model) == .foreground)
            if model == .parakeetRealtimeEOU || model == .moonshineSmall {
                #expect(ModelExecutionContext.backgroundCapable.normalized(for: model) == .foreground)
            } else {
                #expect(ModelExecutionContext.backgroundCapable.normalized(for: model) == .backgroundCapable)
            }
        }
        for model in [SpeechModel.parakeetUltra, .parakeetPhononLUT6] {
            #expect(model.detail.contains("Default in-app execution requests CPU and Neural Engine"))
            #expect(model.detail.contains("Action Button uses the same files on CPU"))
        }
    }
}
