import DBCore
import DBSQL
import SwiftUI

/// The Structure tab (SPEC §15b.1).
///
/// Read-only until Edit is pressed, so browsing a production schema cannot change it by a
/// stray keystroke, and nothing reaches the server without going through Preview.
public struct StructureView: View {
    @Bindable var controller: StructureController
    let isProduction: Bool

    @State private var pane: Pane = .columns
    @State private var isPreviewPresented = false

    enum Pane: String, CaseIterable, Identifiable {
        case columns = "Columns"
        case indexes = "Indexes"
        case foreignKeys = "Foreign Keys"
        case checks = "Checks"
        case triggers = "Triggers"
        case partitions = "Partitions"
        case table = "Table"

        var id: String { rawValue }
    }

    public init(controller: StructureController, isProduction: Bool = false) {
        self.controller = controller
        self.isProduction = isProduction
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let error = controller.errorText {
                ErrorBanner(message: error) { controller.clearError() }
                Divider()
            }
            if let status = controller.statusText {
                statusBanner(status)
                Divider()
            }

            if controller.edited == nil {
                ContentUnavailableView(
                    controller.isLoading ? "Reading the structure…" : "No structure loaded",
                    systemImage: "tablecells"
                )
            } else {
                paneContent
            }
        }
        .task {
            await controller.load()
            await controller.loadCollationsIfNeeded()
        }
        .sheet(isPresented: $isPreviewPresented) {
            DDLPreviewView(
                statements: controller.pendingStatements,
                dialect: controller.dialect,
                isTransactional: controller.isTransactional,
                tableName: controller.table.name,
                isProduction: isProduction,
                onExecute: {
                    await controller.execute()
                    isPreviewPresented = false
                },
                onCancel: { isPreviewPresented = false }
            )
        }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        HStack(spacing: 10) {
            Picker("", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 560)

            Spacer()

            if controller.isEditing {
                let count = controller.pendingStatements.count
                Text(count == 0 ? "No changes" : "\(count) statement\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button("Discard") { controller.discardChanges() }
                    .disabled(!controller.hasPendingChanges)

                Button("Preview…") { isPreviewPresented = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!controller.hasPendingChanges)

                Button("Done") { controller.isEditing = false }
            } else {
                Button("Edit") { controller.isEditing = true }
                    .disabled(controller.edited == nil)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private func statusBanner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            Text(text).font(.callout)
            Spacer()
            Button {
                controller.clearStatus()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .columns:
            ColumnsPane(controller: controller)
        case .indexes:
            IndexesPane(controller: controller)
        case .foreignKeys:
            ForeignKeysPane(controller: controller)
        case .checks:
            ChecksPane(controller: controller)
        case .triggers:
            TriggersPane(controller: controller)
        case .partitions:
            PartitionsPane(controller: controller)
        case .table:
            TablePane(controller: controller)
        }
    }
}

// MARK: - Columns

/// The editable panes are built from rows rather than from `Table`.
///
/// SwiftUI's `Table` does not expose the controls inside its cells: they cannot be reached
/// by the accessibility system, which means VoiceOver cannot operate them and neither can
/// a UI test. A pane whose toggles cannot be clicked is not an editor, so these lay out
/// their own header and rows.
struct StructureGrid<Row: Identifiable, Content: View>: View {
    let headers: [(title: String, width: CGFloat?)]
    let rows: [Row]
    let content: (Row, Int) -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(header.title)
                        .font(.caption.weight(.semibold))
                        .frame(width: header.width, alignment: .leading)
                        .frame(maxWidth: header.width == nil ? .infinity : nil, alignment: .leading)
                        .padding(.horizontal, 6)
                }
            }
            .padding(.vertical, 5)
            .background(Color(nsColor: .windowBackgroundColor))
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        content(row, index)
                            .padding(.vertical, 3)
                            .background(
                                index.isMultiple(of: 2)
                                    ? Color.clear
                                    : Color(nsColor: .alternatingContentBackgroundColors[1])
                            )
                        Divider()
                    }
                }
            }
        }
    }
}

/// A cell that fills its column, so every row lines up under its heading.
private struct Cell<Content: View>: View {
    let width: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, 6)
    }
}

