import DBGrid
import Foundation

/// The questions a grid asks before it loses or writes something, worded once for the
/// table tab and the query tab's result grids alike.
@MainActor
enum GridEditPrompts {
    /// Asked before a delete that auto-commit would send at once: there is no preview
    /// sheet and no Discard to catch a key meant for its neighbour.
    static func deleteRows(
        count: Int, from name: String, action: @escaping @MainActor () async -> Void
    ) -> DestructiveConfirmation {
        DestructiveConfirmation(
            title: "Delete \(count) row\(count == 1 ? "" : "s") from “\(name)”?",
            message:
                "Auto-commit is on, so the DELETE runs on the server as soon as you confirm. "
                + "Turn auto-commit off to review deletions in the commit sheet first.",
            confirmTitle: "Delete \(count == 1 ? "Row" : "\(count) Rows")",
            action: action
        )
    }

    /// Asked before clearing a value that had something in it, when auto-commit would send
    /// the UPDATE at once. Emptying a cell is a deletion, not an edit, and the editor
    /// opens on a whole selected value where one keystroke does it (ADR-0061).
    static func clearValue(
        column: String, from name: String, action: @escaping @MainActor () async -> Void
    ) -> DestructiveConfirmation {
        DestructiveConfirmation(
            title: "Clear “\(column)”?",
            message:
                "The cell has a value; leaving it empty writes an empty value to “\(name)” straight away, "
                + "because auto-commit is on. Esc leaves the value as it was.",
            confirmTitle: "Clear Value",
            action: action
        )
    }

    /// Asked before putting a write back on a production connection: the revert is itself
    /// a write, and production asks about every one of them.
    static func revertWrite(
        summary: String, table name: String, action: @escaping @MainActor () async -> Void
    ) -> DestructiveConfirmation {
        DestructiveConfirmation(
            title: "Put back “\(summary)” on “\(name)”?",
            message:
                "This runs the statements that restore the values the write replaced, in one transaction. "
                + "A row that changed again since is refused rather than overwritten.",
            confirmTitle: "Put It Back",
            action: action
        )
    }
}
