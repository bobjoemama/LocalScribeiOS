import Foundation

// ActivityKit is unavailable in the command-line macOS test environment. This
// fixture records only its platform boundary; production lifecycle code is used.
public protocol ActivityAttributes {
  associatedtype ContentState: Codable, Hashable
}
public struct ActivityContent<State: Codable & Hashable> {
  public let state: State
  public init(state: State, staleDate: Date?) { self.state = state }
}
public enum ActivityUIDismissalPolicy: Equatable {
  case immediate
  case after(Date)
}
public enum ActivityState {
  case active, stale, ended, dismissed
}
public struct ActivityAuthorizationInfo {
  public init() {}
  public var areActivitiesEnabled: Bool { true }
}
public actor ActivityEndGate {
  public static let shared = ActivityEndGate()
  private var holdNext = false
  private var continuation: CheckedContinuation<Void, Never>?
  public func holdNextEnd() { holdNext = true }
  public func isHeld() -> Bool { continuation != nil }
  public func release() { continuation?.resume(); continuation = nil }
  func wait() async {
    guard holdNext else { return }
    holdNext = false
    await withCheckedContinuation { continuation = $0 }
  }
}
private enum Registry {
  static let lock = NSLock()
  nonisolated(unsafe) static var values: [AnyObject] = []
  nonisolated(unsafe) static var requestsAllowed = true
  static func add(_ value: AnyObject) { lock.withLock { values.append(value) } }
  static func all<T: AnyObject>(as type: T.Type) -> [T] {
    lock.withLock { values.compactMap { $0 as? T } }
  }
}
public final class Activity<Attributes: ActivityAttributes>: @unchecked Sendable {
  public let id = UUID().uuidString
  public let attributes: Attributes
  private let lock = NSLock()
  private var updates: [Attributes.ContentState] = []
  private var ended: ActivityContent<Attributes.ContentState>?
  private var policy: ActivityUIDismissalPolicy?
  private var changed = false
  private var state = ActivityState.active
  private var changeWaiters: [CheckedContinuation<Void, Never>] = []
  private init(attributes: Attributes) { self.attributes = attributes }
  public static var activities: [Activity] { Registry.all(as: Activity.self) }
  public static var requestsAllowed: Bool {
    get { Registry.lock.withLock { Registry.requestsAllowed } }
    set { Registry.lock.withLock { Registry.requestsAllowed = newValue } }
  }
  public static func request(
    attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: String?
  ) throws -> Activity {
    guard requestsAllowed else { throw NSError(domain: "ActivityFixture", code: 1) }
    let activity = Activity(attributes: attributes)
    Registry.add(activity)
    return activity
  }
  public var activityState: ActivityState { lock.withLock { state } }
  public func simulateSystemState(_ state: ActivityState) { lock.withLock { self.state = state } }
  public func update(_ content: ActivityContent<Attributes.ContentState>) async {
    let waiters = lock.withLock {
      updates.append(content.state)
      changed = true
      let waiters = changeWaiters
      changeWaiters = []
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }
  public func end(
    _ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy
  ) async {
    await ActivityEndGate.shared.wait()
    let waiters = lock.withLock {
      ended = content
      policy = dismissalPolicy
      state = .ended
      changed = true
      let waiters = changeWaiters
      changeWaiters = []
      return waiters
    }
    for waiter in waiters { waiter.resume() }
  }
  /// A platform update or end is the milestone, not a scheduler delay.
  public func waitForChange() async {
    await withCheckedContinuation { continuation in
      let resumeNow = lock.withLock {
        if changed { return true }
        changeWaiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
  }
  public var finalState: Attributes.ContentState? { lock.withLock { ended?.state } }
  public var dismissalPolicy: ActivityUIDismissalPolicy? { lock.withLock { policy } }
  public var updateStates: [Attributes.ContentState] { lock.withLock { updates } }
}
