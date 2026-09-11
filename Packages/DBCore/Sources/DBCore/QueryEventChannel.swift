import Foundation

/// A bounded hand-off of query events from a driver's producer to the stream's consumer.
///
/// `AsyncThrowingStream`'s continuation never suspends the producer, so a driver that
/// yields as fast as the server delivers turns a million-row result into a million rows
/// in memory whatever the consumer does with them. This channel holds at most
/// `capacity` events; `send` waits when it is full, which is what pushes the wait back
/// to the socket (PostgreSQL's row sequence) or the statement (SQLite's `step`).
///
/// A producer that cannot wait — mysql-nio's row callback runs on the event loop —
/// uses ``offer(_:)`` instead, which never suspends and answers whether the channel is
/// now full; the producer then stops reading its socket and resumes when ``onDemand``
/// says there is room again (ADR-0047).
///
/// One producer, one consumer. The consumer reads through ``stream()``; cancelling that
/// stream's task, or dropping the stream, wakes a waiting producer with
/// `CancellationError`, so it stops sending. Lock-based rather than an actor so the
/// non-suspending entry points can be called from an event loop.
public final class QueryEventChannel: @unchecked Sendable {
    /// Events a channel holds before `send` waits. Four batches of up to 500 rows or 1 MB
    /// (SPEC §4) is enough to keep a consumer busy and small enough to bound memory.
    public static let defaultCapacity = 4

    private let capacity: Int
    private let lock = NSLock()
    private var buffer: [QueryEvent] = []
    private var head = 0
    private var ended: Result<Void, any Error>?
    private var isCancelled = false
    private var waitingConsumer: CheckedContinuation<QueryEvent?, any Error>?
    private var waitingProducers: [CheckedContinuation<Void, any Error>] = []
    private var demandCallback: (@Sendable () -> Void)?
    private var producerFinished = false

