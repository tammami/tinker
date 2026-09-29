import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// Import Data: pick a file, see what it holds and what the table expects, choose for
/// each table column the file column that fills it, and load the rows.
///
/// The mapping is laid out from the table's side — one row per table column, as the
/// table lists them — because the table is what has to end up right: a column that must
/// be filled and is not shows at a glance, and one file column can fill two.
struct ImportDataSheet: View {
    let request: TableOperationRequest
    let environment: AppEnvironment
    let onFinished: (TableRef?) -> Void
    let onCancel: () -> Void

    @State private var fileURL: URL?
    /// The file as it is on disk, mapped.
    @State private var raw: Data?
    /// The file's text as UTF-8, which the CSV and JSON readers walk. The same bytes as
    /// `raw` when the file is UTF-8 already.
    @State private var text: Data?
    @State private var format: TabularFormat = .delimited(",")
    /// An `.xlsx` file, opened once when chosen; the preview and the import both read it.
    @State private var workbook: XLSXWorkbook?
    @State private var detectedEncoding: ImportTextEncoding = .utf8
    /// `auto`, or the raw value of the encoding the user chose.
    @State private var encodingChoice = Self.automatic
    @State private var delimiter = ","
    @State private var hasHeader = true
    @State private var preview: [[String]] = []
    @State private var columns: [ColumnInfo] = []
    /// Table column → the file column that fills it.
    @State private var sources: [String: Int] = [:]
    @State private var nullText = ""
    @State private var commitEvery = 0
    @State private var removesFormulaGuard = false
    @State private var failure: String?
    @State private var isPreparing = false
    @State private var isRunning = false
    @State private var insertedCount: Int64?
    @State private var progressCount: Int64 = 0

    private static let automatic = "auto"
    private static let skip = -1
    private static let previewRows = 6
    private static let rowHeight = DesignTokens.Metrics.gridHeaderHeight + DesignTokens.Spacing.xs
    /// Key, table column, type, file column; the sample takes what is left.
    private static let widths: [CGFloat] = [DesignTokens.Metrics.iconWidth, 170, 150, 190]

    private var config: ConnectionConfig? { environment.connections.first { $0.id == request.connectionID } }
    private var dialect: SQLDialect { config?.dialect ?? .postgresql }
    private var productionName: String? { config?.isProduction == true ? config?.name : nil }

    private var isJSON: Bool { format == .json }
    private var isWorkbook: Bool { format == .xlsx }
    private var isDelimited: Bool { !isJSON && !isWorkbook }
    /// What the file's columns are called: they are not CSV in a workbook.
    private var sourceNoun: String { isWorkbook ? "Excel" : isJSON ? "JSON" : "CSV" }
    private var encoding: ImportTextEncoding {
        ImportTextEncoding(rawValue: encodingChoice) ?? detectedEncoding
    }

    /// How many columns the file has: its widest row among the first few.
    private var sourceCount: Int { preview.map(\.count).max() ?? 0 }
    private var dataRows: ArraySlice<[String]> { hasHeader ? preview.dropFirst() : preview[...] }

    private var assignments: [ImportAssignment] {
        columns.compactMap { column in
            guard !column.isGenerated, let source = sources[column.name], source >= 0, source < sourceCount else {
                return nil
            }
            return ImportAssignment(column: column.name, source: source)
        }
    }

    private var missingRequired: [ColumnInfo] {
        CSVImportPlan.missingRequired(assignments, columns: columns)
    }

