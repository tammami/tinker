import DBCore
import DBGrid
import DBSQL
import SwiftUI

/// What is being exported.
public enum ExportScope: String, CaseIterable, Identifiable, Sendable {
    case selection
    case loadedRows
    case everything

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .selection: "Selection"
        case .loadedRows: "Loaded rows"
        case .everything: "Entire table or query"
        }
    }
}

/// The export sheet (SPEC §14).
public struct ExportView: View {
    let columns: [ColumnMeta]
    let dialect: SQLDialect
    let table: TableRef?
    let hasSelection: Bool
    let loadedRowCount: Int
    /// Streams every row for the `.everything` scope, calling `write` per batch.
    let streamAll: @MainActor (@escaping @MainActor ([[DBValue]]) -> Void) async throws -> Void
    let selectionRows: () -> [[DBValue]]
    let loadedRows: () -> [[DBValue]]
    let onDismiss: () -> Void

    @State private var options = ExportOptions()
    @State private var scope: ExportScope = .loadedRows
    @State private var delimiterText = ","
    @State private var isRunning = false
    @State private var progress = ""
    @State private var failure: String?
    @State private var exportTask: Task<Void, Never>?

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export").font(.headline)

            Form {
                Picker("Format", selection: $options.format) {
                    ForEach(ExportFormat.allCases) { format in
                        Text(format.displayName).tag(format)
                    }
                }
                Picker("Rows", selection: $scope) {
                    ForEach(ExportScope.allCases) { value in
                        Text(value.title).tag(value)
                    }
                }
                .onChange(of: scope) { _, new in
                    if new == .selection, !hasSelection { scope = .loadedRows }
                }

                switch options.format {
                case .csv:
                    TextField("Delimiter", text: $delimiterText)
                        .onChange(of: delimiterText) { _, new in
                            options.delimiter = new.first ?? ","
                        }
                    Toggle("Include header row", isOn: $options.includeHeader)
                    TextField("NULL as", text: $options.nullText)
                    Toggle("UTF-8 byte-order mark (for Excel)", isOn: $options.writeByteOrderMark)
                case .sqlInsert:
                    TextField("Rows per statement", value: $options.batchSize, format: .number)
                    Toggle("Include CREATE TABLE", isOn: $options.includeCreateTable)
                case .json, .ndjson:
                    EmptyView()
                }
            }
            .formStyle(.grouped)

            if isRunning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text(progress).font(.caption).foregroundStyle(.secondary)
                }
            }
            if let failure {
                ErrorBanner(message: failure) { self.failure = nil }
            }

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) {
                    exportTask?.cancel()
                    onDismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("Export…") { chooseDestination() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isRunning)
            }
        }
        .padding(16)
        .frame(width: 460)
    }

    func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(table?.name ?? "export").\(options.format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var resolved = options
        resolved.dialect = dialect
        resolved.table = table
        isRunning = true
        exportTask = Task { await run(to: url, options: resolved) }
    }

    func run(to url: URL, options: ExportOptions) async {
        do {
            let exporter = try RowExporter(url: url, options: options)
            exporter.begin(columns: columns)
            switch scope {
            case .selection:
                exporter.write(rows: selectionRows())
            case .loadedRows:
                exporter.write(rows: loadedRows())
            case .everything:
                // Rows are written as they arrive, so memory stays flat (SPEC §14).
                try await streamAll { batch in
                    exporter.write(rows: batch)
                }
            }
            try exporter.finish()
            progress = "Wrote \(exporter.writtenRowCount) rows"
            isRunning = false
            onDismiss()
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
            isRunning = false
        }
    }
}
