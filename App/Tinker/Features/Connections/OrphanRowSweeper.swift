import AppKit
import SwiftUI

/// Takes row views off an outline once the outline no longer tracks them.
///
/// SwiftUI's `List` sometimes leaves one behind when the tree changes: a row view still in
/// the outline's subviews, visible, for which `row(for:)` answers -1. Nothing lays it out or
/// removes it again, so it stays where it was and draws over whichever row sits there later,
/// which shows as a row with two state dots, or a connection printed across a database name.
/// The trigger is inside SwiftUI (ADR-0074); what it leaves behind is plain to see, so that
/// is what gets removed.
enum OrphanRowSweeper {
    /// How long the tree must have been still before looking, so that a row view on its way
    /// out in a collapse or removal animation (about a quarter of a second) has finished.
    static let settleDelay: Duration = .milliseconds(600)

    /// The visible row views `outline` does not track. A hidden one is in the reuse pool and
    /// is the outline's to manage.
    @MainActor
    static func orphans(in outline: NSOutlineView) -> [NSTableRowView] {
        outline.subviews
            .compactMap { $0 as? NSTableRowView }
            .filter { !$0.isHidden && outline.row(for: $0) < 0 }
    }

    /// Removes the orphans and answers how many there were.
    @MainActor
    @discardableResult
    static func sweep(_ outline: NSOutlineView) -> Int {
        let found = orphans(in: outline)
        found.forEach { $0.removeFromSuperview() }
        return found.count
    }

    /// The nearest outline to `view`: the closest ancestor's subtree that holds one.
    @MainActor
    static func nearestOutline(to view: NSView) -> NSOutlineView? {
        var ancestor = view.superview
        while let current = ancestor {
            if let outline = firstOutline(in: current) { return outline }
            ancestor = current.superview
        }
        return nil
    }

    @MainActor
    private static func firstOutline(in view: NSView) -> NSOutlineView? {
        if let outline = view as? NSOutlineView { return outline }
        for subview in view.subviews {
            if let outline = firstOutline(in: subview) { return outline }
        }
        return nil
    }
}

/// Sweeps the sidebar's outline after `trigger` stops changing. It draws nothing.
struct OrphanRowSweeperAnchor<Trigger: Equatable>: NSViewRepresentable {
    let trigger: Trigger

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        guard context.coordinator.lastTrigger != trigger else { return }
        context.coordinator.lastTrigger = trigger
        context.coordinator.scheduleSweep(from: view)
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    @MainActor
    final class Coordinator {
        var lastTrigger: Trigger?
        private var pending: Task<Void, Never>?

        /// Restarts the wait, so a burst of changes is swept once, after the last of them.
        func scheduleSweep(from view: NSView) {
            pending?.cancel()
            pending = Task { [weak view] in
                try? await Task.sleep(for: OrphanRowSweeper.settleDelay)
                guard !Task.isCancelled, let view, let outline = OrphanRowSweeper.nearestOutline(to: view) else {
                    return
                }
                OrphanRowSweeper.sweep(outline)
            }
        }

        func cancel() { pending?.cancel() }
    }
}