    var body: some View {
        SheetFrame(
            title: "Import into \(request.table.name)",
            icon: Icon.importData,
            subtitle:
                "CSV, TSV, Excel (.xlsx), JSON or JSON Lines. The file is mapped, not loaded, and rows go in as they are read.",
            width: DesignTokens.Metrics.wideSheetWidth
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                endpoints
                if raw != nil { readingOptions }

                if !preview.isEmpty {
                    mappingTable
                    mappingActions
                    importOptions
                    if !missingRequired.isEmpty, insertedCount == nil {
                        InlineBanner(
                            kind: .warning,
                            message:
                                "Not filled, NOT NULL and without a default: "
                                + missingRequired.map(\.name).joined(separator: ", "),
                            detail: "The server refuses a row that leaves these out, unless a trigger fills them.",
                            onDismiss: {})
                    }
                } else if isPreparing {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Reading the file…").font(.caption).foregroundStyle(.secondary)
                    }
                } else if failure == nil {
                    EmptyStateView(
                        icon: Icon.importData, title: "Choose a file to begin",
                        message: "Its columns are shown beside the table's so you can say which fills which."
                    )
                    .frame(height: 200)
                }

                if isRunning {
                    HStack(spacing: DesignTokens.Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text("Inserted \(progressCount) rows…").font(.caption).foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let insertedCount {
                    InlineBanner(
                        kind: .success,
                        message:
                            "Imported \(insertedCount) row\(insertedCount == 1 ? "" : "s") into \(request.table.name).",
                        onDismiss: {})
                }
                if let failure { InlineBanner(kind: .error, message: failure) { self.failure = nil } }
            }
        } footer: {
            if let productionName {
                ProductionGate(connectionName: productionName, requiresTypedName: false, typed: .constant(""))
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
                    .disabled(preview.isEmpty || assignments.isEmpty || isRunning || isPreparing)
            }
        }
        .task {
            await loadColumns()
            // `--ui-demo import --ui-demo-import-file <path>` shows a file's preview and
            // mapping without the open panel. Nothing is imported until Import is pressed.
            if let path = UserDefaults.standard.string(forKey: "uiDemo.importFile") {
                UserDefaults.standard.removeObject(forKey: "uiDemo.importFile")
                await load(URL(fileURLWithPath: path))
            }
        }
    }

    // MARK: - Source and target

