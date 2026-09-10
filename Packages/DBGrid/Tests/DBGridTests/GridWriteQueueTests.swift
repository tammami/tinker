import XCTest

@testable import DBGrid

/// The single-flight write gate both tabs share: one write at a time, requests during a
/// write merged into the next, one re-read after the queue drains, a refusal stops it.
@MainActor
final class GridWriteQueueTests: XCTestCase {
    /// Records what the queue asked for, and answers as told.
    @MainActor
    final class Recorder {
        var performed: [CommitScope] = []
        var drains = 0
        var pending = true
        var refuse = false
        var gate: CheckedContinuation<Void, Never>?

        func perform(_ scope: CommitScope) async -> Bool {
            performed.append(scope)
            if let hold = holdNext {
                holdNext = nil
                await withCheckedContinuation { gate = $0; hold() }
            }
            return !refuse
        }

        /// Set to hold the next write open until `release()` is called.
        var holdNext: (() -> Void)?
        func release() {
            gate?.resume()
            gate = nil
        }
    }

    func testARequestDuringAWriteIsMergedAndRunsAfterIt() async {
        let queue = GridWriteQueue()
        let recorder = Recorder()
        var held = false
        recorder.holdNext = { held = true }
        let first = queue.enqueue(
            .loadedRowsOnly, hasPending: { _ in recorder.pending },
            perform: { await recorder.perform($0) }, afterDrain: { recorder.drains += 1 })
        while !held { await Task.yield() }
        XCTAssertTrue(queue.isWriting)

        let second = queue.enqueue(
            .everything, hasPending: { _ in recorder.pending },
            perform: { await recorder.perform($0) }, afterDrain: { recorder.drains += 1 })
        XCTAssertTrue(first == second, "a request during a write joins that write's task")
        recorder.release()
        await first.value

        XCTAssertEqual(recorder.performed, [.loadedRowsOnly, .everything])
        XCTAssertEqual(recorder.drains, 1, "the grid is re-read once, after the merged writes")
        XCTAssertFalse(queue.isWriting)
    }

    func testARefusedWriteStopsTheQueueAndDropsWhatWasMergedBehindIt() async {
        let queue = GridWriteQueue()
        let recorder = Recorder()
        recorder.refuse = true
        var held = false
        recorder.holdNext = { held = true }
        let task = queue.enqueue(
            .loadedRowsOnly, hasPending: { _ in true },
            perform: { await recorder.perform($0) }, afterDrain: { recorder.drains += 1 })
        while !held { await Task.yield() }
        queue.enqueue(
            .everything, hasPending: { _ in true },
            perform: { await recorder.perform($0) }, afterDrain: { recorder.drains += 1 })
        recorder.release()
        await task.value

        XCTAssertEqual(recorder.performed, [.loadedRowsOnly], "nothing runs after a refusal")
        XCTAssertEqual(recorder.drains, 0, "no re-read after a refusal: the edits are still pending")
        XCTAssertFalse(queue.isWriting)
    }

    func testAnEmptyScopeIsSkippedButStillDrains() async {
        let queue = GridWriteQueue()
        let recorder = Recorder()
        recorder.pending = false
        await queue.enqueue(
            .everything, hasPending: { _ in recorder.pending },
            perform: { await recorder.perform($0) }, afterDrain: { recorder.drains += 1 }
        ).value
        XCTAssertEqual(recorder.performed, [])
        XCTAssertEqual(recorder.drains, 1)
    }

    func testMergeWidensToEverything() {
        XCTAssertEqual(GridWriteQueue.merge(nil, .loadedRowsOnly), .loadedRowsOnly)
        XCTAssertEqual(GridWriteQueue.merge(.loadedRowsOnly, .everything), .everything)
        XCTAssertEqual(GridWriteQueue.merge(.everything, .loadedRowsOnly), .everything)
    }
}
