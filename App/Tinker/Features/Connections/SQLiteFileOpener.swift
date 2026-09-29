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
            // A connections backup is not a database: it opens its restore sheet.
            if url.pathExtension.lowercased() == ConnectionBackupCodec.fileExtension {
                controller.openConnectionBackup(at: url)
                taken += 1
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
    /// Quitting while tabs are open asks first, in any window (SPEC §13.2 asked only
    /// for uncommitted work; a stray ⌘Q closing a window full of tabs cost more than the
    /// question does), answered in an alert before AppKit finishes or cancels the quit.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let workspaces = CommandCenter.shared.all
        let openTabs = workspaces.reduce(0) { $0 + $1.workspace.tabs.count }
        let unsavedTabs = workspaces.reduce(0) { total, workspace in
            total + workspace.workspace.tabs.filter { workspace.hasUnsavedWork($0) }.count
        }
        guard let question = Self.quitQuestion(openTabs: openTabs, unsavedTabs: unsavedTabs) else { return .terminateNow }
        // Logging out, restarting or shutting down is not a stray ⌘Q: with nothing unsaved
        // it goes ahead rather than hold the whole Mac up on a question.
        if unsavedTabs == 0, Self.isSystemQuit() { return .terminateNow }
        // An app-modal alert, not a workspace sheet: a window with an Import or New
        // Database sheet already up cannot show a second one, and the quit would hang.
        let alert = NSAlert()
        alert.messageText = "Quit \(Product.name)?"
        alert.informativeText = question
        alert.alertStyle = unsavedTabs > 0 ? .critical : .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    /// Whether the quit was asked for by the system (log out, restart, shut down).
    static func isSystemQuit() -> Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
            event.eventClass == kCoreEventClass, event.eventID == kAEQuitApplication,
            let reason = event.attributeDescriptor(forKeyword: kAEQuitReason)?.enumCodeValue
        else { return false }
        return [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAERestart, kAEShowShutdownDialog, kAEShutDown]
            .map { OSType($0) }.contains(reason)
    }

    /// What quitting asks, or nil when there is nothing open to lose.
    static func quitQuestion(openTabs: Int, unsavedTabs: Int) -> String? {
        guard openTabs > 0 else { return nil }
        var message = "\(openTabs) tab\(openTabs == 1 ? " is" : "s are") open and will be closed."
        if unsavedTabs > 0 {
            message +=
                " \(unsavedTabs) of them \(unsavedTabs == 1 ? "has" : "have") uncommitted changes or an open transaction; "
                + "quitting rolls the transactions back and discards the changes."
        }
        return message
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
