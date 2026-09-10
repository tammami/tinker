import Foundation
import Observation

/// One write at a time for one grid, whoever asks: auto-commit, Retry, the toolbar's
/// Commit or the ⌘⇧S sheet.
///
/// A scope asked for while a write is on the server is merged into the next write, and
/// the grid is re-read once, after the queue drains, so an edit made during a write is
/// neither lost nor written twice. A refused write stops the queue and drops what was
/// merged behind it: the edits are still in the buffer, and the user decides.
///
/// The table tab and the query tab's result grids each had a copy of this loop; a fix
/// to one drifted from the other. Both own one of these now.
@MainActor
@Observable
public final class GridWriteQueue {
    /// True while a write is on the server.
    public private(set) var isWriting = false

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var queued: CommitScope?

    public init() {}

    /// The scope a merged request covers: `.everything` absorbs `.loadedRowsOnly`.
    public static func merge(_ existing: CommitScope?, _ incoming: CommitScope) -> CommitScope {
        (existing == .everything || incoming == .everything) ? .everything : .loadedRowsOnly
    }

    /// Writes `scope`, or merges it into the write already running. Returns the task that
    /// will have written it by the time it finishes.
    ///
    /// - Parameters:
    ///   - hasPending: whether the grid holds anything in `scope`; an empty scope is skipped.
    ///   - perform: runs one commit and returns false when the server refused it.
    ///   - afterDrain: re-reads the grid once every merged write has landed.
    @discardableResult
    public func enqueue(
        _ scope: CommitScope,
        hasPending: @escaping @MainActor (CommitScope) -> Bool,
        perform: @escaping @MainActor (CommitScope) async -> Bool,
        afterDrain: @escaping @MainActor () async -> Void
    ) -> Task<Void, Never> {
        if let task {
            queued = Self.merge(queued, scope)
            return task
        }
        isWriting = true
        let running = Task { [weak self] in
            guard let self else { return }
            var initial: CommitScope? = scope
            repeat {
                var current = initial
                initial = nil
                var failed = false
                while let scope = current {
                    current = nil
                    if hasPending(scope), !(await perform(scope)) {
                        failed = true
                        break
                    }
                    current = queued
                    queued = nil
                }
                if failed {
                    queued = nil
                    break
                }
                await afterDrain()
                initial = queued
                queued = nil
            } while initial != nil
            isWriting = false
            task = nil
        }
        task = running
        return running
    }
}
