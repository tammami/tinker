import DBCore
import DBGrid
import SwiftUI

/// The product's names: what the app calls itself, and who made it.
enum Product {
    static let name = "Tinker"
    static let maker = "ThinkFree"
    static let credit = "Tinker by ThinkFree"
}

struct DBStudioApp: App {
    @State private var environment = AppEnvironment()
    @State private var settings: AppSettings
    @State private var updater = Updater()
    @State private var crashReporter: CrashReporter

    init() {
        let environment = AppEnvironment()
        _environment = State(initialValue: environment)
        _settings = State(initialValue: AppSettings(environment: environment))
        _crashReporter = State(initialValue: CrashReporter(environment: environment))
    }

    var body: some Scene {
        WindowGroup(Product.name) {
            WorkspaceView(environment: environment, settings: settings)
                .frame(minWidth: 960, minHeight: 600)
                .task {
                    await settings.load()
                    await crashReporter.start()
                }
        }
        .defaultSize(width: 1_280, height: 800)
        .commands { DBStudioCommands(updater: updater) }

        Settings {
            SettingsView(settings: settings, crashReporter: crashReporter, updater: updater)
        }
    }
}

/// Every keyboard shortcut, registered so it appears in the menus.
struct DBStudioCommands: Commands {
    let updater: Updater

    /// F5, the refresh key every database tool shares; the scalar is AppKit's NSF5FunctionKey.
    static let f5 = KeyEquivalent(Character(UnicodeScalar(0xF708) ?? UnicodeScalar(UInt8(32))))

    /// The frontmost workspace. Read at the moment the menu item fires, so it is never a
    /// stale capture and never depends on where first responder happens to be.
    private var workspace: WorkspaceController? { CommandCenter.shared.current }

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(Product.name)") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationName: Product.name,
                    .credits: NSAttributedString(
                        string: "\(Product.credit)\nA native client for PostgreSQL and MySQL.",
                        attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)]
                    ),
                ])
            }
            Button(updater.menuTitle) { updater.checkForUpdates() }
                .disabled(!updater.isConfigured)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Query Tab") { workspace?.newQueryTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Window") {
                NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Open SQL File…") { workspace?.openSQLFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Save Query…") { workspace?.saveSQLFile() }
                .keyboardShortcut("s", modifiers: .command)
            Divider()
            Button("Import from CSV…") { workspace?.importCSV() }
            Button("Export Result…") { workspace?.workspace.isExportPresented = true }
                .keyboardShortcut("e", modifiers: [.command, .option])
        }

        CommandGroup(replacing: .saveItem) {
            Button("Commit") { workspace?.commit() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Rollback") { workspace?.rollback() }
                .keyboardShortcut(.delete, modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as INSERT") { workspace?.copySelection(.sqlInsert) }
                .keyboardShortcut("c", modifiers: [.command, .control])
            Menu("Copy As") {
                Button("CSV") { workspace?.copySelection(.csv) }
                Button("JSON") { workspace?.copySelection(.json) }
                Button("Markdown Table") { workspace?.copySelection(.markdown) }
                Button("Aligned Text") { workspace?.copySelection(.text) }
                Button("WHERE-IN List") { workspace?.copySelection(.whereIn) }
            }
            Button("Paste into Grid") { workspace?.paste() }
            Divider()
            Button("Set NULL") { workspace?.setNull() }
                .keyboardShortcut(.delete, modifiers: [.command, .option])
            Button("Add Row") { workspace?.addRow() }
                .keyboardShortcut("a", modifiers: [.command, .option])
            Button("Delete Selected Rows") { workspace?.deleteRows() }
                .keyboardShortcut(.delete, modifiers: .command)
        }

        CommandGroup(replacing: .textEditing) {
            Button("Find…") { workspace?.findInEditor(replace: false) }
                .keyboardShortcut("f", modifiers: .command)
                .help("Find in the editor, or search the front tab")
            Button("Find and Replace…") { workspace?.findInEditor(replace: true) }
                .keyboardShortcut("f", modifiers: [.command, .option])
        }

        CommandMenu("Query") {
            // ⌘R, not ⌘↩: the system claims ⌘↩ for the window, and Return with modifiers
            // is what every other text view expects to keep.
            Button("Run Current or Selection") { workspace?.run(all: false) }
                .keyboardShortcut("r", modifiers: .command)
            Button("Run Selected") { workspace?.runSelection() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Run All") { workspace?.run(all: true) }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Button("Cancel") { workspace?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Explain") { workspace?.explain(analyze: false) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Explain Analyze") { workspace?.explain(analyze: true) }
            Button("Format SQL") { workspace?.formatSQL() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("Snippets…") { workspace?.showSnippets() }
                .keyboardShortcut("k", modifiers: [.command, .shift])
            Button("History…") { workspace?.workspace.isHistoryPresented = true }
                .keyboardShortcut("y", modifiers: .command)
            Button("Toggle Read-Only") { workspace?.toggleReadOnly() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Previous Result") { workspace?.cycleResultTab(forward: false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Result") { workspace?.cycleResultTab(forward: true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }

        CommandMenu("Database") {
            Button("Command Palette…") { workspace?.showCommandPalette() }
                .keyboardShortcut("k", modifiers: .command)
            Button("Quick Open Table…") { workspace?.workspace.isQuickOpenPresented = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("New Connection…") { workspace?.workspace.presentNewConnection() }
                .keyboardShortcut("n", modifiers: [.command, .option])
            Button("New Folder…") { workspace?.workspace.folderEditor = FolderEditor(kind: .create(parent: [])) }
            Button("New Table…") { workspace?.workspace.isNewTablePresented = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Query Builder") { workspace?.showQueryBuilder() }
                .keyboardShortcut("b", modifiers: [.command, .shift])
            Button("Structure Sync…") { workspace?.workspace.isStructureSyncPresented = true }
            Divider()
            Button("Server Activity") { workspace?.showServerActivity() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("Users & Privileges") {
                guard let workspace, let id = workspace.workspace.activeConnectionID else { return }
                workspace.openUsers(connectionID: id, database: workspace.workspace.activeConnection?.database)
            }
            .keyboardShortcut("u", modifiers: [.command, .shift])
            Button("Refresh") { workspace?.refresh() }
                .keyboardShortcut(Self.f5, modifiers: [])
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { workspace?.isSidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Inspector") { workspace?.workspace.isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Toggle Filter Bar") { workspace?.workspace.isFilterBarVisible.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") { workspace?.closeSelectedTab() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Next Tab") { workspace?.workspace.cycleTab(forward: true) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { workspace?.workspace.cycleTab(forward: false) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            // ⌘1–⌘9 select tabs directly.
            ForEach(1 ... 9, id: \.self) { number in
                Button("Tab \(number)") { workspace?.workspace.selectTab(at: number - 1) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: .command)
            }
        }
    }
}

/// The process entry point.
///
/// It exists so the app can choose between showing a window and running the headless
/// smoke test, which a `@main` `App` struct cannot do on its own.
@main
enum DBStudioEntryPoint {
    static func main() {
        if MainActor.assumeIsolated({ SmokeTest.isRequested }) {
            let task = Task { @MainActor in await SmokeTest.run() }
            withExtendedLifetime(task) { RunLoop.main.run() }
        }
        DBStudioApp.main()
    }
}
