import Foundation
import Testing
@testable import LocalScribeCore

struct ProfilingReportTests {
    private func bytes(_ activity: String = "{\"activeMs\":500,\"dutyCyclePercent\":50}", extra: String = "") -> Data {
        Data("{\"schemaVersion\":1,\"provenance\":\"trace-based (offline)\",\"durationMs\":1000,\"windowStartMs\":0,\"ane\":\(activity),\"gpu\":null,\"countersUnavailable\":[],\"sourceSchemas\":[\"ane-hw-intervals\"],\"scope\":\"trace-wide; not attributed to LocalScribe\"\(extra)}".utf8)
    }
    @Test func validRecordedActivity() throws {
        let value = try ProfilingReport.decode(bytes())
        #expect(value.ane?.activeMs == 500)
        #expect(value.ane?.dutyCyclePercent == 50)
    }
    @Test func inconsistentDutyCycleIsRejected() {
        #expect(throws: (any Error).self) { try ProfilingReport.decode(bytes("{\"activeMs\":500,\"dutyCyclePercent\":95}")) }
    }
    @Test func unknownFieldsAndUnattributedResultsAreRejected() {
        #expect(throws: (any Error).self) { try ProfilingReport.decode(bytes(extra: ",\"deviceID\":\"private\"")) }
        #expect(throws: (any Error).self) { try ProfilingReport.decode(bytes("{\"activeMs\":500,\"dutyCyclePercent\":50,\"appPID\":42}")) }
    }
    @Test func negativeAndMissingActivityIsRejected() {
        #expect(throws: (any Error).self) { try ProfilingReport.decode(bytes("{\"activeMs\":-1,\"dutyCyclePercent\":-0.1}")) }
        #expect(throws: (any Error).self) { try ProfilingReport.decode(bytes("null")) }
    }
    @Test func unsupportedSchemaIsRejected() {
        let data = Data(String(decoding: bytes(), as: UTF8.self).replacingOccurrences(of: "ane-hw-intervals", with: "model-submission-times").utf8)
        #expect(throws: (any Error).self) { try ProfilingReport.decode(data) }
    }
}
