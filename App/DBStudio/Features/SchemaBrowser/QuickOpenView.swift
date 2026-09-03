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
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: Icon.search).foregroundStyle(.secondary)
                TextField("Table name", text: $workspace.quickOpenQuery)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isFieldFocused)
                    .onSubmit(openHighlighted)
                KeyCap(keys: "esc")
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
            Divider()
            if matches.isEmpty {
                EmptyStateView(
                    icon: Icon.table,
                    title: sidebar.knownTables.isEmpty ? "Nothing to search yet" : "No table matches",
                    message: sidebar.knownTables.isEmpty
                        ? "Expand a schema in the sidebar first, so its tables are known."
                        : "Try fewer letters; matching is fuzzy, so “usr” finds “users”."
                )
                .frame(height: 220)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(matches.enumerated()), id: \.offset) { index, match in
                                HStack(spacing: DesignTokens.Spacing.sm) {
                                    Image(systemName: match.table.kind.symbolName)
                                        .foregroundStyle(index == highlighted ? Color.accentColor : .secondary)
                                        .frame(width: DesignTokens.Metrics.iconWidth)
                                    Text(match.table.name)
                                    Text(match.table.ref.schema)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                    Spacer()
                                    if let count = match.table.approximateRowCount {
                                        Text("~\(count)").font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                    Text(connectionName(match.connection))
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                                .padding(.horizontal, DesignTokens.Spacing.lg)
                                .frame(height: 28)
                                .background(index == highlighted ? Color.accentColor.opacity(0.14) : .clear)
                                .contentShape(Rectangle())
                                .id(index)
                                .onTapGesture {
                                    highlighted = index
                                    openHighlighted()
                                }
                            }
                        }
                        .padding(.vertical, DesignTokens.Spacing.xs)
                    }
                    .frame(height: 320)
                    .onChange(of: highlighted) { _, new in proxy.scrollTo(new) }
                }
            }
            Divider()
            SheetHintBar(hints: [("↑↓", "move"), ("↩", "open")]) {
                Text("\(sidebar.knownTables.count) table\(sidebar.knownTables.count == 1 ? "" : "s") known")
            }
        }
        .frame(width: 560)
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
