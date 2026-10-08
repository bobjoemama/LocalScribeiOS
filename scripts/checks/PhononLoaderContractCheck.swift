import CoreML
import Foundation
import LocalScribeCore

enum FixtureLoaderFailure: Error { case requested }
actor FixtureLoaderLedger {
    static let shared = FixtureLoaderLedger()
    private var active = 0
    private(set) var maximumConcurrent = 0
    private(set) var requests: [String] = []
    private var failingName: String?
    func reset(failingName: String? = nil) {
        precondition(active == 0)
        maximumConcurrent = 0; requests = []; self.failingName = failingName
    }
    func begin(_ name: String) -> Bool {
        active += 1; maximumConcurrent = max(maximumConcurrent, active)
        requests.append(name)
        return name == failingName
    }
    func finish() { active -= 1 }
}
actor FixtureLoadGate {
    private(set) var reached = false
    private var waiter: CheckedContinuation<Void, Never>?
    func observe(_ progress: EnginePreparationProgress) async {
        guard progress.phase == .encoderLoad, progress.completedComponents == 1 else { return }
        await withCheckedContinuation { continuation in
            waiter = continuation
            reached = true
        }
    }
    func open() { waiter?.resume(); waiter = nil }
}

enum PhononLoaderContractCheck {
    static func run(directory: URL) async throws -> Int {
        var count = 0
        func check(_ result: @autoclosure () -> Bool, _ label: String) {
            precondition(result(), label)
            count += 1
        }
        let execution = LocalModelExecutionConfiguration(model: .parakeetPhonon, context: .backgroundCapable)
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly
        let ledger = FixtureLoaderLedger.shared
        let ctcFile = directory.appendingPathComponent(ModelNames.ASR.ctcHeadFile)
        try Data().write(to: ctcFile)
        await ledger.reset()
        var timer = FixturePreparationTimer()
        let progress = FixtureProgressRecorder()
        let withCTC = try await EngineContextFixture.loadPhonon(directory: directory, execution: execution, configuration: config, timer: &timer) {
            await progress.append($0)
        }
        check(withCTC.ctcHead?.units == .cpuOnly, "optional CTC uses requested CPU units")
        check(withCTC.vocabulary == [0: "one", 1: "two", 2: "three", 3: "four"], "vocabulary map retained")
        let requests = await ledger.requests
        check(requests == ["Encoder.mlmodelc", "CtcHead.mlmodelc", "Preprocessor.mlmodelc", "Decoder.mlmodelc", "JointDecisionv3.mlmodelc"], "optional CTC preserves pinned load order and names")
        let concurrent = await ledger.maximumConcurrent
        check(concurrent == 1, "large components load sequentially")
        let updates = await progress.updates
        check(updates.last?.completedComponents == 6 && updates.allSatisfy { $0.totalComponents == 6 }, "optional CTC included in truthful total")
        check(timer.phases == [.vocabularyLoad, .encoderLoad, .ctcHeadLoad, .preprocessorLoad, .decoderLoad, .jointLoad], "optional CTC has separate timing phase")
        try FileManager.default.removeItem(at: ctcFile)

        // Missing or invalid vocabulary must fail before any model constructor.
        let vocabularyFile = directory.appendingPathComponent(ModelNames.ASR.vocabularyFile)
        let vocabularyData = try Data(contentsOf: vocabularyFile)
        for data in [Data(#"{"0":"one"}"#.utf8), Data("invalid JSON".utf8)] {
            try data.write(to: vocabularyFile)
            await ledger.reset()
            var invalidTimer = FixturePreparationTimer()
            do {
                _ = try await EngineContextFixture.loadPhonon(directory: directory, execution: execution, configuration: config, timer: &invalidTimer) { _ in }
                preconditionFailure("invalid vocabulary must throw")
            } catch { count += 1 }
            let requests = await ledger.requests
            check(requests.isEmpty, "invalid vocabulary never loads a model")
        }
        // The pinned vocabulary parser accepts arrays and ignores nonnumeric
        // dictionary keys; neither representation changes the token ID mapping.
        for data in [Data(#"["one","two","three","four"]"#.utf8), Data(#"{"0":"one","1":"two","2":"three","3":"four","ignored":"metadata"}"#.utf8)] {
            try data.write(to: vocabularyFile)
            var formatTimer = FixturePreparationTimer()
            let models = try await EngineContextFixture.loadPhonon(directory: directory, execution: execution, configuration: config, timer: &formatTimer) { _ in }
            check(models.vocabulary == [0: "one", 1: "two", 2: "three", 3: "four"], "pinned supported vocabulary formats retain exact map")
        }
        try FileManager.default.removeItem(at: vocabularyFile)
        var missingVocabularyTimer = FixturePreparationTimer()
        do {
            _ = try await EngineContextFixture.loadPhonon(directory: directory, execution: execution, configuration: config, timer: &missingVocabularyTimer) { _ in }
            preconditionFailure("missing vocabulary must throw")
        } catch AsrModelsError.modelNotFound(let name, let url) {
            check(name == "parakeet_vocab.json" && url == vocabularyFile, "pinned missing-vocabulary error retained")
        }
        try vocabularyData.write(to: vocabularyFile)

        // Required component absence and Core ML errors propagate without fallback.
        let decoderFile = directory.appendingPathComponent(ModelNames.ASR.decoderFile)
        try FileManager.default.removeItem(at: decoderFile)
        await ledger.reset()
        var missingTimer = FixturePreparationTimer()
        do {
            _ = try await EngineContextFixture.loadPhonon(directory: directory, execution: execution, configuration: config, timer: &missingTimer) { _ in }
            preconditionFailure("missing decoder must throw")
        } catch AsrModelsError.modelNotFound(let name, let url) {
            check(name == "Decoder.mlmodelc" && url == decoderFile, "pinned missing-component error is preserved")
        }
        let beforeMissing = await ledger.requests
        check(beforeMissing == ["Encoder.mlmodelc", "Preprocessor.mlmodelc"], "required component failure stops loading")
        try Data().write(to: decoderFile)
        await ledger.reset(failingName: "Decoder.mlmodelc")
        var failedTimer = FixturePreparationTimer()
        let failedProgress = FixtureProgressRecorder()
        do {
            _ = try await EngineContextFixture.loadPhonon(directory: directory, execution: execution, configuration: config, timer: &failedTimer) {
                await failedProgress.append($0)
            }
            preconditionFailure("Core ML load error must throw")
        } catch FixtureLoaderFailure.requested { count += 1 }
        let failedUpdates = await failedProgress.updates
        check(failedUpdates.last == .init(phase: .decoderLoad, completedComponents: 3, totalComponents: 5), "failed decoder never advances completed count")
        let beforeFailure = await ledger.requests
        check(beforeFailure == ["Encoder.mlmodelc", "Preprocessor.mlmodelc", "Decoder.mlmodelc"], "Core ML error stops before joint")

        // Cancellation delivered while component progress is being published
        // stops the next constructor and leaves the completed count unchanged.
        await ledger.reset()
        let gate = FixtureLoadGate()
        let task = Task {
            var timer = FixturePreparationTimer()
            let taskConfiguration = MLModelConfiguration()
            taskConfiguration.computeUnits = .cpuOnly
            _ = try await EngineContextFixture.loadPhonon(directory: directory, execution: execution, configuration: taskConfiguration, timer: &timer) {
                await gate.observe($0)
            }
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while !(await gate.reached), ContinuousClock.now < deadline { await Task.yield() }
        let reached = await gate.reached
        check(reached, "controlled cancellation gate reached")
        task.cancel()
        await gate.open()
        do {
            _ = try await task.value
            preconditionFailure("cancelled component load must throw")
        } catch is CancellationError { count += 1 }
        let afterCancellation = await ledger.requests
        check(afterCancellation.isEmpty, "cancellation prevents Core ML submission")
        return count
    }
}