    /// What is read and what is filled, one above the other.
    private var endpoints: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            FieldRow(label: "From", labelWidth: 60) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Button {
                        chooseFile()
                    } label: {
                        Label(fileURL == nil ? "Choose File…" : "Choose Another…", systemImage: Icon.open)
                    }
                    .fixedSize()
                    .disabled(isRunning)
                    if let fileURL {
                        Text(fileURL.lastPathComponent).font(.callout).lineLimit(1).truncationMode(.middle)
                            .help(fileURL.path)
                        if let raw {
                            Text(ObjectsView.size(Int64(raw.count))).font(.caption).foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        if !preview.isEmpty {
                            Badge(text: "\(sourceCount) column\(sourceCount == 1 ? "" : "s")")
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            FieldRow(label: "Into", labelWidth: 60) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Label(targetName, systemImage: Icon.data).font(.callout).lineLimit(1).truncationMode(.middle)
                    if let name = config?.name {
                        Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !columns.isEmpty {
                        Badge(text: "\(columns.count) column\(columns.count == 1 ? "" : "s")")
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .controlSize(.small)
    }

    private var targetName: String {
        [request.table.schema, request.table.name].filter { !$0.isEmpty }.joined(separator: ".")
    }

    /// How the file is read: which sheet, which encoding, what separates the fields.
    private var readingOptions: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            if isJSON {
                Text("JSON · keys are the columns").font(.caption).foregroundStyle(.secondary)
            }
            if isWorkbook, let workbook {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Sheet").font(.caption).foregroundStyle(.secondary)
                    BarPopUp(
                        items: workbook.sheets.map {
                            BarPopUp.Item(id: $0.index, title: $0.isHidden ? "\($0.name) (hidden)" : $0.name)
                        },
                        selection: Binding(
                            get: { workbook.sheetIndex },
                            set: { index in Task { await select(sheet: index) } }
                        )
                    )
                    .frame(width: 190)
                    .accessibilityLabel("sheet")
                }
            }
            if !isWorkbook {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Encoding").font(.caption).foregroundStyle(.secondary)
                    BarPopUp(
                        items: [BarPopUp.Item(id: Self.automatic, title: "Auto (\(detectedEncoding.displayName))")]
                            + ImportTextEncoding.allCases.map { BarPopUp.Item(id: $0.rawValue, title: $0.displayName) },
                        selection: Binding(
                            get: { encodingChoice },
                            set: { choice in
                                encodingChoice = choice
                                Task { await prepareText(guessingDelimiter: false) }
                            }
                        )
                    )
                    .frame(width: 170)
                    .accessibilityLabel("encoding")
                }
            }
            if isDelimited {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Delimiter").font(.caption).foregroundStyle(.secondary)
                    BarPopUp(
                        items: [
                            BarPopUp.Item(id: ",", title: "Comma"), BarPopUp.Item(id: ";", title: "Semicolon"),
                            BarPopUp.Item(id: "\t", title: "Tab"), BarPopUp.Item(id: "|", title: "Pipe"),
                        ],
                        selection: Binding(
                            get: { delimiter },
                            set: { value in
                                delimiter = value
                                reparse()
                            }
                        )
                    )
                    .frame(width: 120)
                    .accessibilityLabel("delimiter")
                }
            }
            if !isJSON {
                Toggle("First row is a header", isOn: $hasHeader)
                    .onChange(of: hasHeader) { _, _ in rematch() }
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .disabled(isRunning || isPreparing)
    }

    // MARK: - Mapping

    /// The table's columns down the left, the file column each one takes, and a sample.
    private var mappingTable: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Text("").frame(width: Self.widths[0])
                Text("Table column").frame(width: Self.widths[1], alignment: .leading)
                Text("Type").frame(width: Self.widths[2], alignment: .leading)
                Text("\(sourceNoun) column").frame(width: Self.widths[3], alignment: .leading)
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
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        mappingRow(column)
                            .padding(.horizontal, DesignTokens.Spacing.sm)
                            .frame(height: Self.rowHeight)
                            .background(
                                index.isMultiple(of: 2)
                                    ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
                    }
                }
            }
            .frame(height: min(CGFloat(max(3, columns.count)) * Self.rowHeight, Self.rowHeight * 8))
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func mappingRow(_ column: ColumnInfo) -> some View {
        let source = sources[column.name] ?? Self.skip
        let isRequired = missingRequired.contains { $0.name == column.name }
        return HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: Icon.key)
                .foregroundStyle(column.isPrimaryKey ? Color.yellow : Color.clear)
                .frame(width: Self.widths[0])
                .accessibilityLabel(column.isPrimaryKey ? "primary key" : "")
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(column.name).lineLimit(1).truncationMode(.middle)
                if isRequired {
                    Image(systemName: Icon.warning).foregroundStyle(.orange)
                        .help("NOT NULL without a default: the import must fill it")
                }
            }
            .frame(width: Self.widths[1], alignment: .leading)
            Text(typeText(column))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: Self.widths[2], alignment: .leading)
                .help(typeText(column))
            if column.isGenerated {
                Text("computed by the server")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.widths[3], alignment: .leading)
            } else {
                BarPopUp(
                    items: [BarPopUp.Item(id: Self.skip, title: "Skip")]
                        + (0 ..< sourceCount).map { BarPopUp.Item(id: $0, title: sourceTitle($0)) },
                    selection: Binding(
                        get: { source < sourceCount ? source : Self.skip },
                        set: { sources[column.name] = $0 == Self.skip ? nil : $0 }
                    )
                )
                .controlSize(.small)
                .frame(width: Self.widths[3])
                .disabled(isRunning)
                .accessibilityLabel("\(column.name) source column")
            }
            Text(source >= 0 && !column.isGenerated ? sample(at: source) : "")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// The type as the server spells it, with what an insert has to know about it.
    private func typeText(_ column: ColumnInfo) -> String {
        var text = column.nativeType
        if !column.isNullable { text += " · NOT NULL" }
        if column.isAutoIncrement { text += " · auto" }
        return text
    }

    /// `B · nama` in a workbook, `2 · nama` in a text file; the position alone when the
    /// file has no header or the heading is blank.
    private func sourceTitle(_ index: Int) -> String {
        let position = isWorkbook ? Self.columnLetters(index) : String(index + 1)
        let name = hasHeader ? (preview.first?[safe: index] ?? "").trimmingCharacters(in: .whitespaces) : ""
        return name.isEmpty ? "Column \(position)" : "\(position) · \(name)"
    }

    static func columnLetters(_ index: Int) -> String {
        var number = index + 1
        var letters = ""
        while number > 0 {
            let remainder = (number - 1) % 26
            letters = String(UnicodeScalar(UInt8(65 + remainder))) + letters
            number = (number - 1) / 26
        }
        return letters
    }

    private func sample(at index: Int) -> String {
        dataRows.prefix(3).compactMap { $0.indices.contains(index) ? $0[index] : nil }
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private var mappingActions: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Button("Match by Name") { matchByName() }
                .disabled(!hasHeader)
                .help("Each table column takes the file column with the same name")
            Button("Match by Position") { matchByPosition() }
                .help("The first file column fills the first table column, and so on")
            Button("Clear") { sources = [:] }
                .disabled(sources.isEmpty)
            Spacer()
            Text("\(assignments.count) of \(columns.count) table column\(columns.count == 1 ? "" : "s") filled")
                .font(.caption).foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .disabled(isRunning)
    }

    private var importOptions: some View {
        HStack(spacing: DesignTokens.Spacing.md) {
            FieldRow(label: "NULL when", labelWidth: 70) {
                TextField("empty", text: $nullText).textFieldStyle(.roundedBorder).frame(width: 100)
            }
            FieldRow(label: "Commit every", labelWidth: 84) {
                TextField("all at once", value: $commitEvery, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 90)
                Text("rows").font(.caption).foregroundStyle(.secondary)
            }
            .help(
                "0 keeps the whole import in one transaction; a number commits along the way, which a very large file needs."
            )
            if isDelimited {
                Toggle("Remove formula guards", isOn: $removesFormulaGuard)
                    .help(
                        "A CSV exported with formula protection writes '=SUM(A1) for =SUM(A1). This takes that apostrophe off text fields."
                    )
                    .fixedSize()
            }
            Spacer(minLength: 0)
        }
        .controlSize(.small)
        .disabled(isRunning)
    }

    private func matchByName() {
        let matched = CSVImportPlan.assignmentsByName(header: preview.first ?? [], columns: columns)
        sources = Dictionary(matched.map { ($0.column, $0.source) }, uniquingKeysWith: { first, _ in first })
    }

    private func matchByPosition() {
        let matched = CSVImportPlan.assignmentsByPosition(sourceCount: sourceCount, columns: columns)
        sources = Dictionary(matched.map { ($0.column, $0.source) }, uniquingKeysWith: { first, _ in first })
    }

    /// By name when the file names its columns, by position when it does not.
    private func rematch() {
        guard !columns.isEmpty, !preview.isEmpty else { return }
        if hasHeader { matchByName() } else { matchByPosition() }
    }

    // MARK: - Reading the file

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            .commaSeparatedText, .tabSeparatedText, UTType(filenameExtension: "xlsx") ?? .data, .json, .plainText,
            .data,
        ]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await load(url) }
    }

    private func load(_ url: URL) async {
        fileURL = url
        failure = nil
        insertedCount = nil
        preview = []
        sources = [:]
        workbook = nil
        raw = nil
        text = nil
        encodingChoice = Self.automatic
        isPreparing = true
        defer { isPreparing = false }
        do {
            // Mapped, not read: the file's bytes are paged in as the reader walks them.
            let mapped = try Data(contentsOf: url, options: .mappedIfSafe)
            raw = mapped
            // The bytes decide over the name: a workbook read as CSV, or an old `.xls`
            // read as anything, fills the mapping with the file's binary.
            format = try ImportFileProbe.format(url: url, data: mapped)
            if isJSON || isWorkbook { hasHeader = true }
            if isWorkbook {
                var opened = try await XLSXWorkbook.open(data: mapped)
                // A hidden first sheet is rarely the data; the first one shown is.
                if opened.sheets.first?.isHidden == true, let shown = opened.sheets.first(where: { !$0.isHidden }) {
                    opened = try await Self.selecting(shown.index, in: opened)
                }
                workbook = opened
                reparse()
            } else {
                detectedEncoding = ImportFileProbe.detectEncoding(mapped)
                try await readText(guessingDelimiter: true)
            }
        } catch {
            raw = nil
            failure = Self.message(for: error)
        }
    }

    private func select(sheet index: Int) async {
        guard let workbook, index != workbook.sheetIndex else { return }
        isPreparing = true
        defer { isPreparing = false }
        do {
            self.workbook = try await Self.selecting(index, in: workbook)
            failure = nil
            insertedCount = nil
            reparse()
        } catch {
            failure = Self.message(for: error)
        }
    }

    private func prepareText(guessingDelimiter: Bool) async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            failure = nil
            try await readText(guessingDelimiter: guessingDelimiter)
        } catch {
            failure = Self.message(for: error)
        }
    }

    /// Turns the file into UTF-8 in the chosen encoding and reads its first rows.
    private func readText(guessingDelimiter: Bool) async throws {
        guard let raw else { return }
        let converted = try await Self.utf8(raw, encoding: encoding)
        text = converted
        if isDelimited, guessingDelimiter {
            var fallback: Character = ","
            if case let .delimited(character) = format { fallback = character }
            delimiter = String(ImportFileProbe.detectDelimiter(converted, fallback: fallback))
        }
        reparse()
    }

    /// Away from the main actor: a large file takes a moment to transcode or inflate.
    private nonisolated static func utf8(_ data: Data, encoding: ImportTextEncoding) async throws -> Data {
        try ImportFileProbe.utf8Data(from: data, encoding: encoding)
    }

    private nonisolated static func selecting(_ index: Int, in workbook: XLSXWorkbook) async throws -> XLSXWorkbook {
        try workbook.selecting(sheet: index)
    }

    private static func message(for error: any Error) -> String {
        (error as? DBError)?.errorDescription ?? String(describing: error)
    }

    private func reparse() {
        var rows: [[String]] = []
        if isWorkbook {
            guard var reader = workbook?.rows() else { return }
            while rows.count < Self.previewRows, let row = reader.next() { rows.append(row) }
        } else if let text {
            if isJSON {
                // The keys stand in as the header row so the mapping table reads the same.
                var reader = JSONRecordReader(data: text)
                rows.append(reader.header)
                while rows.count < Self.previewRows, let row = reader.next() { rows.append(row) }
                if rows.count == 1, reader.header.isEmpty { rows = [] }
            } else {
                var reader = CSVReader(data: text, delimiter: delimiter.first ?? ",")
                while rows.count < Self.previewRows, let row = reader.next() { rows.append(row) }
            }
        }
        preview = rows
        if rows.isEmpty {
            failure = isWorkbook ? "This sheet has no rows." : "The file has no rows."
        }
        rematch()
    }

    private func loadColumns() async {
        let table = request.table
        guard let session = environment.session(for: request.connectionID, table: table) else { return }
        do {
            columns = try await session.introspection(.columns(table)) { try await $0.columns(of: table) }
        } catch {
            failure = Self.message(for: error)
        }
        rematch()
    }

    // MARK: - Importing

    private func run() async {
        guard let session = environment.session(for: request.connectionID, table: request.table) else { return }
        isRunning = true
        progressCount = 0
        failure = nil
        defer { isRunning = false }
        // JSON records never carry a header row; the keys were the header in the preview.
        let plan = CSVImportPlan(
            table: request.table, assignments: assignments, sourceCount: sourceCount,
            hasHeader: isJSON ? false : hasHeader, nullText: nullText, commitEveryRows: commitEvery,
            removesFormulaGuard: isDelimited && removesFormulaGuard)
        let importer = CSVImporter(plan: plan, columns: columns, dialect: dialect)
        let workbook = workbook
        let text = text
        let isJSON = isJSON
        let separator = delimiter.first ?? ","
        do {
            if await session.isReadOnly {
                throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L first.")
            }
            _ = try await session.connect()
            let count = try await session.withLease { connection -> Int64 in
                let progress: @Sendable (Int64) -> Void = { done in
                    Task { @MainActor in progressCount = done }
                }
                if let workbook {
                    var reader = workbook.rows()
                    return try await importer.run(reader: &reader, on: connection, progress: progress)
                }
                guard let text else { return 0 }
                if isJSON {
                    var reader = JSONRecordReader(data: text)
                    return try await importer.run(reader: &reader, on: connection, progress: progress)
                }
                var reader = CSVReader(data: text, delimiter: separator)
                return try await importer.run(reader: &reader, on: connection, progress: progress)
            }
            await session.invalidateIntrospection(.rowCount(request.table))
            insertedCount = count
        } catch {
            failure = Self.message(for: error)
        }
    }
}
