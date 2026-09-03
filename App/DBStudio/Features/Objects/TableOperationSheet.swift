import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// The sheet behind Rename, Duplicate, Maintenance and Import from CSV.
///
/// Each one shows the exact statement before it runs. Rename and duplicate are structure
/// changes and go through the same confirmation as everything else that alters a table.
struct TableOperationSheet: View {
    let request: TableOperationRequest
    let environment: AppEnvironment
    /// Called with the table to open afterwards, when there is one.
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    var body: some View {
        switch request.kind {
        case .rename:
            RenameTableSheet(request: request, environment: environment, onFinished: onFinished, onCancel: onCancel)
        case .duplicate:
            DuplicateTableSheet(request: request, environment: environment, onFinished: onFinished, onCancel: onCancel)
        case let .maintenance(action):
            MaintenanceSheet(request: request, action: action, environment: environment, onFinished: onFinished, onCancel: onCancel)
        case .importCSV:
            ImportCSVSheet(request: request, environment: environment, onFinished: onFinished, onCancel: onCancel)
        }
    }
}

/// Runs statements on a leased connection and reports what the server said.
@MainActor
private enum OperationRunner {
    static func run(
        _ statements: [String], connectionID: UUID, environment: AppEnvironment
    ) async throws -> QueryResult? {
        guard let session = environment.session(for: connectionID) else { throw DBError.notConnected }
        if await session.isReadOnly {
            throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L first.")
        }
        _ = try await session.connect()
        let (lease, connection) = try await session.lease()
        defer { Task { await session.release(lease) } }
        var last: QueryResult?
        for statement in statements {
            last = try await connection.executeCollecting(statement)
        }
        await session.invalidateIntrospection()
        return last
    }

    static func dialect(_ connectionID: UUID, _ environment: AppEnvironment) -> SQLDialect {
        environment.connections.first { $0.id == connectionID }?.dialect ?? .postgresql
    }

    static func isProduction(_ connectionID: UUID, _ environment: AppEnvironment) -> Bool {
        environment.connections.first { $0.id == connectionID }?.isProduction ?? false
    }
}

// MARK: - Rename

private struct RenameTableSheet: View {
    let request: TableOperationRequest
    let environment: AppEnvironment
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var failure: String?
    @State private var isRunning = false

