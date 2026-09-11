import Foundation

/// A bounded hand-off of query events from a driver's producer to the stream's consumer.
///
/// `AsyncThrowingStream`'s continuation never suspends the producer, so a driver that
/// yields as fast as the server delivers turns a million-row result into a million rows
/// in memory whatever the consumer does with them. This channel holds at most
/// `capacity` events; `send` waits when it is full, which is what pushes the wait back
/// to the socket (PostgreSQL's row sequence) or the statement (SQLite's `step`).
///
/// One producer, one consumer. The consumer reads through ``stream()``; cancelling that
/// stream's task wakes a waiting producer with `CancellationError`, so it stops sending.
public actor QueryEventChannel {
    /// Events a channel holds before `send` waits. Four batches of up to 500 rows or 1 MB
    /// (SPEC §4) is enough to keep a consumer busy and small enough to bound memory.
    public static let defaultCapacity = 4

    private let capacity: Int
    private var buffer: [QueryEvent] = []
    private var head = 0
    private var ended: Result<Void, any Error>?
    private var isCancelled = false
    private var waitingConsumer: CheckedContinuation<QueryEvent?, any Error>?
    private var waitingProducers: [CheckedContinuation<Void, any Error>] = []

    public init(capacity: Int = QueryEventChannel.defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    private var count: Int { buffer.count - head }

    /// Hands one event to the consumer, waiting while the channel is full.
    ///
    /// Throws `CancellationError` when the consumer has gone away; the producer should
    /// stop, and whatever it was reading from should be cancelled on the server.
    public func send(_ event: QueryEvent) async throws {
        if isCancelled { throw CancellationError() }
        guard ended == nil else { return }
        while count >= capacity, !isCancelled, ended == nil {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                waitingProducers.append(continuation)
            }
        }
        if isCancelled { throw CancellationError() }
        guard ended == nil else { return }
        // The consumer check comes after the wait, not before it: a consumer that started
        // waiting while this producer was suspended must be handed this event, and a
        // waiting consumer means the buffer is empty, so the order is kept.
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(returning: event)
            return
        }
        buffer.append(event)
    }

    /// Ends the channel. Events already buffered are still delivered; after them the
    /// consumer sees the end, or `error`.
    public func finish(throwing error: (any Error)? = nil) {
        guard ended == nil else { return }
        _ = producerFinished.trip()
        ended = error.map { .failure($0) } ?? .success(())
        if let consumer = waitingConsumer, count == 0 {
            waitingConsumer = nil
            deliverEnd(to: consumer)
        }
        wakeProducers(with: nil)
    }

    /// The consumer's side: the next event, or nil at the end. Throws what `finish` was
    /// given once the buffered events are gone.
    public func next() async throws -> QueryEvent? {
        if count > 0 {
            let event = buffer[head]
            head += 1
            if head >= 64, head * 2 >= buffer.count {
                buffer.removeFirst(head)
                head = 0
            }
            wakeProducers(with: nil)
            return event
        }
        if ended != nil {
            return try endValue()
        }
        if isCancelled { throw CancellationError() }
        return try await withCheckedThrowingContinuation { continuation in
            waitingConsumer = continuation
        }
    }

    /// The consumer has gone away. A waiting producer is woken with `CancellationError`,
    /// buffered events are dropped, and further `send`s fail at once.
    public func cancel() {
        isCancelled = true
        buffer.removeAll()
        head = 0
        wakeProducers(with: CancellationError())
        if let consumer = waitingConsumer {
            waitingConsumer = nil
            consumer.resume(throwing: CancellationError())
        }
    }

    /// A stream over this channel that pulls on demand. `onCancel` runs when the
    /// consumer's task is cancelled, after the channel itself has been cancelled.
    public nonisolated func stream(
        onCancel: @escaping @Sendable () -> Void = {}
    ) -> AsyncThrowingStream<QueryEvent, any Error> {
        // Two ways a consumer goes away: its task is cancelled while it waits in `next`
        // (the cancellation handler sees that), or it leaves the loop — `break`, a throw
        // in its body — and drops the stream, which the throwing stream has no callback
        // for. The lifetime object is owned by the stream's pull closure and released
        // with it, so its deinit is that callback. Both paths run the same code once, and
        // neither cancels anything when the producer had already finished.
        let fired = OnceFlag()
        let producerDone = producerFinished
        let end: @Sendable () -> Void = { [self] in
            guard fired.trip(), !producerDone.isSet else { return }
            Task { await self.cancel() }
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

    /// Set by `finish`, readable without the actor, so a dropped stream knows whether
    /// there is still a statement to cancel.
    private nonisolated let producerFinished = OnceFlag()

    /// Trips once, from any thread.
    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var tripped = false
        /// True the first time only.
        func trip() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if tripped { return false }
            tripped = true
            return true
        }
        var isSet: Bool {
            lock.lock()
            defer { lock.unlock() }
            return tripped
        }
    }

    /// Runs `onEnd` when the stream that owns it is released.
    private final class StreamLifetime: Sendable {
        private let onEnd: @Sendable () -> Void
        init(onEnd: @escaping @Sendable () -> Void) { self.onEnd = onEnd }
        deinit { onEnd() }
    }

    private func endValue() throws -> QueryEvent? {
        switch ended {
        case .success, .none: return nil
        case let .failure(error): throw error
        }
    }

    private func deliverEnd(to consumer: CheckedContinuation<QueryEvent?, any Error>) {
        switch ended {
        case .success, .none: consumer.resume(returning: nil)
        case let .failure(error): consumer.resume(throwing: error)
        }
    }

    private func wakeProducers(with error: (any Error)?) {
        guard !waitingProducers.isEmpty else { return }
        let waiting = waitingProducers
        waitingProducers.removeAll()
        for producer in waiting {
            if let error { producer.resume(throwing: error) } else { producer.resume() }
        }
    }
}
