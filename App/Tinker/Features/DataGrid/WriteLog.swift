import DBCore
import DBGrid
import DBSQL
import Foundation
import Observation

/// One write a grid sent to the server, and what would take it back (ADR-0060).
public struct WriteRecord: Identifiable, Sendable {
    public let id = UUID()
    public let at: Date
    /// What it did, in the user's words: "1 row updated", "2 rows deleted".
    public let summary: String
    /// The statements that would put it back, empty when it cannot be put back.
    public let revert: [GeneratedStatement]
    /// Why it cannot be put back, when it cannot.
    public let blockedReason: String?
    /// True once it has been taken back, so the button goes and the entry stays.
    public var isReverted = false

    public init(
        at: Date = Date(), summary: String, revert: [GeneratedStatement], blockedReason: String? = nil
    ) {
        self.at = at
        self.summary = summary
        self.revert = revert
        self.blockedReason = blockedReason
    }

    public var canRevert: Bool { !isReverted && blockedReason == nil && !revert.isEmpty }

    /// How the statements of one commit read as a sentence.
    ///
    /// A commit is usually one kind of change — the cell just edited, the rows just
    /// deleted — so the common case gets a plain count. A mixed one is counted whole
    /// rather than listed, because the list is in the log beside it.
    public static func summary(of kinds: [GeneratedStatement.Kind]) -> String {
        func rows(_ count: Int) -> String { "\(count) row\(count == 1 ? "" : "s")" }
        let updates = kinds.count { $0 == .update }
        let inserts = kinds.count { $0 == .insert }
        let deletes = kinds.count { $0 == .delete }
        switch (updates, inserts, deletes) {
        case (let n, 0, 0) where n > 0: return "\(rows(n)) updated"
        case (0, let n, 0) where n > 0: return "\(rows(n)) added"
        case (0, 0, let n) where n > 0: return "\(rows(n)) deleted"
        default: return "\(kinds.count) change\(kinds.count == 1 ? "" : "s") written"
        }
    }
}

/// A tab that writes through a grid and can take those writes back.
///
/// Both kinds of tab write to real tables and both auto-commit, so both need the same way
/// back; this is what the status line and the log popover talk to.
@MainActor
public protocol WriteLogOwner: AnyObject, Observable {
    var writeLog: WriteLog { get }
    /// True while a write is on the server, when nothing may be taken back.
    var isWritingNow: Bool { get }
    func revert(_ record: WriteRecord)
}

/// What a tab has written since it was opened, newest first.
///
/// A grid with auto-commit on writes as the user types, and the edit buffer — with its
/// undo history — is empty again the moment the write lands. The log is what is left to
/// undo with: each entry carries the statements that would restore what it replaced, so
/// an accidental edit is a write to take back rather than a value that is simply gone.
@MainActor
@Observable
public final class WriteLog {
    /// How many writes a tab remembers. Enough to find yesterday's mistake in a session,
    /// bounded so a long editing session does not grow without end.
    public static let capacity = 50

    public private(set) var records: [WriteRecord] = []

    public init() {}

    /// The write to offer as "Undo": the newest one that can still be taken back.
    public var undoable: WriteRecord? { records.first { $0.canRevert } }

    /// The newest write, whether or not it can be taken back, for the status line.
    public var latest: WriteRecord? { records.first }

    public func record(_ record: WriteRecord) {
        records.insert(record, at: 0)
        if records.count > Self.capacity { records.removeLast(records.count - Self.capacity) }
    }

    public func markReverted(_ id: UUID) {
        guard let index = records.firstIndex(where: { $0.id == id }) else { return }
        records[index].isReverted = true
    }

    public func clear() { records.removeAll() }
}
