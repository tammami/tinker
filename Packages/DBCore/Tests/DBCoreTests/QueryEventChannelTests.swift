import XCTest

@testable import DBCore

/// The bounded hand-off between a driver and the consumer of its stream: the producer
/// waits when the channel is full, the consumer sees every event in order, an error
/// arrives after the events before it, and a cancelled consumer stops the producer.
final class QueryEventChannelTests: XCTestCase {
    func testEventsArriveInOrderAndTheEndFollowsThem() async throws {
        let channel = QueryEventChannel(capacity: 2)
        let producer = Task {
            for index in 0 ..< 5 { try await channel.send(makeBatch(index)) }
            await channel.finish()
        }
        var seen: [Int] = []
        for try await event in channel.stream() {
            if case let .rows(rows) = event { seen.append(rows.startIndex) }
        }
        try await producer.value
        XCTAssertEqual(seen, [0, 1, 2, 3, 4])
    }

    func testTheProducerWaitsWhileTheChannelIsFull() async throws {
        let channel = QueryEventChannel(capacity: 2)
        let sent = Counter()
        let producer = Task {
            for index in 0 ..< 10 {
                try await channel.send(makeBatch(index))
                sent.increment()
            }
            await channel.finish()
        }
        // Nobody reads: the producer gets as far as the capacity and no further.
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(sent.value, 2, "two events fit; the third send must wait for a reader")

        var received = 0
        for try await _ in channel.stream() { received += 1 }
        try await producer.value
        XCTAssertEqual(received, 10)
        XCTAssertEqual(sent.value, 10)
    }

    func testAnErrorIsDeliveredAfterTheEventsBeforeIt() async throws {
        struct ServerSaidNo: Error {}
        let channel = QueryEventChannel(capacity: 8)
        try await channel.send(makeBatch(0))
        try await channel.send(makeBatch(1))
        await channel.finish(throwing: ServerSaidNo())

        var seen = 0
        do {
            for try await _ in channel.stream() { seen += 1 }
            XCTFail("expected the error after the two events")
        } catch is ServerSaidNo {}
        XCTAssertEqual(seen, 2)
    }

    func testCancellingTheConsumerWakesAWaitingProducer() async throws {
        let channel = QueryEventChannel(capacity: 1)
        let producerStopped = Counter()
        let producer = Task {
            do {
                for index in 0 ..< 1_000 { try await channel.send(makeBatch(index)) }
            } catch is CancellationError {
                producerStopped.increment()
            }
        }
        let cancelSeen = Counter()
        let consumer = Task {
            for try await _ in channel.stream(onCancel: { cancelSeen.increment() }) {
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        try await Task.sleep(for: .milliseconds(60))
        consumer.cancel()
        _ = try? await consumer.value
        _ = await producer.result

        XCTAssertEqual(producerStopped.value, 1, "the producer must be told the consumer is gone")
        XCTAssertEqual(cancelSeen.value, 1)
    }

    /// A consumer that leaves the loop early — the grid's memory cap, a `break` — drops
    /// the stream without cancelling its task. The producer has to notice all the same.
    func testDroppingTheStreamMidWayStopsTheProducer() async throws {
        let channel = QueryEventChannel(capacity: 1)
        let producerStopped = Counter()
        let producer = Task {
            do {
                for index in 0 ..< 1_000 { try await channel.send(makeBatch(index)) }
            } catch is CancellationError {
                producerStopped.increment()
            }
        }
        let cancelSeen = Counter()
        var read = 0
        for try await _ in channel.stream(onCancel: { cancelSeen.increment() }) {
            read += 1
            if read == 3 { break }
        }
        _ = await producer.result
        XCTAssertEqual(read, 3)
        XCTAssertEqual(producerStopped.value, 1)
        XCTAssertEqual(cancelSeen.value, 1)
    }

    /// When the producer has already finished, dropping the stream cancels nothing:
    /// there is no statement left to stop on the server.
    func testDroppingTheStreamAfterTheProducerFinishedDoesNotCancel() async throws {
        let channel = QueryEventChannel(capacity: 8)
        try await channel.send(makeBatch(0))
        try await channel.send(makeBatch(1))
        await channel.finish()
        let cancelSeen = Counter()
        for try await _ in channel.stream(onCancel: { cancelSeen.increment() }) { break }
        XCTAssertEqual(cancelSeen.value, 0)
    }

    func testSendAfterFinishIsIgnoredAndNextAfterEndStaysAtTheEnd() async throws {
        let channel = QueryEventChannel()
        await channel.finish()
        try await channel.send(makeBatch(0))
        let first = try await channel.next()
        let second = try await channel.next()
        XCTAssertNil(first)
        XCTAssertNil(second)
    }
}

/// One batch holding one row, numbered so order is observable.
private func makeBatch(_ index: Int) -> QueryEvent {
    .rows(RowBatch(rows: [[.int(Int64(index))]], startIndex: index))
}

/// A counter tests can bump from any task.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
}
