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

/// The export sheet.
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
    @State private var datesFileName = false
    @State private var outcome: Outcome?

    /// What a finished export shows.
    struct Outcome {
        let url: URL
        let rows: Int64
        let seconds: String
    }

    public var body: some View {
        SheetFrame(
            title: "Export \(table?.name ?? "result")",
            icon: Icon.export,
            subtitle: "Rows are written as they arrive, so a large table never has to fit in memory.",
            contentInset: 0
        ) {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Picker("Format", selection: $options.format) {
                            ForEach(ExportFormat.allCases) { format in
                                Text(format.displayName).tag(format)
                            }
                        }
                        Picker("Rows", selection: $scope) {
                            ForEach(ExportScope.allCases) { value in
                                Text(value.title + (value == .loadedRows ? " (\(loadedRowCount))" : "")).tag(value)
                            }
                        }
                        .onChange(of: scope) { _, new in
                            if new == .selection, !hasSelection { scope = .loadedRows }
                        }
                    }

                    Section {
                        switch options.format {
                        case .csv:
                            Picker("Delimiter", selection: $delimiterText) {
                                Text("Comma").tag(",")
                                Text("Semicolon").tag(";")
                                Text("Tab").tag("\t")
                                Text("Pipe").tag("|")
                            }
                            .onChange(of: delimiterText) { _, new in
                                options.delimiter = new.first ?? ","
                            }
                            Toggle("Include header row", isOn: $options.includeHeader)
                            TextField("NULL as", text: $options.nullText, prompt: Text("empty"))
                            Toggle("UTF-8 byte-order mark (for Excel)", isOn: $options.writeByteOrderMark)
                            Toggle("Keep spreadsheets from running cells as formulas", isOn: $options.guardFormulas)
                                .help("A value starting with =, +, - or @ gets a leading apostrophe")
                        case .xlsx:
                            Toggle("Include header row", isOn: $options.includeHeader)
                            Text(
                                "One worksheet, numbers as numbers, the header in bold. Excel holds 1,048,576 rows per sheet."
                            )
                            .font(.caption).foregroundStyle(.secondary)
                        case .sqlInsert:
                            TextField("Rows per statement", value: $options.batchSize, format: .number)
                            Toggle("Include CREATE TABLE", isOn: $options.includeCreateTable)
                        case .json, .ndjson:
                            Text("One JSON value per row, with column names as keys.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Add today's date to the file name", isOn: $datesFileName)
                    } header: {
                        Text("Options")
                    }
                }
                .formStyle(.grouped)
                .frame(height: 370)

                if let outcome {
                    // The receipt: what was written, where, and a way to it.
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        Image(systemName: Icon.success).foregroundStyle(.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wrote \(outcome.rows) row\(outcome.rows == 1 ? "" : "s") in \(outcome.seconds)")
                                .font(.callout.weight(.semibold))
                            Text(outcome.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer()
                        Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([outcome.url]) }
                        Button("Open") { NSWorkspace.shared.open(outcome.url) }
                    }
                    .controlSize(.small)
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.md)
                }

                if isRunning {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(progress.isEmpty ? "Writing…" : progress).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.md)
                }
                if let failure {
                    InlineBanner(kind: .error, message: failure) { self.failure = nil }
                }
            }
        } footer: {
            Spacer()
            Button(outcome == nil ? "Cancel" : "Done", role: .cancel) {
                exportTask?.cancel()
                onDismiss()
            }
            .keyboardShortcut(.cancelAction)
            Button {
                chooseDestination()
            } label: {
                Label("Export…", systemImage: Icon.export)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)
        }
    }

    func chooseDestination() {
        let panel = NSSavePanel()
        var name = table?.name ?? "result"
        if datesFileName {
            let stamp = Date().formatted(.iso8601.year().month().day().dateSeparator(.dash))
            name += " \(stamp)"
        }
        panel.nameFieldStringValue = "\(name).\(options.format.fileExtension)"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var resolved = options
        resolved.dialect = dialect
        resolved.table = table
        resolved.sheetTitle = table?.name ?? "Result"
        isRunning = true
        outcome = nil
        failure = nil
        exportTask = Task { await run(to: url, options: resolved) }
    }

    func run(to url: URL, options: ExportOptions) async {
        let started = ContinuousClock.now
        do {
            let exporter = try RowExporter(url: url, options: options)
            try exporter.begin(columns: columns)
            switch scope {
            case .selection:
                exporter.write(rows: selectionRows())
            case .loadedRows:
                exporter.write(rows: loadedRows())
            case .everything:
                // Rows are written as they arrive, so memory stays flat.
                try await streamAll { batch in
                    exporter.write(rows: batch)
                    progress = "Wrote \(exporter.writtenRowCount) rows"
                }
            }
            try exporter.finish()
            progress = ""
            isRunning = false
            outcome = Outcome(
                url: url, rows: exporter.writtenRowCount,
                seconds: started.duration(to: .now).formatted(
                    .units(allowed: [.seconds, .milliseconds], width: .narrow)))
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
            isRunning = false
        }
    }
}
