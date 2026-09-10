import DBCore
import SwiftUI

/// One thing the palette can do.
struct PaletteCommand: Identifiable {
    enum Group: String {
        case tabs = "Open tabs"
        case tables = "Tables"
        case connections = "Connections"
        case actions = "Actions"
    }

    let id: String
    let group: Group
    let title: String
    var subtitle: String?
    let icon: String
    var shortcut: String?
    let run: @MainActor () -> Void
}

/// The command palette (⌘K): every action, open tab, known table and connection, matched
/// as you type. Keyboard first: arrows move, Return runs, Escape closes.
public struct CommandPaletteView: View {
    let controller: WorkspaceController

    @State private var query = ""
    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    private var workspace: WorkspaceModel { controller.workspace }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: Icon.command).foregroundStyle(.secondary)
                TextField("Type a command, table or connection…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFieldFocused)
                    .onSubmit(runHighlighted)
                KeyCap(keys: "esc")
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
            Divider()

            if matches.isEmpty {
                EmptyStateView(icon: Icon.search, title: "No match", message: "Try another word.")
                    .frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.element.id) { index, command in
                                if index == 0 || matches[index - 1].group != command.group {
                                    SectionHeading(text: command.group.rawValue, inset: DesignTokens.Spacing.lg)
                                }
                                row(command, isHighlighted: index == highlighted)
                                    .id(index)
                                    .onTapGesture {
                                        highlighted = index
                                        runHighlighted()
                                    }
                            }
                        }
                        .padding(.bottom, DesignTokens.Spacing.sm)
                    }
                    .frame(height: 360)
                    .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
                }
            }
            Divider()
            SheetHintBar(hints: [("↑↓", "move"), ("↩", "run")]) {
                Text("\(matches.count) result\(matches.count == 1 ? "" : "s")")
            }
        }
        .frame(width: 600)
        .onAppear { isFieldFocused = true }
        .onChange(of: query) { _, _ in highlighted = 0 }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = min(matches.count - 1, highlighted + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            workspace.isCommandPalettePresented = false
            return .handled
        }
    }

    private func row(_ command: PaletteCommand, isHighlighted: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: command.icon)
                .foregroundStyle(isHighlighted ? Color.accentColor : .secondary)
                .frame(width: DesignTokens.Metrics.iconWidth)
            Text(command.title).lineLimit(1)
            if let subtitle = command.subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            }
            Spacer()
            if let shortcut = command.shortcut { KeyCap(keys: shortcut) }
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(height: 28)
        .background(isHighlighted ? Color.accentColor.opacity(0.14) : .clear)
        .contentShape(Rectangle())
    }

    // MARK: - Commands

    /// Everything the palette offers, built once per keystroke from what is open.
    private var allCommands: [PaletteCommand] {
        var commands: [PaletteCommand] = []
        let ws = workspace

        for tab in ws.tabs {
            commands.append(
                PaletteCommand(
                    id: "tab-\(tab.id)", group: .tabs, title: tab.title,
                    subtitle: ws.environment.connections.first { $0.id == tab.connectionID }?.name,
                    icon: tab.icon
                ) { ws.selectedTabID = tab.id })
        }

        for match in controller.sidebar.knownTables.prefix(400) {
            let connection = ws.environment.connections.first { $0.id == match.connection }
            commands.append(
                PaletteCommand(
                    id: "table-\(match.connection)-\(match.table.id)", group: .tables,
                    title: match.table.name,
                    subtitle: [match.table.ref.schema, connection?.name].compactMap { $0 }.joined(separator: " · "),
                    icon: match.table.kind.symbolName
                ) { controller.openTable(match.table.ref, connectionID: match.connection) })
        }

        for config in ws.environment.connections {
            commands.append(
                PaletteCommand(
                    id: "conn-\(config.id)", group: .connections, title: config.qualifiedName,
                    subtitle: "New query on \(config.user)@\(config.host)", icon: Icon.connection
                ) { controller.newQueryTab(connectionID: config.id) })
        }

        let actions: [(String, String, String?, @MainActor () -> Void)] = [
            ("New Query Tab", Icon.newQuery, "⌘T", { controller.newQueryTab() }),
            ("Find Table…", Icon.search, "⌘⇧O", { ws.isQuickOpenPresented = true }),
            ("New Connection…", Icon.add, nil, { ws.presentNewConnection() }),
            ("New Table…", Icon.table, "⌘⇧N", { ws.isNewTablePresented = true }),
            ("Query Builder", Icon.builder, "⌘⇧B", { controller.showQueryBuilder() }),
            ("Server Activity", Icon.activity, "⌘⇧A", { controller.showServerActivity() }),
            (
                "Users & Privileges", Icon.user, "⌘⇧U",
                {
                    if let id = ws.activeConnectionID {
                        controller.openUsers(connectionID: id, database: ws.activeConnection?.database)
                    }
                }
            ),
            ("New Folder…", Icon.group, nil, { ws.folderEditor = FolderEditor(kind: .create(parent: [])) }),
            ("Query History…", Icon.history, "⌘Y", { ws.isHistoryPresented = true }),
            ("Snippets…", Icon.snippet, "⌘⇧K", { ws.isSnippetsPresented = true }),
            ("Export Result…", Icon.export, "⌘⌥E", { ws.isExportPresented = true }),
            ("Import from CSV…", Icon.importData, nil, { controller.importCSV() }),
            ("Structure Sync…", Icon.structure, nil, { ws.isStructureSyncPresented = true }),
            ("Run", Icon.run, "⌘R", { controller.run(all: false) }),
            ("Run Selected", Icon.run, "⌘⇧R", { controller.runSelection() }),
            ("Run All", Icon.runAll, "⌘⌥R", { controller.run(all: true) }),
            ("Explain Statement", Icon.explain, "⌘⇧E", { controller.explain(analyze: false) }),
            ("Beautify SQL", Icon.format, "⌘⇧I", { controller.formatSQL() }),
            ("Commit", Icon.commit, "⌘⇧S", { controller.commit() }),
            ("Rollback", Icon.rollback, "⌘⇧⌫", { controller.rollback() }),
            ("Refresh", Icon.refresh, "F5", { controller.refresh() }),
            ("Toggle Inspector", Icon.inspector, "⌘⌥I", { ws.isInspectorVisible.toggle() }),
            ("Toggle Filter Bar", Icon.filter, "⌘⇧F", { ws.isFilterBarVisible.toggle() }),
            ("Toggle Sidebar", Icon.sidebar, "⌘⌥S", { controller.isSidebarVisible.toggle() }),
            ("Toggle Read-Only", Icon.lock, "⌘⇧L", { controller.toggleReadOnly() }),
            ("Close Tab", Icon.close, "⌘W", { controller.closeSelectedTab() }),
        ]
        for (title, icon, shortcut, run) in actions {
            commands.append(
                PaletteCommand(
                    id: "action-\(title)", group: .actions, title: title, icon: icon, shortcut: shortcut, run: run
                ))
        }
        return commands
    }

    private var matches: [PaletteCommand] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = allCommands
        guard !needle.isEmpty else {
            // With nothing typed: the open tabs, then the actions. Tables wait for a word.
            return all.filter { $0.group == .tabs || $0.group == .actions }
        }
        // Every typed word must land somewhere in the title or subtitle; the best fit
        // first, then by group.
        let ordered = all.sorted { $0.group.rawValue < $1.group.rawValue }
        return Array(
            FuzzyMatch.filter(ordered, query: needle, text: { $0.title + " " + ($0.subtitle ?? "") }).prefix(60))
    }

    private func runHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        let command = matches[highlighted]
        workspace.isCommandPalettePresented = false
        command.run()
    }
}
