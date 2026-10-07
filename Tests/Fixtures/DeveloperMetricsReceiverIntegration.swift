import Foundation
import Network

@main struct Check {
  @MainActor static func main() async throws {
    let receiver = DeveloperMetricsReceiver()
    receiver.start()
    for _ in 0..<100 {
      if receiver.pairingCode != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    guard let code = receiver.pairingCode else { fatalError("listener not ready") }
    var encoded = String(code.dropFirst(5)).replacingOccurrences(of: "-", with: "+")
      .replacingOccurrences(of: "_", with: "/")
    encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
    let config =
      try JSONSerialization.jsonObject(with: Data(base64Encoded: encoded)!) as! [String: Any]
    let connection = NWConnection(
      host: "127.0.0.1", port: NWEndpoint.Port(rawValue: UInt16(config["port"] as! Int))!,
      using: .tcp)
    connection.start(queue: DispatchQueue(label: "fixture"))
    let auth = try JSONSerialization.data(withJSONObject: [
      "type": "authenticate", "token": config["token"]!,
    ])
    connection.send(
      content: auth
        + Data(
          "\n{\"type\":\"sample\",\"version\":1,\"sequence\":1,\"gpuDevicePercent\":43,\"appCPUPercent\":240}\n"
            .utf8), completion: .contentProcessed { _ in })
    let reply: Data? = await withCheckedContinuation { continuation in
      connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { data, _, _, _ in
        continuation.resume(returning: data)
      }
    }
    guard String(data: reply ?? Data(), encoding: .utf8)?.contains("ready") == true else {
      fatalError("auth ack failed")
    }
    for _ in 0..<100 {
      if receiver.latestSample != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    precondition(receiver.latestSample?.gpuDevicePercent == 43)
    precondition(receiver.latestSample?.appCPUPercent == 240)
    for _ in 0..<700 {
      if receiver.status == .stale { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    precondition(
      receiver.status == .stale && receiver.latestSample == nil && receiver.lastSampleAt != nil)
    connection.send(
      content: Data("{\"type\":\"sample\",\"version\":1,\"sequence\":2,\"displayFPS\":60}\n".utf8),
      completion: .contentProcessed { _ in })
    for _ in 0..<100 {
      if receiver.latestSample != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    precondition(receiver.status == .connected && receiver.latestSample?.displayFPS == 60)
    connection.cancel()
    for _ in 0..<100 {
      if receiver.status == .waiting { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    precondition(receiver.latestSample == nil && receiver.lastSampleAt == nil)
    let previous = receiver.pairingCode
    receiver.stop()
    receiver.start()
    for _ in 0..<100 {
      if receiver.pairingCode != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    precondition(receiver.pairingCode != previous)
    receiver.stop()
    precondition(receiver.pairingCode == nil && receiver.status == .stopped)
    print(
      "Loopback listener/authentication/ack/sample/stale/recovery/disconnect/session rotation passed"
    )
  }
}
