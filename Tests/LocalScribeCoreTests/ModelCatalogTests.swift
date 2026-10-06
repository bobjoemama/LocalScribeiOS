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
        #expect(SpeechModel.parakeetPhononLUT3.detail.contains("foreground"))
        #expect(SpeechModel.moonshineSmall.detail.contains("CPU"))
    }
}
