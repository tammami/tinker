import AppKit
import DBCore
import DBGrid
import DBSQL
import SwiftUI
import UniformTypeIdentifiers

/// Dump a database, a schema or some tables to a `.sql` or `.sql.gz` file.
///
/// Structure only, structure and data, or data only; PostgreSQL data as COPY blocks
/// or INSERTs; every object optional. The file is written as the rows stream, so the
/// size of the database never matters to the app's memory.
struct DumpSheet: View {
    let request: DumpRequest
    let environment: AppEnvironment
    let onDismiss: () -> Void

    @State private var controller: TransferController
    @State private var options: DumpOptions
    @State private var compress = false
    @State private var tables: [TableInfo] = []
    @State private var selected: Set<String> = []
    @State private var isLoadingTables = false
    @State private var loadError: String?

    init(request: DumpRequest, environment: AppEnvironment, onDismiss: @escaping () -> Void) {
        self.request = request
        self.environment = environment
        self.onDismiss = onDismiss
        let dialect = environment.connections.first { $0.id == request.connectionID }?.dialect ?? .postgresql
        _controller = State(initialValue: TransferController(environment: environment))
        _options = State(initialValue: DumpOptions.preferred(for: dialect))
    }

    private var config: ConnectionConfig? { environment.connections.first { $0.id == request.connectionID } }
    private var dialect: SQLDialect { config?.dialect ?? .postgresql }

    private var scopeTitle: String {
        if let tables = request.tables {
            return tables.count == 1 ? "Dump “\(tables[0].name)”" : "Dump \(tables.count) tables"
        }
        return dialect == .mysql
            ? "Dump database “\(request.schema.database)”" : "Dump schema “\(request.schema.schema)”"
    }

    private var sourceLine: String {
        let name = config?.name ?? "connection"
        return dialect == .mysql
            ? "\(name) · \(request.schema.database)"
            : "\(name) · \(request.schema.database) · \(request.schema.schema)"
    }

    private var chosenTables: [TableInfo] {
        request.tables ?? tables.filter { selected.contains($0.name) }
    }

    private var suggestedFileName: String {
        let base: String
        if let tables = request.tables, tables.count == 1 {
            base = tables[0].name
        } else {
            base = dialect == .mysql ? request.schema.database : "\(request.schema.database)_\(request.schema.schema)"
        }
        return base + (compress ? ".sql.gz" : ".sql")
    }

    var body: some View {
        SheetFrame(
            title: scopeTitle, icon: Icon.export, subtitle: sourceLine, width: DesignTokens.Metrics.wideSheetWidth,
            contentInset: 0
        ) {
            VStack(spacing: 0) {
                Form {
                    Section {
                        Picker("Content", selection: $options.content) {
                            ForEach(DumpOptions.Content.allCases) { content in Text(content.title).tag(content) }
                        }
                        if dialect == .postgresql, options.content.includesData {
                            Picker("Data as", selection: $options.dataStyle) {
                                ForEach(DumpOptions.DataStyle.allCases) { style in Text(style.title).tag(style) }
                            }
                        }
                        if options.content.includesData, options.dataStyle == .insert || dialect == .mysql {
                            TextField("Rows per INSERT", value: $options.rowsPerInsert, format: .number)
                        }
                        Toggle("Compress with gzip (.sql.gz)", isOn: $compress)
                    }
                    if options.content.includesStructure {
                        Section("Structure") {
                            Toggle("DROP … IF EXISTS before each object", isOn: $options.includeDrop)
                            if request.tables == nil {
                                Toggle("Views", isOn: $options.includeViews)
                                Toggle("Functions and procedures", isOn: $options.includeRoutines)
                            }
                            Toggle("Triggers", isOn: $options.includeTriggers)
                            if dialect == .mysql {
                                Toggle(
                                    "Leave DEFINER out, so it restores under any account", isOn: $options.stripDefiners)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(
                    height: options.content.includesStructure
                        ? (request.tables == nil ? 350 : 290) + (dialect == .mysql ? 36 : 0) : 190
                )
                .disabled(controller.isRunning)

                if request.tables == nil {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        if isLoadingTables {
                            HStack(spacing: DesignTokens.Spacing.sm) {
                                ProgressView().controlSize(.small)
                                Text("Reading tables…").font(.caption).foregroundStyle(.secondary)
                            }
                            .frame(height: 200)
                            .frame(maxWidth: .infinity)
                        } else if let loadError {
                            InlineBanner(kind: .error, message: loadError) { self.loadError = nil }
                        } else {
                            TransferTableList(tables: tables, selected: $selected)
                        }
                    }
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.top, DesignTokens.Spacing.sm)
                    .padding(.bottom, DesignTokens.Spacing.md)
                    .disabled(controller.isRunning)
                }

                if controller.phase != .idle {
                    TransferProgressView(controller: controller)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.bottom, DesignTokens.Spacing.md)
                }
            }
        } footer: {
            if let url = controller.writtenURL {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: Icon.open)
                }
            }
            Spacer()
            if controller.isRunning {
                Button("Cancel") { controller.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button(controller.phase == .finished ? "Close" : "Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                if controller.phase != .finished {
                    Button {
                        chooseDestination()
                    } label: {
                        Label("Dump…", systemImage: Icon.export)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(chosenTables.isEmpty && !(options.includeRoutines && request.tables == nil))
                }
            }
        }
        .task { await loadTables() }
    }

    private func loadTables() async {
        guard request.tables == nil else { return }
        isLoadingTables = true
        defer { isLoadingTables = false }
        guard let session = environment.session(for: request.connectionID, database: request.schema.database) else {
            return
        }
        do {
            _ = try await session.connect()
            let schema = request.schema
            let all = try await session.introspection(.tables(schema)) { try await $0.tables(in: schema) }
            tables = all.filter { $0.kind != .systemTable }
            selected = Set(tables.map(\.name))
        } catch {
            loadError = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    private func chooseDestination() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFileName
        panel.canCreateDirectories = true
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .gzip]
        panel.allowsOtherFileTypes = true
        guard panel.runModal() == .OK, var url = panel.url else { return }
        // The panel may drop the double extension; the file's own name says what it is.
        if compress, url.pathExtension != "gz" { url = url.appendingPathExtension("gz") }
        var chosen = options
        if dialect == .mysql { chosen.dataStyle = .insert }
        controller.dump(request, tables: chosenTables, options: chosen, compress: compress, to: url)
    }
}
