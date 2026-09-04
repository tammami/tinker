import AppKit
import DBCore
import DBGrid
import SwiftUI
import UniformTypeIdentifiers

/// Run a `.sql` or `.sql.gz` file — a Tinker dump, a `pg_dump`, a `mysqldump` — against
/// a database, however big the file is.
///
/// The file is read in pieces and each statement is run as it is found, in batched
/// transactions, so a multi-gigabyte dump with hundreds of millions of rows costs the
/// app the memory of one statement. Progress is by bytes, so it is honest about how
/// far along a large file is.
struct ImportScriptSheet: View {
    let request: ScriptImportRequest
    let environment: AppEnvironment
    let onDismiss: () -> Void

    @State private var controller: TransferController
    @State private var endpoint: EndpointModel
    @State private var fileURL: URL?
    @State private var fileSize: Int64 = 0
    @State private var isCompressed = false
    @State private var transactions: TransactionChoice = .perBatch
    @State private var batchSize = 500
    @State private var stopOnError = true
    @State private var disableForeignKeyChecks = true

    enum TransactionChoice: String, CaseIterable, Identifiable {
        case perBatch, single, autocommit
        var id: String { rawValue }
        var title: String {
            switch self {
            case .perBatch: "Commit every N statements"
            case .single: "One transaction for the whole file"
            case .autocommit: "Autocommit (each statement on its own)"
            }
        }
    }

    init(request: ScriptImportRequest, environment: AppEnvironment, onDismiss: @escaping () -> Void) {
        self.request = request
        self.environment = environment
        self.onDismiss = onDismiss
        _controller = State(initialValue: TransferController(environment: environment))
        let start = environment.connections.first { $0.id == request.connectionID }
        let database = request.database ?? start?.database ?? ""
        _endpoint = State(
            initialValue: EndpointModel(
                environment: environment, connectionID: request.connectionID,
                schema: SchemaRef(database: database, schema: "")))
    }

    /// Where the script runs: the row that was clicked, or what the pickers say.
    private var connectionID: UUID {
        request.choosesTarget ? (endpoint.connectionID ?? request.connectionID) : request.connectionID
    }
    private var database: String? {
        request.choosesTarget ? (endpoint.database.isEmpty ? nil : endpoint.database) : request.database
    }
    private var config: ConnectionConfig? { environment.connections.first { $0.id == connectionID } }
    private var dialect: SQLDialect { config?.dialect ?? .postgresql }
    private var isProduction: Bool { config?.isProduction ?? false }

    private var targetLine: String {
        let name = config?.name ?? "connection"
        let database = database ?? config?.database ?? ""
        return database.isEmpty ? name : "\(name) · \(database)"
    }

    var body: some View {
        SheetFrame(
            title: "Import SQL file", icon: Icon.importData, subtitle: "Into \(targetLine)",
            width: DesignTokens.Metrics.wideSheetWidth, contentInset: 0
        ) {
            VStack(spacing: 0) {
                if request.choosesTarget {
                    targetPicker
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.top, DesignTokens.Spacing.lg)
                        .disabled(controller.isRunning)
                }
                filePicker
                    .padding(.horizontal, DesignTokens.Spacing.lg)
                    .padding(.top, DesignTokens.Spacing.lg)
                    .padding(.bottom, DesignTokens.Spacing.sm)
                Form {
                    Section {
                        Picker("Transactions", selection: $transactions) {
                            ForEach(TransactionChoice.allCases) { choice in Text(choice.title).tag(choice) }
                        }
                        if transactions == .perBatch {
                            TextField("Statements per commit", value: $batchSize, format: .number)
                        }
                        Toggle("Stop at the first error", isOn: $stopOnError)
                        if !stopOnError {
                            Text("Continuing runs every statement on its own, so one failure cannot roll back a batch.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if dialect == .mysql {
                            Toggle(
                                "Turn off foreign key and unique checks while loading", isOn: $disableForeignKeyChecks)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(height: 190)
                .disabled(controller.isRunning)

                if controller.phase != .idle {
                    TransferProgressView(controller: controller)
                        .padding(.horizontal, DesignTokens.Spacing.lg)
                        .padding(.bottom, DesignTokens.Spacing.md)
                }
            }
        } footer: {
            if isProduction {
                Label("Production", systemImage: Icon.production).foregroundStyle(.red).font(.callout.weight(.semibold))
            }
            Spacer()
            if controller.isRunning {
                Button("Cancel") { controller.cancel() }.keyboardShortcut(.cancelAction)
            } else {
                Button(controller.phase == .finished ? "Close" : "Cancel") { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                if controller.phase != .finished {
                    Button {
                        run()
                    } label: {
                        Label("Import", systemImage: Icon.importData)
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(fileURL == nil)
                }
            }
        }
    }

    /// Connection and database pickers, for an import started from the menu.
    private var targetPicker: some View {
        @Bindable var endpoint = endpoint
        return VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.md) {
                FieldRow(label: "Into connection", labelWidth: 100) {
                    Picker("", selection: $endpoint.connectionID) {
                        ForEach(environment.connections) { config in Text(config.name).tag(UUID?.some(config.id)) }
                    }
                    .labelsHidden()
                    .onChange(of: endpoint.connectionID) { _, _ in Task { await endpoint.loadConnection() } }
                }
                FieldRow(label: "Database", labelWidth: 70) {
                    Picker("", selection: $endpoint.database) {
                        ForEach(endpoint.databases, id: \.self) { name in Text(name).tag(name) }
                    }
                    .labelsHidden()
                    .disabled(endpoint.databases.isEmpty)
                }
            }
            if let error = endpoint.error {
                InlineBanner(kind: .error, message: error, onDismiss: {})
            }
        }
        .task { await endpoint.loadConnection() }
    }

    private var filePicker: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            Image(systemName: Icon.text)
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.Metrics.iconWidth)
            if let fileURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fileURL.lastPathComponent).lineLimit(1)
                    Text(
                        "\(TransferFormat.bytes(fileSize))"
                            + (isCompressed ? " · gzip" : "")
                            + " · read in 1 MB pieces, never loaded whole"
                    )
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            } else {
                Text("Choose a .sql or .sql.gz file").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Choose…") { chooseFile() }.disabled(controller.isRunning)
        }
        .padding(DesignTokens.Spacing.md)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "sql") ?? .plainText, .gzip, .plainText, .data]
        panel.allowsOtherFileTypes = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        fileURL = url
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        fileSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        if let handle = try? FileHandle(forReadingFrom: url) {
            let magic = (try? handle.read(upToCount: 2)) ?? Data()
            isCompressed = magic.count == 2 && magic[magic.startIndex] == 0x1F && magic[magic.startIndex + 1] == 0x8B
            try? handle.close()
        }
    }

    private func run() {
        guard let fileURL else { return }
        var options = ScriptExecutionOptions()
        switch transactions {
        case .perBatch: options.transactions = .perBatch(statements: max(1, batchSize))
        case .single: options.transactions = .single
        case .autocommit: options.transactions = .autocommit
        }
        options.stopOnError = stopOnError
        options.disableForeignKeyChecks = disableForeignKeyChecks
        let resolved = ScriptImportRequest(connectionID: connectionID, database: database)
        controller.importScript(resolved, from: fileURL, options: options)
    }
}
