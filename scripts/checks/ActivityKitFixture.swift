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
public struct ActivityAuthorizationInfo {
  public init() {}
  public var areActivitiesEnabled: Bool { true }
}
private enum Registry {
  static let lock = NSLock()
  nonisolated(unsafe) static var values: [AnyObject] = []
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
  private init(attributes: Attributes) { self.attributes = attributes }
  public static var activities: [Activity] { Registry.all(as: Activity.self) }
  public static func request(
    attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: String?
  ) throws -> Activity {
    let activity = Activity(attributes: attributes)
    Registry.add(activity)
    return activity
  }
  public func update(_ content: ActivityContent<Attributes.ContentState>) async {
    lock.withLock { updates.append(content.state) }
  }
  public func end(
    _ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy
  ) async {
    lock.withLock {
      ended = content
      policy = dismissalPolicy
    }
  }
  public var finalState: Attributes.ContentState? { lock.withLock { ended?.state } }
  public var dismissalPolicy: ActivityUIDismissalPolicy? { lock.withLock { policy } }
  public var updateStates: [Attributes.ContentState] { lock.withLock { updates } }
}
