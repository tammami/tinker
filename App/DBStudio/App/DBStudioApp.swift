import DBCore
import DBGrid
import SwiftUI

/// Commands the menus dispatch to whichever workspace window is focused.
///
/// SwiftUI menu items live outside the window's view tree, so the focused window
/// publishes this bundle of closures and the commands call through it (SPEC §10.2).
@MainActor
public struct WorkspaceCommands {
    public var newQueryTab: () -> Void
    public var run: (Bool) -> Void
    public var cancel: () -> Void
    public var commit: () -> Void
    public var rollback: () -> Void
    public var refresh: () -> Void
    public var quickOpen: () -> Void
    public var toggleFilter: () -> Void
    public var toggleSidebar: () -> Void
    public var toggleInspector: () -> Void
    public var closeTab: () -> Void
    public var selectTab: (Int) -> Void
    public var cycleTab: (Bool) -> Void
    public var formatSQL: () -> Void
    public var toggleReadOnly: () -> Void
    public var export: () -> Void
    public var copy: (ClipboardFormat) -> Void
    public var paste: () -> Void
    public var setNull: () -> Void
    public var addRow: () -> Void
    public var deleteRows: () -> Void
    public var showHistory: () -> Void
    public var openSQLFile: () -> Void
    public var saveSQLFile: () -> Void
    public var cycleResultTab: (Bool) -> Void
}

struct WorkspaceCommandsKey: FocusedValueKey {
    typealias Value = WorkspaceCommands
}

extension FocusedValues {
    var workspaceCommands: WorkspaceCommands? {
        get { self[WorkspaceCommandsKey.self] }
        set { self[WorkspaceCommandsKey.self] = newValue }
    }
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
    @FocusedValue(\.workspaceCommands) private var commands
    let updater: Updater

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            Button(updater.menuTitle) { updater.checkForUpdates() }
                .disabled(!updater.isConfigured)
        }

        CommandGroup(replacing: .newItem) {
            Button("New Query Tab") { commands?.newQueryTab() }
                .keyboardShortcut("t", modifiers: .command)
            Button("New Window") {
                NSApp.sendAction(#selector(NSDocumentController.newDocument(_:)), to: nil, from: nil)
            }
            .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Open SQL File…") { commands?.openSQLFile() }
                .keyboardShortcut("o", modifiers: .command)
            Button("Save Query…") { commands?.saveSQLFile() }
                .keyboardShortcut("s", modifiers: .command)
            Divider()
            Button("Export Result…") { commands?.export() }
                .keyboardShortcut("e", modifiers: .command)
        }

        CommandGroup(replacing: .saveItem) {
            Button("Commit") { commands?.commit() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
            Button("Rollback") { commands?.rollback() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
        }

        CommandGroup(after: .pasteboard) {
            Divider()
            Button("Copy as INSERT") { commands?.copy(.sqlInsert) }
                .keyboardShortcut("c", modifiers: [.command, .option])
            Menu("Copy As") {
                Button("CSV") { commands?.copy(.csv) }
                Button("JSON") { commands?.copy(.json) }
                Button("Markdown Table") { commands?.copy(.markdown) }
                Button("WHERE-IN List") { commands?.copy(.whereIn) }
            }
            Button("Paste into Grid") { commands?.paste() }
            Divider()
            Button("Set NULL") { commands?.setNull() }
                .keyboardShortcut(.delete, modifiers: .command)
            Button("Add Row") { commands?.addRow() }
                .keyboardShortcut("+", modifiers: .command)
            Button("Delete Selected Rows") { commands?.deleteRows() }
                .keyboardShortcut("-", modifiers: .command)
        }

        CommandMenu("Query") {
            Button("Run") { commands?.run(false) }
                .keyboardShortcut(.return, modifiers: .command)
            Button("Run All") { commands?.run(true) }
                .keyboardShortcut(.return, modifiers: [.command, .shift])
            Button("Cancel") { commands?.cancel() }
                .keyboardShortcut(".", modifiers: .command)
            Divider()
            Button("Format SQL") { commands?.formatSQL() }
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Divider()
            Button("History…") { commands?.showHistory() }
                .keyboardShortcut("y", modifiers: .command)
            Button("Toggle Read-Only") { commands?.toggleReadOnly() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Divider()
            Button("Previous Result") { commands?.cycleResultTab(false) }
                .keyboardShortcut(.leftArrow, modifiers: [.command, .option])
            Button("Next Result") { commands?.cycleResultTab(true) }
                .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
        }

        CommandGroup(after: .sidebar) {
            Button("Toggle Sidebar") { commands?.toggleSidebar() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Toggle Cell Inspector") { commands?.toggleInspector() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Filter Grid") { commands?.toggleFilter() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Divider()
            Button("Refresh") { commands?.refresh() }
                .keyboardShortcut("r", modifiers: .command)
            Button("Quick Open Table…") { commands?.quickOpen() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button("Close Tab") { commands?.closeTab() }
                .keyboardShortcut("w", modifiers: .command)
            Button("Next Tab") { commands?.cycleTab(true) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
            Button("Previous Tab") { commands?.cycleTab(false) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            // ⌘1–⌘9 select tabs directly.
            ForEach(1 ... 9, id: \.self) { number in
                Button("Tab \(number)") { commands?.selectTab(number - 1) }
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