    private var dialect: SQLDialect { OperationRunner.dialect(request.connectionID, environment) }
    private var statement: String { TableOperations.rename(request.table, to: name, dialect: dialect) }
    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != request.table.name
    }

    var body: some View {
        SheetFrame(title: "Rename \(request.table.name)", icon: Icon.rename,
                   subtitle: "Views, foreign keys and code that name the table are not updated.") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "New name") {
                    TextField("name", text: $name).textFieldStyle(.roundedBorder)
                }
                StatementPreview(sql: statement)
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            if OperationRunner.isProduction(request.connectionID, environment) {
                Label("Production", systemImage: Icon.production).foregroundStyle(.red).font(.callout.weight(.semibold))
            }
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button(isRunning ? "Renaming…" : "Rename") { Task { await run() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isRunning)
        }
        .onAppear { name = request.table.name }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        do {
            _ = try await OperationRunner.run([statement], connectionID: request.connectionID, environment: environment)
            onFinished(TableRef(database: request.table.database, schema: request.table.schema, name: name.trimmingCharacters(in: .whitespaces)))
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

// MARK: - Duplicate

private struct DuplicateTableSheet: View {
    let request: TableOperationRequest
    let environment: AppEnvironment
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    @State private var name = ""
    @State private var includeData = false
    @State private var failure: String?
    @State private var isRunning = false

    private var dialect: SQLDialect { OperationRunner.dialect(request.connectionID, environment) }
    private var statements: [String] {
        TableOperations.duplicate(request.table, to: name, includeData: includeData, dialect: dialect)
    }
    private var isValid: Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed != request.table.name
    }

    var body: some View {
        SheetFrame(title: "Duplicate \(request.table.name)", icon: Icon.duplicate,
                   subtitle: "Copies the columns, defaults, constraints and indexes. Foreign keys are not copied.") {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "New table") {
                    TextField("name", text: $name).textFieldStyle(.roundedBorder)
                }
                FieldRow(label: "") {
                    Toggle("Copy the rows as well", isOn: $includeData)
                }
                StatementPreview(sql: statements.joined(separator: ";\n") + ";")
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            if OperationRunner.isProduction(request.connectionID, environment) {
                Label("Production", systemImage: Icon.production).foregroundStyle(.red).font(.callout.weight(.semibold))
            }
            Spacer()
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button(isRunning ? "Duplicating…" : "Duplicate") { Task { await run() } }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(!isValid || isRunning)
        }
        .onAppear { name = request.table.name + "_copy" }
    }

    private func run() async {
        isRunning = true
        defer { isRunning = false }
        do {
            _ = try await OperationRunner.run(statements, connectionID: request.connectionID, environment: environment)
            onFinished(TableRef(database: request.table.database, schema: request.table.schema, name: name.trimmingCharacters(in: .whitespaces)))
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

// MARK: - Maintenance

private struct MaintenanceSheet: View {
    let request: TableOperationRequest
    let action: MaintenanceAction
    let environment: AppEnvironment
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    @State private var failure: String?
    @State private var isRunning = false
    @State private var output: QueryResult?
    @State private var elapsed: Duration?

    private var dialect: SQLDialect { OperationRunner.dialect(request.connectionID, environment) }
    private var statement: String? { TableOperations.maintenance(action, on: request.table, dialect: dialect) }

    var body: some View {
        SheetFrame(title: "\(action.title) \(request.table.name)", icon: Icon.maintenance, subtitle: action.summary) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if let statement {
                    StatementPreview(sql: statement)
                } else {
                    InlineBanner(kind: .warning, message: "This engine has no \(action.title.lowercased()) for tables.", onDismiss: {})
                }
                if let output, !output.rows.isEmpty {
                    SimpleTable(
                        columns: output.columns.map { SimpleTable.Column(title: $0.name, width: 140) },
                        rows: output.rows.map { row in row.map { ClipboardFormatter.cellText($0, nullText: "NULL") } }
                    )
                    .frame(height: 120)
                } else if let elapsed {
                    InlineBanner(kind: .success, message: "Done in \(QueryTabController.format(elapsed))", onDismiss: {})
                }
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            Spacer()
            Button(elapsed == nil ? "Cancel" : "Close", action: onCancel).keyboardShortcut(.cancelAction)
            if elapsed == nil {
                Button(isRunning ? "Running…" : "Run") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(statement == nil || isRunning)
            }
        }
    }

    private func run() async {
        guard let statement else { return }
        isRunning = true
        defer { isRunning = false }
        let start = ContinuousClock.now
        do {
            output = try await OperationRunner.run([statement], connectionID: request.connectionID, environment: environment)
            elapsed = start.duration(to: .now)
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

// MARK: - Import

/// Import from CSV: pick a file, see its first rows, map its columns onto the table's,
/// and load it in one transaction.
private struct ImportCSVSheet: View {
    let request: TableOperationRequest
    let environment: AppEnvironment
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    @State private var fileURL: URL?
    @State private var data: Data?
    @State private var preview: [[String]] = []
    @State private var columns: [ColumnInfo] = []
    @State private var mapping: [String?] = []
    @State private var hasHeader = true
    @State private var delimiter = ","
    @State private var nullText = ""
    @State private var failure: String?
    @State private var isRunning = false
    @State private var insertedCount: Int64?
    @State private var progressCount: Int64 = 0

    private var dialect: SQLDialect { OperationRunner.dialect(request.connectionID, environment) }
    private var header: [String] { preview.first ?? [] }
    private var mappedCount: Int { mapping.compactMap { $0 }.count }

    var body: some View {
        SheetFrame(
            title: "Import into \(request.table.name)",
            icon: Icon.importData,
            subtitle: "Rows are inserted in one transaction. If any value does not fit its column, nothing is changed.",
            width: DesignTokens.Metrics.wideSheetWidth
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button {
                        chooseFile()
                    } label: {
                        Label(fileURL == nil ? "Choose CSV File…" : "Choose Another…", systemImage: Icon.open)
                    }
                    if let fileURL {
                        Text(fileURL.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                        if let data {
                            Text(ObjectsView.size(Int64(data.count))).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Toggle("First row is a header", isOn: $hasHeader)
                        .onChange(of: hasHeader) { _, _ in rebuildMapping() }
                    Picker("Delimiter", selection: $delimiter) {
                        Text("Comma").tag(",")
                        Text("Semicolon").tag(";")
                        Text("Tab").tag("\t")
                        Text("Pipe").tag("|")
                    }
                    .frame(width: 150)
                    .onChange(of: delimiter) { _, _ in reparse() }
                }
                .controlSize(.small)

                if !preview.isEmpty {
                    mappingTable
                    HStack {
                        FieldRow(label: "NULL when", labelWidth: 80) {
                            TextField("empty", text: $nullText).textFieldStyle(.roundedBorder).frame(width: 120)
                        }
                        Spacer()
                        Text("\(mappedCount) of \(header.count) CSV column\(header.count == 1 ? "" : "s") mapped")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else {
                    EmptyStateView(icon: Icon.importData, title: "Choose a file to begin",
                                   message: "The first rows are shown so you can check the columns line up.")
                        .frame(height: 200)
                }

                if isRunning {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Inserted \(progressCount) rows…").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                if let insertedCount {
                    InlineBanner(kind: .success, message: "Imported \(insertedCount) row\(insertedCount == 1 ? "" : "s") into \(request.table.name).", onDismiss: {})
                }
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            if OperationRunner.isProduction(request.connectionID, environment) {
                Label("Production", systemImage: Icon.production).foregroundStyle(.red).font(.callout.weight(.semibold))
            }
            Spacer()
            Button(insertedCount == nil ? "Cancel" : "Close") {
                insertedCount == nil ? onCancel() : onFinished(request.table)
            }
            .keyboardShortcut(.cancelAction)
            if insertedCount == nil {
                Button(isRunning ? "Importing…" : "Import") { Task { await run() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(data == nil || mappedCount == 0 || isRunning)
            }
        }
        .task { await loadColumns() }
    }

    /// The CSV's columns down the left, the table column each one fills, and a sample.
    private var mappingTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Text("CSV column").frame(width: 200, alignment: .leading)
                Text("Table column").frame(width: 200, alignment: .leading)
                Text("Sample").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: DesignTokens.Metrics.gridHeaderHeight)
            .background(.bar)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(header.enumerated()), id: \.offset) { index, name in
                        HStack(spacing: 0) {
                            Text(hasHeader ? name : "Column \(index + 1)")
                                .lineLimit(1)
                                .frame(width: 200, alignment: .leading)
                            Picker("Target", selection: Binding(
                                get: { mapping.indices.contains(index) ? (mapping[index] ?? "") : "" },
                                set: { value in if mapping.indices.contains(index) { mapping[index] = value.isEmpty ? nil : value } }
                            )) {
                                Text("Skip").tag("")
                                ForEach(columns) { column in
                                    Text("\(column.name)  ·  \(column.nativeType)").tag(column.name)
                                }
                            }
                            .labelsHidden()
                            .controlSize(.small)
                            .frame(width: 190, alignment: .leading)
                            .padding(.trailing, DesignTokens.Spacing.sm + 2)
                            Text(sample(at: index))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .frame(height: 28)
                        .background(index.isMultiple(of: 2) ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
                    }
                }
            }
            .frame(height: min(CGFloat(max(3, header.count)) * 28, 224))
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func sample(at index: Int) -> String {
        let rows = hasHeader ? preview.dropFirst() : preview[...]
        return rows.prefix(3).compactMap { $0.indices.contains(index) ? $0[index] : nil }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText, .tabSeparatedText, .plainText]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        failure = nil
        insertedCount = nil
        do {
            // Mapped, not read: the file's bytes are paged in as the reader walks them.
            data = try Data(contentsOf: url, options: .mappedIfSafe)
            reparse()
        } catch {
            failure = String(describing: error)
        }
    }

    private func reparse() {
        guard let data else { return }
        var reader = CSVReader(data: data, delimiter: delimiter.first ?? ",")
        var rows: [[String]] = []
        while rows.count < 6, let row = reader.next() { rows.append(row) }
        preview = rows
        rebuildMapping()
    }

    private func rebuildMapping() {
        guard !columns.isEmpty, !header.isEmpty else { return }
        if hasHeader {
            mapping = CSVImportPlan.matched(header: header, to: columns, table: request.table).mapping
        } else {
            // Positional: the first CSV column fills the first table column, and so on.
            mapping = header.indices.map { $0 < columns.count ? columns[$0].name : nil }
        }
    }

    private func loadColumns() async {
        guard let session = environment.session(for: request.connectionID) else { return }
        let table = request.table
        columns = (try? await session.introspection(.columns(table)) { try await $0.columns(of: table) }) ?? []
        rebuildMapping()
    }

    private func run() async {
        guard let data, let session = environment.session(for: request.connectionID) else { return }
        isRunning = true
        progressCount = 0
        failure = nil
        defer { isRunning = false }
        let plan = CSVImportPlan(table: request.table, mapping: mapping, hasHeader: hasHeader, nullText: nullText)
        let importer = CSVImporter(plan: plan, columns: columns, dialect: dialect)
        var reader = CSVReader(data: data, delimiter: delimiter.first ?? ",")
        do {
            if await session.isReadOnly {
                throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L first.")
            }
            _ = try await session.connect()
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            let count = try await importer.run(reader: &reader, on: connection) { done in
                Task { @MainActor in progressCount = done }
            }
            await session.invalidateIntrospection(.rowCount(request.table))
            insertedCount = count
        } catch {
            failure = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }
}

/// The statement a sheet is about to run, shown as it will be sent.
struct StatementPreview: View {
    let sql: String

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Statement").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                Text(sql)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignTokens.Spacing.sm)
            }
            .frame(maxHeight: 140)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
            .overlay(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius).strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}
