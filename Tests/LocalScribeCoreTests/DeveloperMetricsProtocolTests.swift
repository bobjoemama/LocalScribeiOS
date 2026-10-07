import Foundation
import Testing

@testable import LocalScribeCore

struct DeveloperMetricsProtocolTests {
  private func data(_ text: String) -> Data { Data(text.utf8) }
  @Test func testFragmentedAndBatchedLines() throws {
    var buffer = DeveloperMetricsLineBuffer()
    #expect(try buffer.append(data("{\"type\":")).isEmpty)
    #expect(
      try buffer.append(data("\"sample\"}\n{}\n")) == [data("{\"type\":\"sample\"}"), data("{}")])
  }
  @Test func testLineLimitIncludesNewline() throws {
    var buffer = DeveloperMetricsLineBuffer()
    #expect(
      try buffer.append(Data(repeating: 32, count: 65_535) + data("\n")).first?.count == 65_535)
    #expect(throws: (any Error).self) { try buffer.append(Data(repeating: 32, count: 65_536)) }
  }
  @Test func testAllowedNumbersNullAndSequence() throws {
    let sample = try DeveloperMetricsProtocol.sample(
      data(
        "{\"type\":\"sample\",\"version\":1,\"sequence\":2,\"appCPUPercent\":340,\"systemCPUCoresPercent\":[0,null,100],\"gpuDevicePercent\":null,\"appMemoryBytes\":18446744073709551615}"
      ), after: 1)
    #expect(sample.appCPUPercent == 340)
    #expect(sample.systemCPUCoresPercent! == [0, nil, 100])
    #expect(sample.appMemoryBytes == UInt64.max)
    #expect(throws: (any Error).self) {
      try DeveloperMetricsProtocol.sample(
        data("{\"type\":\"sample\",\"version\":1,\"sequence\":2}"), after: 2)
    }
  }
  @Test func testRejectsUnknownIdentityAndInvalidNumericFields() {
    for extra in [
      "\"pid\":12", "\"gpuDevicePercent\":101", "\"systemCPUPercent\":-1", "\"displayFPS\":-1",
      "\"appCPUPercent\":true", "\"appMemoryBytes\":-1", "\"systemCPUCoresPercent\":[101]",
    ] {
      #expect(throws: (any Error).self) {
        try DeveloperMetricsProtocol.sample(
          data("{\"type\":\"sample\",\"version\":1,\"sequence\":1,\(extra)}"), after: nil)
      }
    }
    #expect(throws: (any Error).self) {
      try DeveloperMetricsProtocol.sample(
        data("{\"type\":\"sample\",\"version\":2,\"sequence\":1}"), after: nil)
    }
  }
  @Test func testAuthenticationStrictKeysAndLength() throws {
    let token = String(repeating: "a", count: 43)
    #expect(
      try DeveloperMetricsProtocol.authenticationToken(
        data("{\"type\":\"authenticate\",\"token\":\"\(token)\"}")) == token)
    #expect(throws: (any Error).self) {
      try DeveloperMetricsProtocol.authenticationToken(
        data("{\"type\":\"authenticate\",\"token\":\"\(token)\",\"pid\":1}"))
    }
    #expect(throws: (any Error).self) {
      try DeveloperMetricsProtocol.authenticationToken(
        data("{\"type\":\"authenticate\",\"token\":\"short\"}"))
    }
  }
}
