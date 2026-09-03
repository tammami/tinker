import DBCore
import DBGrid
import SwiftUI

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
        WindowGroup("DBStudio") {
            WorkspaceView(environment: environment, settings: settings)
                .frame(minWidth: 900, minHeight: 560)
                .task {
                    await settings.load()
                    await crashReporter.start()
                }
        }
        .defaultSize(width: 1_200, height: 760)
        .commands { DBStudioCommands(updater: updater) }

        Settings {
            SettingsView(settings: settings, crashReporter: crashReporter, updater: updater)
        }
    }
}

/// Every keyboard shortcut in SPEC §10.2, registered so it appears in the menus.
struct DBStudioCommands: Commands {
    let updater: Updater

    /// The frontmost workspace. Read at the moment the menu item fires, so it is never a
    /// stale capture and never depends on where first responder happens to be.
    private var workspace: WorkspaceController? { CommandCenter.shared.current }

    var body: some Commands {
        CommandGroup(after: .appInfo) {
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
            Button("Export Result…") { workspace?.workspace.isExportPresented = true }
                .keyboardShortcut("e", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Commit") { workspace?.commit() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Rollback") { workspace?.rollback() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as INSERT") { workspace?.copySelection(.sqlInsert) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Menu("Copy As") {
                Button("CSV") { workspace?.copySelection(.csv) }
                Button("JSON") { workspace?.copySelection(.json) }
                Button("Markdown Table") { workspace?.copySelection(.markdown) }
                Button("WHERE-IN List") { workspace?.copySelection(.whereIn) }
            }
            Button("Paste into Grid") { workspace?.paste() }
            Divider()
            Button("Set NULL") { workspace?.setNull() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Add Row") { workspace?.addRow() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Delete Selected Rows") { workspace?.deleteRows() }
                .keyboardShortcut("-", modifiers: .command)
        }

        CommandMenu("Query") {
            Button("Run") { workspace?.run(all: false) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Run All") { workspace?.run(all: true) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Cancel") { workspace?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Format SQL") { workspace?.formatSQL() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
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

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { workspace?.isSidebarVisible.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Cell Inspector") { workspace?.workspace.isInspectorVisible.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Filter Grid") { workspace?.workspace.isFilterBarVisible.toggle() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Refresh") { workspace?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Quick Open Table…") { workspace?.workspace.isQuickOpenPresented = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("New Table…") { workspace?.workspace.isNewTablePresented = true }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Structure Sync…") { workspace?.workspace.isStructureSyncPresented = true }
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
