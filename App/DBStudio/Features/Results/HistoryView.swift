import DBCore
import DBStore
import SwiftUI

/// The query history panel (⌘Y), searchable and double-click to reuse (SPEC §13.2).
public struct HistoryView: View {
    let environment: AppEnvironment
    let connectionID: UUID?
    let onInsert: (String) -> Void
    let onDismiss: () -> Void

    @State private var entries: [QueryHistoryEntry] = []
    @State private var search = ""
    @State private var onlyThisConnection = true

    public var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search history", text: $search)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await reload() } }
                Toggle("This connection", isOn: $onlyThisConnection)
                    .toggleStyle(.checkbox)
                Button("Clear…", role: .destructive) {
                    Task {
                        await environment.clearHistory()
                        await reload()
                    }
                }
                Button("Done", action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()

            Table(entries) {
                TableColumn("When") { entry in
                    Text(entry.startedAt.formatted(date: .abbreviated, time: .standard))
                        .font(.caption)
                }
                .width(160)
                TableColumn("Statement") { entry in
                    Text(entry.sql.split(whereSeparator: \.isNewline).joined(separator: " "))
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                }
                TableColumn("Rows") { entry in
                    Text(entry.rowCount.map(String.init) ?? "—").font(.caption)
                }
                .width(60)
                TableColumn("Time") { entry in
                    Text(entry.duration.map(QueryTabController.format) ?? "—").font(.caption)
                }
                .width(80)
                TableColumn("Result") { entry in
                    if entry.succeeded {
                        Image(systemName: "checkmark.circle").foregroundStyle(.green)
                    } else {
                        Text(entry.error ?? "failed")
                            .font(.caption)
                            .foregroundStyle(.red)
                            .lineLimit(1)
                    }
                }
                .width(160)
            }
            .contextMenu(forSelectionType: QueryHistoryEntry.ID.self) { selection in
                if let id = selection.first, let entry = entries.first(where: { $0.id == id }) {
                    Button("Insert into Editor") { onInsert(entry.sql) }
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.sql, forType: .string)
                    }
                }
            } primaryAction: { selection in
                if let id = selection.first, let entry = entries.first(where: { $0.id == id }) {
                    onInsert(entry.sql)
                }
            }
        }
        .frame(width: 820, height: 460)
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
