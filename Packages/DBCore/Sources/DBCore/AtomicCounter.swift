import Foundation

/// A counter that can be changed from any thread, for bookkeeping that starts outside
/// an actor and is read inside it.
///
/// A driver counts a cancel here the moment a consumer drops its stream, before the
/// cancel has hopped onto the connection's actor; a statement that starts in that gap
/// sees the count and waits, so the cancel cannot land on it.
public final class AtomicCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    public init() {}

    /// The current count.
    public var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    public func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    public func decrement() {
        lock.lock()
        count -= 1
        lock.unlock()
    }
}
