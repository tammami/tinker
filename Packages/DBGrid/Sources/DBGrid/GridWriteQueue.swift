import Foundation
import Observation

/// One write at a time for one grid, whoever asks: auto-commit, Retry, the toolbar's
/// Commit, the ⌘⇧S sheet, or a put-back from the write log.
///
/// Requests run in the order they were made, each with its own closures, and each is
/// followed by its own re-read of the grid before the next one starts. A request made
/// while a write is on the server waits its turn; one of the same kind as the request
/// still waiting at the back of the queue is merged into it, so a burst of edits is one
/// more write, not one per keystroke. A refused write stops the queue and drops what
/// was waiting behind it: the edits are still in the buffer, and the user decides.
///
/// The re-read between writes is what keeps a write's put-back honest: the next write
/// works out what it replaces from the rows as the server now holds them, not as they
/// were loaded before the previous write changed them. And a put-back followed by an
/// edit runs the put-back and then the edit, rather than the edit being judged by the
/// put-back's idea of what is pending.
///
/// The table tab and the query tab's result grids each had a copy of this loop; a fix
/// to one drifted from the other. Both own one of these now.
@MainActor
@Observable
public final class GridWriteQueue {
    /// True while a write is on the server.
    public private(set) var isWriting = false

    /// One caller's write: what it covers, and its own way to check, run and follow it.
    private struct Request {
        let kind: String
        var scope: CommitScope
        let hasPending: @MainActor (CommitScope) -> Bool
        let perform: @MainActor (CommitScope) async -> Bool
        let afterDrain: @MainActor () async -> Void
    }

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var waiting: [Request] = []

    public init() {}

    /// The scope a merged request covers: `.everything` absorbs `.loadedRowsOnly`.
    public static func merge(_ existing: CommitScope?, _ incoming: CommitScope) -> CommitScope {
        (existing == .everything || incoming == .everything) ? .everything : .loadedRowsOnly
    }

    /// Writes `scope`, or queues it behind the write already running. Returns the task
    /// that will have written it by the time it finishes.
    ///
    /// - Parameters:
    ///   - kind: what the request is, for merging: a request is merged only into a
    ///     waiting request of the same kind. Edits of the grid share one kind; each
    ///     put-back is its own.
    ///   - hasPending: whether the grid holds anything in `scope`; an empty scope is skipped.
    ///   - perform: runs one commit and returns false when the server refused it.
    ///   - afterDrain: re-reads the grid once this request's write has landed, before the
    ///     next request runs.
    @discardableResult
    public func enqueue(
        _ scope: CommitScope,
        kind: String = "edits",
        hasPending: @escaping @MainActor (CommitScope) -> Bool,
        perform: @escaping @MainActor (CommitScope) async -> Bool,
        afterDrain: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        let request = Request(
            kind: kind, scope: scope, hasPending: hasPending, perform: perform, afterDrain: afterDrain)
        if let task {
            if let last = waiting.last, last.kind == kind {
                // The newer closures, with the scope widened to cover both.
                var merged = request
                merged.scope = Self.merge(last.scope, scope)
                waiting[waiting.count - 1] = merged
            } else {
                waiting.append(request)
            }
            return task
        }
        isWriting = true
        let running = Task { [weak self] in
            guard let self else { return }
            var next: Request? = request
            while let current = next {
                if current.hasPending(current.scope), !(await current.perform(current.scope)) {
                    waiting.removeAll()
                    break
                }
                await current.afterDrain()
                next = waiting.isEmpty ? nil : waiting.removeFirst()
            }
            isWriting = false
            task = nil
        }
        task = running
        return running
    }
}
