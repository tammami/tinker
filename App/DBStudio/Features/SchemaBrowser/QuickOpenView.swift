import DBCore
import SwiftUI

/// The table quick-switcher (⌘⇧O), matching names across every connected database.
public struct QuickOpenView: View {
    @Bindable var workspace: WorkspaceModel
    let sidebar: SidebarModel
    let onOpen: (TableRef, UUID) -> Void

    @State private var highlighted = 0
    @FocusState private var isFieldFocused: Bool

    public var body: some View {
        VStack(spacing: 0) {
            TextField("Table name", text: $workspace.quickOpenQuery)
                .textFieldStyle(.plain)
                .font(.title3)
                .padding(12)
                .focused($isFieldFocused)
                .onSubmit(openHighlighted)
            Divider()
            if matches.isEmpty {
                Text(sidebar.knownTables.isEmpty
                    ? "Expand a schema in the sidebar first, so there is something to search."
                    : "No table matches")
                    .foregroundStyle(.secondary)
                    .padding(20)
            } else {
                ScrollViewReader { proxy in
                    List(Array(matches.enumerated()), id: \.offset) { index, match in
                        HStack(spacing: 8) {
                            Image(systemName: match.table.kind.symbolName)
                                .foregroundStyle(.secondary)
                            Text(match.table.name)
                            Text(match.table.ref.schema)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Spacer()
                            Text(connectionName(match.connection))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                        .listRowBackground(
                            index == highlighted
                                ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.3)
                                : Color.clear
                        )
                        .id(index)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            highlighted = index
                            openHighlighted()
                        }
                    }
                    .listStyle(.plain)
                    .frame(height: 320)
                    .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
                }
            }
        }
        .frame(width: 520)
        .onAppear { isFieldFocused = true }
        .onChange(of: workspace.quickOpenQuery) { _, _ in highlighted = 0 }
        .onKeyPress(.upArrow) {
            highlighted = max(0, highlighted - 1)
            return .handled
        }
        .onKeyPress(.downArrow) {
            highlighted = min(matches.count - 1, highlighted + 1)
            return .handled
        }
        .onKeyPress(.escape) {
            workspace.isQuickOpenPresented = false
            return .handled
        }
    }

    var matches: [(connection: UUID, table: TableInfo)] {
        sidebar.quickOpenMatches(workspace.quickOpenQuery)
    }

    func connectionName(_ id: UUID) -> String {
        workspace.environment.connections.first { $0.id == id }?.name ?? ""
    }

    func openHighlighted() {
        guard matches.indices.contains(highlighted) else { return }
        let match = matches[highlighted]
        workspace.isQuickOpenPresented = false
        workspace.quickOpenQuery = ""
        onOpen(match.table.ref, match.connection)
    }
}
