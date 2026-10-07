import Combine
import CryptoKit
import Darwin
import Foundation
import LocalScribeCore
import Network
import Security

/// Foreground, manually enabled USB telemetry. Call stop() when the scene becomes inactive.
/// IPv4 loopback only: no Bonjour, LAN listener, persistence, or background execution.
@MainActor
final class DeveloperMetricsReceiver: ObservableObject {
  enum Status: String { case stopped, starting, waiting, connected, stale, failed }
  @Published private(set) var status: Status = .stopped
  @Published private(set) var pairingCode: String?
  @Published private(set) var latestSample: DeveloperMetricSample?
  @Published private(set) var lastSampleAt: Date?
  private var listener: NWListener?
  private var peer: NWConnection?
  private var secret: String?
  private var generation = UUID()
  private var peerID: UUID?
  private var buffer = DeveloperMetricsLineBuffer()
  private var authenticated = false
  private var sequence: UInt64?
  private var timeout: Task<Void, Never>?
  private let queue = DispatchQueue(label: "LocalScribe.developer-metrics", qos: .utility)

  func start() {
    stop()
    status = .starting
    var bytes = [UInt8](repeating: 0, count: 32)
    guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
      status = .failed
      return
    }
    secret = Self.base64URL(Data(bytes))
    let current = generation
    do {
      let parameters = NWParameters.tcp
      parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
      let listener = try NWListener(using: parameters)
      self.listener = listener
      listener.stateUpdateHandler = { [weak self] state in
        Task { @MainActor [weak self] in
          guard let self, self.generation == current else { return }
          switch state {
          case .ready:
            guard let port = self.listener?.port, let token = self.secret,
              let data = try? JSONSerialization.data(
                withJSONObject: ["version": 1, "port": Int(port.rawValue), "token": token],
                options: [.sortedKeys])
            else {
              self.fail()
              return
            }
            self.pairingCode = "LSM1-" + Self.base64URL(data)
            self.status = .waiting
          case .failed: self.fail()
          default: break
          }
        }
      }
      listener.newConnectionHandler = { [weak self] connection in
        Task { @MainActor [weak self] in
          guard let self, self.generation == current else {
            connection.cancel()
            return
          }
          self.accept(connection, generation: current)
        }
      }
      listener.start(queue: queue)
    } catch { fail() }
  }

  func stop() {
    generation = UUID()
    timeout?.cancel()
    timeout = nil
    peer?.cancel()
    peer = nil
    peerID = nil
    listener?.cancel()
    listener = nil
    secret = nil
    pairingCode = nil
    clearSample()
    status = .stopped
  }
  private func fail() {
    stop()
    status = .failed
  }
  private func clearSample() {
    latestSample = nil
    lastSampleAt = nil
    sequence = nil
  }
  private func accept(_ connection: NWConnection, generation: UUID) {
    guard peer == nil else {
      connection.cancel()
      return
    }
    peer = connection
    let id = UUID()
    peerID = id
    authenticated = false
    buffer = DeveloperMetricsLineBuffer()
    connection.stateUpdateHandler = { [weak self] state in
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation, self.peerID == id else { return }
        switch state {
        case .ready: self.receive(connection, generation: generation, id: id)
        case .failed, .cancelled: self.disconnect()
        default: break
        }
      }
    }
    // An unauthenticated peer cannot hold the single connection indefinitely.
    armTimeout(generation: generation, id: id, authentication: true)
    connection.start(queue: queue)
  }
  private func disconnect() {
    peerID = nil
    peer?.cancel()
    peer = nil
    timeout?.cancel()
    timeout = nil
    authenticated = false
    buffer = DeveloperMetricsLineBuffer()
    clearSample()
    status = listener == nil ? .stopped : .waiting
  }
  private func receive(_ connection: NWConnection, generation: UUID, id: UUID) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) {
      [weak self] data, _, complete, error in
      Task { @MainActor [weak self] in
        guard let self, self.generation == generation, self.peerID == id else { return }
        do {
          if let data {
            for line in try self.buffer.append(data) {
              if !self.authenticated {
                let supplied = try DeveloperMetricsProtocol.authenticationToken(line)
                guard let secret = self.secret, Self.equalSecrets(supplied, secret) else {
                  self.disconnect()
                  return
                }
                self.authenticated = true
                self.status = .connected
                connection.send(
                  content: Data("{\"type\":\"ready\",\"version\":1,\"appPID\":\(getpid())}\n".utf8),
                  completion: .contentProcessed { _ in })
              } else {
                let sample = try DeveloperMetricsProtocol.sample(line, after: self.sequence)
                self.sequence = sample.sequence
                self.latestSample = sample
                self.lastSampleAt = Date()
                self.status = .connected
              }
              self.armTimeout(generation: generation, id: id, authentication: false)
            }
          }
          if complete || error != nil {
            self.disconnect()
          } else {
            self.receive(connection, generation: generation, id: id)
          }
        } catch { self.disconnect() }
      }
    }
  }
  private func armTimeout(generation: UUID, id: UUID, authentication: Bool) {
    timeout?.cancel()
    timeout = Task { [weak self] in
      do { try await Task.sleep(for: .seconds(DeveloperMetricsProtocol.staleInterval)) } catch {
        return
      }
      guard let self, self.generation == generation, self.peerID == id else { return }
      if authentication {
        self.disconnect()
      } else {
        self.latestSample = nil
        self.status = .stale
      }
    }
  }
  private static func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
      of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
  }
  private static func equalSecrets(_ lhs: String, _ rhs: String) -> Bool {
    let a = SHA256.hash(data: Data(lhs.utf8))
    let b = SHA256.hash(data: Data(rhs.utf8))
    var difference: UInt8 = 0
    for (x, y) in zip(a, b) { difference |= x ^ y }
    return difference == 0
  }
}
