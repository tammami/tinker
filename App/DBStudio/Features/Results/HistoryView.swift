import DBCore
import DBStore
import SwiftUI

/// The query history panel (⌘Y), searchable and double-click to reuse.
public struct HistoryView: View {
    let environment: AppEnvironment
    let connectionID: UUID?
    let onInsert: (String) -> Void
    let onDismiss: () -> Void

    @State private var entries: [QueryHistoryEntry] = []
    @State private var search = ""
    @State private var onlyThisConnection = true
    @State private var selection: QueryHistoryEntry.ID?

    public var body: some View {
        SheetFrame(
            title: "Query History",
            icon: Icon.history,
            subtitle: "Every statement this Mac has run, newest first. Double-click to put one in the editor.",
            width: DesignTokens.Metrics.wideSheetWidth + 80,
            contentInset: 0
        ) {
            VStack(spacing: 0) {
                PaneBar {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        Image(systemName: Icon.search).foregroundStyle(.secondary)
                        TextField("Search statements", text: $search).textFieldStyle(.plain)
                    }
                    .padding(.horizontal, DesignTokens.Spacing.sm)
                    .frame(width: 260, height: 24)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                    .overlay(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
                    Toggle("This connection only", isOn: $onlyThisConnection).toggleStyle(.checkbox)
                    Spacer()
                    Text("\(entries.count) entr\(entries.count == 1 ? "y" : "ies")").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    Button(role: .destructive) {
                        Task {
                            await environment.clearHistory()
                            await reload()
                        }
                    } label: {
                        Label("Clear", systemImage: Icon.delete)
                    }
                    .disabled(entries.isEmpty)
                }
                .controlSize(.small)
                Divider()

                if entries.isEmpty {
                    EmptyStateView(icon: Icon.history, title: "No history yet",
                                   message: search.isEmpty ? "Statements appear here after they run." : "Nothing matches “\(search)”.")
                        .frame(height: 380)
                } else {
                    Table(entries, selection: $selection) {
                        TableColumn("When") { entry in
                            Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                                .font(.caption)
                        }
                        .width(150)
                        TableColumn("Statement") { entry in
                            Text(entry.sql.split(whereSeparator: \.isNewline).joined(separator: " "))
                                .font(.system(.caption, design: .monospaced))
                                .lineLimit(1)
                        }
                        TableColumn("Rows") { entry in
                            Text(entry.rowCount.map(String.init) ?? "—").font(.caption).monospacedDigit()
                        }
                        .width(60)
                        TableColumn("Time") { entry in
                            Text(entry.duration.map(QueryTabController.format) ?? "—").font(.caption).monospacedDigit()
                        }
                        .width(70)
                        TableColumn("Result") { entry in
                            if entry.succeeded {
                                Image(systemName: Icon.success).foregroundStyle(.green)
                            } else {
                                Label(entry.error ?? "failed", systemImage: Icon.error)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            }
                        }
                        .width(180)
                    }
                    .frame(height: 380)
                    .contextMenu(forSelectionType: QueryHistoryEntry.ID.self) { selection in
                        if let id = selection.first, let entry = entries.first(where: { $0.id == id }) {
                            Button { onInsert(entry.sql) } label: { Label("Insert into Editor", systemImage: Icon.query) }
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(entry.sql, forType: .string)
                            } label: {
                                Label("Copy", systemImage: Icon.copy)
                            }
                        }
                    } primaryAction: { selection in
                        if let id = selection.first, let entry = entries.first(where: { $0.id == id }) {
                            onInsert(entry.sql)
                        }
                    }
                }
            }
        } footer: {
            Spacer()
            Button("Close", action: onDismiss).keyboardShortcut(.cancelAction)
            Button {
                if let id = selection, let entry = entries.first(where: { $0.id == id }) { onInsert(entry.sql) }
            } label: {
                Label("Insert", systemImage: Icon.query)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(selection == nil)
        }
        .task { await reload() }
        .onChange(of: onlyThisConnection) { _, _ in Task { await reload() } }
        .onChange(of: search) { _, _ in Task { await reload() } }
    }

    func reload() async {
        entries = await environment.history(
            connectionID: onlyThisConnection ? connectionID : nil,
            matching: search.isEmpty ? nil : search
        )
    }
}