struct ColumnsPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [34, 180, 150, 60, 140, 46, 130, nil]

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(
                headers: [
                    ("PK", widths[0]), ("Name", widths[1]), ("Type", widths[2]),
                    ("Not null", widths[3]), ("Default", widths[4]), ("Auto", widths[5]),
                    ("Collation", widths[6]), ("Comment", widths[7]),
                ],
                rows: controller.edited?.columns ?? []
            ) { column, index in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        Toggle("", isOn: primaryKeyBinding(for: column.name))
                            .labelsHidden()
                            .disabled(!controller.isEditing)
                            .accessibilityLabel("\(column.name) primary key")
                    }
                    Cell(width: widths[1]) {
                        field(index, \.name, placeholder: "name")
                    }
                    Cell(width: widths[2]) {
                        field(index, \.type, placeholder: "type")
                    }
                    Cell(width: widths[3]) {
                        Toggle("", isOn: Binding(
                            get: { !(controller.edited?.columns[safe: index]?.isNullable ?? true) },
                            set: { controller.edited?.columns[safe: index]?.isNullable = !$0 }
                        ))
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(column.name) not null")
                    }
                    Cell(width: widths[4]) {
                        optionalField(index, \.defaultExpression, placeholder: "none")
                    }
                    Cell(width: widths[5]) {
                        Toggle("", isOn: Binding(
                            get: { controller.edited?.columns[safe: index]?.isAutoIncrement ?? false },
                            set: { controller.edited?.columns[safe: index]?.isAutoIncrement = $0 }
                        ))
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(column.name) auto increment")
                    }
                    Cell(width: widths[6]) {
                        optionalField(index, \.collation, placeholder: "default")
                    }
                    Cell(width: widths[7]) {
                        optionalField(index, \.comment, placeholder: "")
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Column",
                    onAdd: {
                        controller.edited?.columns.append(
                            ColumnDefinition(name: "new_column", type: defaultType)
                        )
                    },
                    onRemove: {
                        guard controller.edited?.columns.isEmpty == false else { return }
                        controller.edited?.columns.removeLast()
                    }
                )
            }
        }
    }

    private var defaultType: String {
        controller.dialect == .postgresql ? "text" : "varchar(255)"
    }

    private func field(
        _ index: Int, _ path: WritableKeyPath<ColumnDefinition, String>, placeholder: String
    ) -> some View {
        TextField(placeholder, text: Binding(
            get: { controller.edited?.columns[safe: index]?[keyPath: path] ?? "" },
            set: { controller.edited?.columns[safe: index]?[keyPath: path] = $0 }
        ))
        .textFieldStyle(.plain)
        .disabled(!controller.isEditing)
    }

    private func optionalField(
        _ index: Int, _ path: WritableKeyPath<ColumnDefinition, String?>, placeholder: String
    ) -> some View {
        TextField(placeholder, text: Binding(
            get: { controller.edited?.columns[safe: index]?[keyPath: path] ?? "" },
            set: { controller.edited?.columns[safe: index]?[keyPath: path] = $0.isEmpty ? nil : $0 }
        ))
        .textFieldStyle(.plain)
        .disabled(!controller.isEditing)
    }

    /// Marking a column adds it to the key in the order it was marked, which is the order
    /// the key is written in.
    private func primaryKeyBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { controller.edited?.primaryKey.contains(name) ?? false },
            set: { isOn in
                guard var definition = controller.edited else { return }
                if isOn {
                    if !definition.primaryKey.contains(name) { definition.primaryKey.append(name) }
                } else {
                    definition.primaryKey.removeAll { $0 == name }
                }
                controller.edited = definition
            }
        )
    }
}

// MARK: - Indexes

