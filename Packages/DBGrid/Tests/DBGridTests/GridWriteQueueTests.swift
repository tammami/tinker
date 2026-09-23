import XCTest

@testable import DBGrid

/// The single-flight write gate both tabs share: one write at a time, in order, each
/// followed by its own re-read; a request of the same kind as one still waiting merges
/// into it, and a refusal stops the queue.
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
        XCTAssertEqual(
            recorder.drains, 2,
            "each write is followed by its own re-read, so the next one plans from the rows as they now are")
        XCTAssertFalse(queue.isWriting)
    }

    /// A burst of edits while a write is on the server is one more write, not one each.
    func testRequestsOfOneKindWaitingTogetherAreMerged() async {
        let queue = GridWriteQueue()
        let recorder = Recorder()
        var held = false
        recorder.holdNext = { held = true }
        let first = queue.enqueue(
            .loadedRowsOnly, hasPending: { _ in true },
            perform: { await recorder.perform($0) }, afterDrain: { recorder.drains += 1 })
        while !held { await Task.yield() }
        for scope in [CommitScope.loadedRowsOnly, .everything, .loadedRowsOnly] {
            queue.enqueue(
                scope, hasPending: { _ in true },
                perform: { await recorder.perform($0) }, afterDrain: { recorder.drains += 1 })
        }
        recorder.release()
        await first.value
        XCTAssertEqual(recorder.performed, [.loadedRowsOnly, .everything])
        XCTAssertEqual(recorder.drains, 2)
    }

    /// A put-back and an edit asked for during a write each run their own closures. The
    /// edit used to be judged by the put-back's idea of what was pending, found nothing,
    /// and was left unwritten.
    func testAPutBackThenAnEditEachRunTheirOwnWrite() async {
        let queue = GridWriteQueue()
        let recorder = Recorder()
        var held = false
        recorder.holdNext = { held = true }
        var ran: [String] = []
        let first = queue.enqueue(
            .loadedRowsOnly, hasPending: { _ in true },
            perform: { await recorder.perform($0) }, afterDrain: { ran.append("reload") })
        while !held { await Task.yield() }
        queue.enqueue(
            .everything, kind: "revert 1", hasPending: { _ in false },
            perform: { _ in
                ran.append("put back")
                return true
            }, afterDrain: { ran.append("reload") })
        queue.enqueue(
            .loadedRowsOnly, hasPending: { _ in true },
            perform: { _ in
                ran.append("edit")
                return true
            }, afterDrain: { ran.append("reload") })
        recorder.release()
        await first.value
        XCTAssertEqual(
            ran, ["reload", "reload", "edit", "reload"],
            "the put-back found nothing to do and was skipped; the edit still ran, by its own check")
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