    public init(capacity: Int = QueryEventChannel.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    private var count: Int { buffer.count - head }

    /// Called, off the lock, when the consumer took an event from a full channel: the
    /// producer that stopped reading may read again.
    public var onDemand: (@Sendable () -> Void)? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return demandCallback
        }
        set {
            lock.lock()
            demandCallback = newValue
            lock.unlock()
        }
    }

    /// True when the channel holds `capacity` events or more.
    public var isFull: Bool {
        lock.lock()
        defer { lock.unlock() }
        return count >= capacity
    }

    // MARK: - Producer

    /// Hands one event to the consumer, waiting while the channel is full.
    ///
    /// Throws `CancellationError` when the consumer has gone away; the producer should
    /// stop, and whatever it was reading from should be cancelled on the server.
    public func send(_ event: QueryEvent) async throws {
        // The lock is only ever taken in synchronous helpers: `NSLock` may not be held
        // across a suspension, and the compiler refuses it in an async body outright.
        while true {
            switch trySend(event) {
            case .sent: return
            case .cancelled: throw CancellationError()
            case .full:
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    parkProducer(continuation)
                }
            }
        }
    }

    private enum SendOutcome { case sent, cancelled, full }

    private func trySend(_ event: QueryEvent) -> SendOutcome {
        lock.lock()
        if isCancelled {
            lock.unlock()
            return .cancelled
        }
        if ended != nil {
            lock.unlock()
            return .sent
        }
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            lock.unlock()
            consumer.resume(returning: event)
            return .sent
        }
        if count < capacity {
            buffer.append(event)
            lock.unlock()
            return .sent
        }
        lock.unlock()
        return .full
    }

    /// Parks a producer until there is room, unless room or a cancel arrived between
    /// its `trySend` and now, in which case it is woken at once.
    private func parkProducer(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else if ended != nil || count < capacity || waitingConsumer != nil {
            lock.unlock()
            continuation.resume()
        } else {
            waitingProducers.append(continuation)
            lock.unlock()
        }
    }

    /// Hands one event over without waiting, for a producer that cannot suspend.
    /// Returns true when the channel is now full and the producer should stop reading
    /// until ``onDemand`` fires. Ignored after `finish`; false after `cancel`, with the
    /// event dropped, so the producer should also check ``isCancelledByConsumer``.
    @discardableResult
    public func offer(_ event: QueryEvent) -> Bool {
        lock.lock()
        if isCancelled || ended != nil {
            lock.unlock()
            return false
        }
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            lock.unlock()
            consumer.resume(returning: event)
            return false
        }
        buffer.append(event)
        let full = count >= capacity
        lock.unlock()
        return full
    }

    /// True once the consumer has gone away.
    public var isCancelledByConsumer: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    /// Ends the channel. Events already buffered are still delivered; after them the
    /// consumer sees the end, or `error`.
    public func finish(throwing error: (any Error)? = nil) {
        lock.lock()
        guard ended == nil else {
            lock.unlock()
            return
        }
        producerFinished = true
        ended = error.map { .failure($0) } ?? .success(())
        let consumer = count == 0 ? waitingConsumer : nil
        if consumer != nil { waitingConsumer = nil }
        let producers = waitingProducers
        waitingProducers.removeAll()
        let end = ended
        lock.unlock()
        for producer in producers { producer.resume() }
        if let consumer { Self.deliver(end, to: consumer) }
    }

    // MARK: - Consumer

    /// The consumer's side: the next event, or nil at the end. Throws what `finish` was
    /// given once the buffered events are gone.
    public func next() async throws -> QueryEvent? {
        switch tryNext() {
        case let .event(event): return event
        case let .ended(result): return try Self.endValue(result)
        case .cancelled: throw CancellationError()
        case .empty:
            return try await withCheckedThrowingContinuation { continuation in parkConsumer(continuation) }
        }
    }

    private enum NextOutcome {
        case event(QueryEvent)
        case ended(Result<Void, any Error>)
        case cancelled
        case empty
    }

    private func tryNext() -> NextOutcome {
        lock.lock()
        if count > 0 {
            let event = buffer[head]
            head += 1
            if head >= 64, head * 2 >= buffer.count {
                buffer.removeFirst(head)
                head = 0
            }
            let producers = waitingProducers
            waitingProducers.removeAll()
            let demand = count == capacity - 1 ? demandCallback : nil
            lock.unlock()
            for producer in producers { producer.resume() }
            demand?()
            return .event(event)
        }
        if let ended {
            lock.unlock()
            return .ended(ended)
        }
        if isCancelled {
            lock.unlock()
            return .cancelled
        }
        lock.unlock()
        return .empty
    }

    /// Parks the consumer until an event arrives, unless one arrived — or the end, or a
    /// cancel — between its `tryNext` and now, in which case it is answered at once.
    private func parkConsumer(_ continuation: CheckedContinuation<QueryEvent?, any Error>) {
        lock.lock()
        if count > 0 {
            lock.unlock()
            // Re-run the take under the lock through `tryNext` so producers are woken.
            switch tryNext() {
            case let .event(event): continuation.resume(returning: event)
            case let .ended(result): Self.deliver(result, to: continuation)
            case .cancelled: continuation.resume(throwing: CancellationError())
            case .empty: parkConsumer(continuation)
            }
        } else if let ended {
            lock.unlock()
            Self.deliver(ended, to: continuation)
        } else if isCancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
        } else {
            waitingConsumer = continuation
            lock.unlock()
        }
    }

    /// The consumer has gone away. A waiting producer is woken with `CancellationError`,
    /// buffered events are dropped, and further `send`s fail at once.
    public func cancel() {
        lock.lock()
        isCancelled = true
        buffer.removeAll()
        head = 0
        let producers = waitingProducers
        waitingProducers.removeAll()
        let consumer = waitingConsumer
        waitingConsumer = nil
        let demand = demandCallback
        lock.unlock()
        for producer in producers { producer.resume(throwing: CancellationError()) }
        consumer?.resume(throwing: CancellationError())
        // A producer that stopped reading must wake to notice the cancel.
        demand?()
    }

    /// A stream over this channel that pulls on demand. `onCancel` runs once when the
    /// consumer's task is cancelled or the stream is dropped before the producer
    /// finished, after the channel itself has been cancelled.
    public func stream(
        onCancel: @escaping @Sendable () -> Void = {}
    ) -> AsyncThrowingStream<QueryEvent, any Error> {
        // Two ways a consumer goes away: its task is cancelled while it waits in `next`
        // (the cancellation handler sees that), or it leaves the loop — `break`, a throw
        // in its body — and drops the stream, which the throwing stream has no callback
        // for. The lifetime object is owned by the stream's pull closure and released
        // with it, so its deinit is that callback. Both paths run the same code once, and
        // neither cancels anything when the producer had already finished.
        let fired = OnceFlag()
        let end: @Sendable () -> Void = { [self] in
            guard fired.trip(), !hasProducerFinished else { return }
            cancel()
            onCancel()
        }
        let lifetime = StreamLifetime(onEnd: end)
        return AsyncThrowingStream(unfolding: { [self] in
            _ = lifetime
            return try await withTaskCancellationHandler {
                try await self.next()
            } onCancel: {
                end()
            }
        })
    }

    private var hasProducerFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return producerFinished
    }

    private static func endValue(_ ended: Result<Void, any Error>) throws -> QueryEvent? {
        switch ended {
        case .success: return nil
        case let .failure(error): throw error
        }
    }

    private static func deliver(_ ended: Result<Void, any Error>?, to consumer: CheckedContinuation<QueryEvent?, any Error>) {
        switch ended {
        case .success, .none: consumer.resume(returning: nil)
        case let .failure(error): consumer.resume(throwing: error)
        }
    }

    /// Trips once, from any thread.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false
        func trip() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if tripped { return false }
            tripped = true
            return true
        }
    }

    /// Runs `onEnd` when the stream that owns it is released.
    private final class StreamLifetime: Sendable {
        private let onEnd: @Sendable () -> Void
        init(onEnd: @escaping @Sendable () -> Void) { self.onEnd = onEnd }
        deinit { onEnd() }
    }
}