struct IndexesPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [200, nil, 110, 60, 200]

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(
                headers: [
                    ("Name", widths[0]), ("Columns", widths[1]), ("Method", widths[2]),
                    ("Unique", widths[3]), ("Where", widths[4]),
                ],
                rows: controller.edited?.indexes ?? []
            ) { index, position in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        TextField("name", text: Binding(
                            get: { controller.edited?.indexes[safe: position]?.name ?? "" },
                            set: { controller.edited?.indexes[safe: position]?.name = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField("column, column", text: Binding(
                            get: {
                                (controller.edited?.indexes[safe: position]?.columns ?? [])
                                    .map(\.name).joined(separator: ", ")
                            },
                            set: { text in
                                controller.edited?.indexes[safe: position]?.columns = text
                                    .split(separator: ",")
                                    .map { IndexColumn(name: $0.trimmingCharacters(in: .whitespaces)) }
                                    .filter { !$0.name.isEmpty }
                            }
                        ))
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[2]) {
                        Picker("", selection: Binding(
                            get: {
                                controller.edited?.indexes[safe: position]?.method
                                    ?? methods.first ?? "btree"
                            },
                            set: { controller.edited?.indexes[safe: position]?.method = $0 }
                        )) {
                            ForEach(methods, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(index.name) method")
                    }
                    Cell(width: widths[3]) {
                        Toggle("", isOn: Binding(
                            get: { controller.edited?.indexes[safe: position]?.isUnique ?? false },
                            set: { controller.edited?.indexes[safe: position]?.isUnique = $0 }
                        ))
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(index.name) unique")
                    }
                    Cell(width: widths[4]) {
                        TextField("predicate", text: Binding(
                            get: { controller.edited?.indexes[safe: position]?.predicate ?? "" },
                            set: {
                                controller.edited?.indexes[safe: position]?.predicate =
                                    $0.isEmpty ? nil : $0
                            }
                        ))
                        .textFieldStyle(.plain)
                        // A partial index is PostgreSQL's; MySQL has no equivalent.
                        .disabled(!controller.isEditing || controller.dialect != .postgresql)
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Index",
                    onAdd: {
                        let count = (controller.edited?.indexes.count ?? 0) + 1
                        controller.edited?.indexes.append(IndexDefinition(
                            name: "\(controller.table.name)_idx_\(count)",
                            columns: [],
                            method: methods.first
                        ))
                    },
                    onRemove: {
                        guard controller.edited?.indexes.isEmpty == false else { return }
                        controller.edited?.indexes.removeLast()
                    }
                )
            }
        }
    }

    /// What each engine actually offers, rather than a list with half of it disabled.
    private var methods: [String] {
        controller.dialect == .postgresql
            ? ["btree", "hash", "gin", "gist", "brin", "spgist"]
            : ["btree", "hash", "fulltext", "spatial"]
    }
}

// MARK: - Foreign keys

struct ForeignKeysPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [170, 150, 150, 150, 130, 130]

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(
                headers: [
                    ("Name", widths[0]), ("Columns", widths[1]), ("References", widths[2]),
                    ("Ref columns", widths[3]), ("On update", widths[4]), ("On delete", widths[5]),
                ],
                rows: controller.edited?.foreignKeys ?? []
            ) { key, position in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        TextField("name", text: Binding(
                            get: { controller.edited?.foreignKeys[safe: position]?.name ?? "" },
                            set: { controller.edited?.foreignKeys[safe: position]?.name = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField("column", text: Binding(
                            get: {
                                (controller.edited?.foreignKeys[safe: position]?.columns ?? [])
                                    .joined(separator: ", ")
                            },
                            set: {
                                controller.edited?.foreignKeys[safe: position]?.columns =
                                    Self.splitNames($0)
                            }
                        ))
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[2]) {
                        TextField("table", text: Binding(
                            get: {
                                controller.edited?.foreignKeys[safe: position]?
                                    .referencedTable.name ?? ""
                            },
                            set: { name in
                                guard let old = controller.edited?.foreignKeys[safe: position]?
                                    .referencedTable else { return }
                                controller.edited?.foreignKeys[safe: position]?.referencedTable =
                                    TableRef(database: old.database, schema: old.schema, name: name)
                            }
                        ))
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[3]) {
                        TextField("column", text: Binding(
                            get: {
                                (controller.edited?.foreignKeys[safe: position]?
                                    .referencedColumns ?? []).joined(separator: ", ")
                            },
                            set: {
                                controller.edited?.foreignKeys[safe: position]?
                                    .referencedColumns = Self.splitNames($0)
                            }
                        ))
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[4]) {
                        actionPicker(position, keyName: key.name, isUpdate: true)
                    }
                    Cell(width: widths[5]) {
                        actionPicker(position, keyName: key.name, isUpdate: false)
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Foreign Key",
                    onAdd: {
                        let table = controller.table
                        let count = (controller.edited?.foreignKeys.count ?? 0) + 1
                        controller.edited?.foreignKeys.append(ForeignKeyDefinition(
                            name: "\(table.name)_fk_\(count)",
                            columns: [],
                            referencedTable: table,
                            referencedColumns: []
                        ))
                    },
                    onRemove: {
                        guard controller.edited?.foreignKeys.isEmpty == false else { return }
                        controller.edited?.foreignKeys.removeLast()
                    }
                )
            }
        }
    }

    private func actionPicker(_ position: Int, keyName: String, isUpdate: Bool) -> some View {
        Picker("", selection: Binding(
            get: {
                let key = controller.edited?.foreignKeys[safe: position]
                return (isUpdate ? key?.onUpdate : key?.onDelete) ?? .noAction
            },
            set: { action in
                if isUpdate {
                    controller.edited?.foreignKeys[safe: position]?.onUpdate = action
                } else {
                    controller.edited?.foreignKeys[safe: position]?.onDelete = action
                }
            }
        )) {
            ForEach(ForeignKeyAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .disabled(!controller.isEditing)
        .accessibilityLabel("\(keyName) on \(isUpdate ? "update" : "delete")")
    }

    static func splitNames(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Checks

struct ChecksPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [220, nil]

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(
                headers: [("Name", widths[0]), ("Expression", widths[1])],
                rows: controller.edited?.checks ?? []
            ) { _, position in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        TextField("name", text: Binding(
                            get: { controller.edited?.checks[safe: position]?.name ?? "" },
                            set: { controller.edited?.checks[safe: position]?.name = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField("expression", text: Binding(
                            get: { controller.edited?.checks[safe: position]?.expression ?? "" },
                            set: { controller.edited?.checks[safe: position]?.expression = $0 }
                        ))
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Check",
                    onAdd: {
                        let count = (controller.edited?.checks.count ?? 0) + 1
                        controller.edited?.checks.append(CheckDefinition(
                            name: "\(controller.table.name)_check_\(count)", expression: ""
                        ))
                    },
                    onRemove: {
                        guard controller.edited?.checks.isEmpty == false else { return }
                        controller.edited?.checks.removeLast()
                    }
                )
            }
        }
    }
}

// MARK: - Triggers and partitions, read-only for now

struct TriggersPane: View {
    @Bindable var controller: StructureController

    var body: some View {
        let triggers = controller.edited?.triggers ?? []
        if triggers.isEmpty {
            ContentUnavailableView("No triggers", systemImage: "bolt")
        } else {
            Table(triggers) {
                TableColumn("Name", value: \.name)
                TableColumn("Timing") { Text($0.timing.rawValue) }
                TableColumn("Events") { Text($0.events.map(\.rawValue).joined(separator: ", ")) }
                TableColumn("Level") { Text($0.isRowLevel ? "ROW" : "STATEMENT") }
                TableColumn("When") { Text($0.condition ?? "—") }
                TableColumn("Action") { Text($0.functionCall ?? $0.body ?? "—") }
            }
        }
    }
}

struct PartitionsPane: View {
    @Bindable var controller: StructureController

    var body: some View {
        if let partitioning = controller.edited?.partitioning {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Label(partitioning.strategy.rawValue, systemImage: "square.split.2x1")
                        .font(.callout.weight(.medium))
                    Text(partitioning.key).font(.system(.callout, design: .monospaced))
                    Spacer()
                }
                .padding(10)
                Divider()
                Table(partitioning.partitions) {
                    TableColumn("Partition", value: \.name)
                    TableColumn("Bound") { Text($0.bound ?? "—") }
                    TableColumn("Rows") {
                        Text($0.approximateRowCount.map { "~\($0)" } ?? "—")
                    }
                }
            }
        } else {
            ContentUnavailableView("Not partitioned", systemImage: "square.split.2x1")
        }
    }
}

// MARK: - Table

struct TablePane: View {
    @Bindable var controller: StructureController

    var body: some View {
        Form {
            Section("Table") {
                TextField("Name", text: Binding(
                    get: { controller.edited?.ref.name ?? "" },
                    set: { name in
                        guard var definition = controller.edited else { return }
                        let old = definition.ref
                        definition.ref = TableRef(
                            database: old.database, schema: old.schema, name: name
                        )
                        controller.edited = definition
                    }
                ))
                .disabled(!controller.isEditing)

                TextField("Comment", text: Binding(
                    get: { controller.edited?.comment ?? "" },
                    set: { controller.edited?.comment = $0.isEmpty ? nil : $0 }
                ))
                .disabled(!controller.isEditing)
            }

            if controller.dialect == .mysql {
                Section("Storage") {
                    TextField("Engine", text: optionBinding(\.engine))
                        .disabled(!controller.isEditing)
                    TextField("Character set", text: optionBinding(\.characterSet))
                        .disabled(!controller.isEditing)
                    TextField("Collation", text: optionBinding(\.collation))
                        .disabled(!controller.isEditing)
                }
            } else {
                Section("Storage") {
                    TextField("Tablespace", text: optionBinding(\.tablespace))
                        .disabled(!controller.isEditing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func optionBinding(_ path: WritableKeyPath<TableOptions, String?>) -> Binding<String> {
        Binding(
            get: { controller.edited?.options[keyPath: path] ?? "" },
            set: { controller.edited?.options[keyPath: path] = $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - Shared

/// Add and remove, the two buttons every pane needs.
struct PaneFooter: View {
    let addTitle: String
    let onAdd: () -> Void
    let onRemove: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button(action: onAdd) { Label(addTitle, systemImage: "plus") }
                Button(action: onRemove) { Label("Remove", systemImage: "minus") }
                    .labelStyle(.iconOnly)
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}

/// Indexing that returns nil rather than trapping, so a row that vanished while the user
/// was editing it cannot crash the pane.
extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            guard indices.contains(index), let newValue else { return }
            self[index] = newValue
        }
    }
}
