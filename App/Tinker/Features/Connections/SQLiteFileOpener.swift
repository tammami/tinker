import AppKit
import DBCore
import DBSQLite
import Foundation
import UniformTypeIdentifiers

/// Opens SQLite database files the way Navicat does: drop the file on the window, or pick
/// it from the File menu, and it is a connection — connected, expanded, ready.
///
/// A file that already has a connection reuses it; any other becomes a new one named after
/// the file. A `.sql` file dropped alongside opens as a query tab, as ⌘O would.
@MainActor
enum SQLiteFileOpener {
    /// The file types the open panel and the drop target offer. The header decides in the
    /// end; the list only steers the panel.
    static var contentTypes: [UTType] {
        SQLiteDriver.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.database]
    }

    /// Handles every URL: databases connect, `.sql` files open as queries, and anything
    /// else is left alone. Returns how many URLs were taken.
    @discardableResult
    static func open(_ urls: [URL], in controller: WorkspaceController) async -> Int {
        var taken = 0
        for url in urls {
            let path = url.standardizedFileURL.path
            if url.pathExtension.lowercased() == "sql" {
                if controller.openSQLFile(at: url) { taken += 1 }
                continue
            }
            if SQLiteDriver.isDatabaseFile(at: path) {
                await openDatabase(atPath: path, in: controller)
                taken += 1
            } else if SQLiteDriver.fileExtensions.contains(url.pathExtension.lowercased()) {
                // Looks like a database but is not one: the editor's validation says why.
                var config = SQLiteDriver.connectionConfig(forFileAt: path)
                config.name = url.deletingPathExtension().lastPathComponent
                controller.workspace.editingConnection = config
                controller.workspace.isEditingNewConnection = true
                taken += 1
            }
        }
        return taken
    }

    /// Connects to the database file at `path`, saving a connection for it first when
    /// none points there yet.
    static func openDatabase(atPath path: String, in controller: WorkspaceController) async {
        let environment = controller.environment
        let config: ConnectionConfig
        if let existing = environment.connections.first(where: { $0.dialect == .sqlite && $0.database == path }) {
            config = existing
        } else {
            var fresh = SQLiteDriver.connectionConfig(forFileAt: path)
            fresh.name = uniqueName(fresh.name, among: environment.connections)
            await environment.save(fresh)
            controller.sidebar.rebuildRoots()
            config = fresh
        }
        controller.workspace.sidebarSelection = config.id.uuidString
        if let item = controller.sidebar.roots.first(where: { $0.id == config.id.uuidString }) {
            await controller.sidebar.expand(item)
        }
    }

    /// `Orders`, then `Orders 2`, `Orders 3`… so two files of the same name stay apart.
    static func uniqueName(_ base: String, among connections: [ConnectionConfig]) -> String {
        let names = Set(connections.map(\.name))
        guard names.contains(base) else { return base }
        var counter = 2
        while names.contains("\(base) \(counter)") { counter += 1 }
        return "\(base) \(counter)"
    }

    /// The open panel behind File › Open SQLite Database….
    static func chooseAndOpen(in controller: WorkspaceController) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = contentTypes + [.data]
        panel.message = "Choose a SQLite database file. It opens as a connection."
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task { await open(urls, in: controller) }
    }
}

/// Receives the files Finder hands the app — a double-clicked database, "Open With", a
/// drop on the Dock icon — and opens them once a workspace window exists to open them in.
final class TinkerAppDelegate: NSObject, NSApplicationDelegate {
    /// Quitting with uncommitted edits or an open transaction in any window asks first
    /// (SPEC §13.2). The question goes through the frontmost workspace's confirmation
    /// sheet; the answer is handed back to AppKit, which finishes or cancels the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let workspaces = CommandCenter.shared.all
        let unsaved = workspaces.filter(\.hasAnyUnsavedWork)
        guard !unsaved.isEmpty, let front = workspaces.first else { return .terminateNow }
        let tabs = unsaved.reduce(0) { total, workspace in
            total + workspace.workspace.tabs.filter { workspace.hasUnsavedWork($0) }.count
        }
        front.workspace.confirmation = DestructiveConfirmation(
            title: "Quit \(Product.name)?",
            message:
                "\(tabs) tab\(tabs == 1 ? " has" : "s have") uncommitted changes or an open transaction. "
                + "Quitting rolls the transactions back and discards the changes.",
            confirmTitle: "Quit",
            action: { sender.reply(toApplicationShouldTerminate: true) },
            onCancel: { sender.reply(toApplicationShouldTerminate: false) }
        )
        return .terminateLater
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            // The first window may still be on its way when the app is launched by a file.
            for _ in 0 ..< 50 where CommandCenter.shared.current == nil {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let controller = CommandCenter.shared.current else { return }
            await SQLiteFileOpener.open(urls, in: controller)
        }
    }
}
