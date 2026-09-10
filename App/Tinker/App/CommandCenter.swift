import Foundation
import Observation

/// The workspace the menus act on.
///
/// SwiftUI's `@FocusedValue` was the obvious way to route menu commands to the front
/// window, and it does not survive an AppKit view taking first responder: while the SQL
/// editor has focus the value goes missing, SwiftUI disables the menu item, and the
/// keyboard shortcut is swallowed with nothing happening. Since the editor is exactly
/// where ⌘R matters, the menus read from here instead — a plain reference to whichever
/// workspace is frontmost (DECISIONS.md ADR-0025).
@MainActor
@Observable
public final class CommandCenter {
    public static let shared = CommandCenter()

    /// The frontmost workspace, or nil before the first window appears.
    public private(set) var current: WorkspaceController?

    /// Every workspace that has appeared and not gone away, frontmost or not, so that
    /// quitting can ask about unsaved work in a window that is behind another.
    private var registered: [ObjectIdentifier: WeakWorkspace] = [:]

    private init() {}

    public func activate(_ controller: WorkspaceController) {
        current = controller
        registered[ObjectIdentifier(controller)] = WeakWorkspace(controller)
    }

    public func deactivate(_ controller: WorkspaceController) {
        if current === controller { current = nil }
    }

    /// Every live workspace, frontmost first.
    public var all: [WorkspaceController] {
        registered = registered.filter { $0.value.controller != nil }
        let others = registered.values.compactMap(\.controller).filter { $0 !== current }
        return (current.map { [$0] } ?? []) + others
    }

    private struct WeakWorkspace {
        weak var controller: WorkspaceController?
        init(_ controller: WorkspaceController) { self.controller = controller }
    }
}
