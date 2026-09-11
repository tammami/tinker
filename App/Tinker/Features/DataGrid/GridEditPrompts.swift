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
}
