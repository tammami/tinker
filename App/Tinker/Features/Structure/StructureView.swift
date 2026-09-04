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
    @State private var ownPreviewPresented = false
    /// A sheet that hosts the editor drives the preview from its own footer.
    private let externalPreview: Binding<Bool>?
    /// False hides Edit / Discard / Preview / Done, for a host that supplies its own.
    private let showsActions: Bool

    private var isPreviewPresented: Binding<Bool> {
        externalPreview ?? $ownPreviewPresented
    }

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

    public init(
        controller: StructureController,
        isProduction: Bool = false,
        previewPresented: Binding<Bool>? = nil,
        showsActions: Bool = true
    ) {
        self.controller = controller
        self.isProduction = isProduction
        externalPreview = previewPresented
        self.showsActions = showsActions
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let error = controller.errorText {
                InlineBanner(kind: .error, message: error) { controller.clearError() }
                Divider()
            }
            if let status = controller.statusText {
                InlineBanner(kind: .success, message: status) { controller.clearStatus() }
                Divider()
            }

            if controller.edited == nil {
                EmptyStateView(
                    icon: Icon.structure,
                    title: controller.isLoading ? "Reading the structure…" : "No structure loaded"
                )
            } else {
                paneContent
            }
        }
        // Keyed on the table: SwiftUI reuses this view when the front tab changes, and an
        // unkeyed task would not run again, leaving the new tab reading "No structure
        // loaded" forever.
        .task(id: controller.table.id) {
            await controller.load()
            await controller.loadCollationsIfNeeded()
        }
        .refreshable { await controller.load(force: true) }
        .sheet(isPresented: isPreviewPresented) {
            DDLPreviewView(
                statements: controller.pendingStatements,
                dialect: controller.dialect,
                isTransactional: controller.isTransactional,
                tableName: controller.table.name,
                isProduction: isProduction,
                onExecute: {
                    await controller.execute()
                    isPreviewPresented.wrappedValue = false
                },
                onCancel: { isPreviewPresented.wrappedValue = false }
            )
        }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        PaneBar {
            // The pane picker gives way; the buttons keep their size and never wrap.
            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)

            Spacer(minLength: DesignTokens.Spacing.sm)

            if showsActions {
                if controller.isEditing {
                    let count = controller.pendingStatements.count
                    if count > 0 {
                        Badge(text: "\(count) statement\(count == 1 ? "" : "s")", color: .orange)
                    } else {
                        Text("No changes").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }

                    Button("Discard") { controller.discardChanges() }
                        .disabled(!controller.hasPendingChanges)
                        .fixedSize()

                    Button {
                        isPreviewPresented.wrappedValue = true
                    } label: {
                        Label("Preview…", systemImage: Icon.source)
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!controller.hasPendingChanges)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()

                    Button("Done") { controller.isEditing = false }
                        .fixedSize()
                } else {
                    Button {
                        controller.isEditing = true
                    } label: {
                        Label("Edit", systemImage: Icon.edit)
                    }
                    .disabled(controller.edited == nil)
                    .fixedSize()
                }
            }
        }
        .controlSize(.small)
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
                        .foregroundStyle(.secondary)
                        .frame(width: header.width, alignment: .leading)
                        .frame(maxWidth: header.width == nil ? .infinity : nil, alignment: .leading)
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                }
            }
            .frame(height: DesignTokens.Metrics.gridHeaderHeight)
            .background(.bar)
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
            .padding(.horizontal, DesignTokens.Spacing.sm)
    }
}

struct ColumnsPane: View {
    @Bindable var controller: StructureController

    /// Which column the move buttons act on. -1 when none is chosen.
    @State private var selectedColumn = -1

    private let widths: [CGFloat?] = [34, 180, 150, 60, 140, 46, 130, nil]

    private func move(_ index: Int, by offset: Int) {
        guard var columns = controller.edited?.columns,
            columns.indices.contains(index),
            columns.indices.contains(index + offset)
        else { return }
        columns.swapAt(index, index + offset)
        controller.edited?.columns = columns
        selectedColumn = index + offset
    }

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
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { !(controller.edited?.columns[safe: index]?.isNullable ?? true) },
                                set: { controller.edited?.columns[safe: index]?.isNullable = !$0 }
                            )
                        )
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(column.name) not null")
                    }
                    Cell(width: widths[4]) {
                        optionalField(index, \.defaultExpression, placeholder: "none")
                    }
                    Cell(width: widths[5]) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { controller.edited?.columns[safe: index]?.isAutoIncrement ?? false },
                                set: { controller.edited?.columns[safe: index]?.isAutoIncrement = $0 }
                            )
                        )
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(column.name) auto increment")
                    }
                    Cell(width: widths[6]) {
                        collationPicker(index)
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
                ) {
                    // PostgreSQL has no syntax for moving a column, so the control is
                    // absent there rather than present and disabled.
                    if controller.dialect == .mysql {
                        BarDivider()
                        IconButton(icon: "arrow.up", label: "Move Up") { move(selectedColumn, by: -1) }
                            .disabled(selectedColumn <= 0)

                        IconButton(icon: "arrow.down", label: "Move Down") { move(selectedColumn, by: 1) }
                            .disabled(
                                selectedColumn < 0
                                    || selectedColumn >= (controller.edited?.columns.count ?? 0) - 1
                            )

                        Picker("", selection: $selectedColumn) {
                            Text("Select a column").tag(-1)
                            ForEach(
                                Array((controller.edited?.columns ?? []).enumerated()),
                                id: \.offset
                            ) { offset, column in
                                Text(column.name).tag(offset)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 160)
                    }
                }
            }
        }
    }

    private var defaultType: String {
        controller.dialect == .postgresql ? "text" : "varchar(255)"
    }

    /// The collations the server actually offers. A free-text field here is a typo waiting
    /// to become a failed statement, so the list is the control.
    @ViewBuilder
    private func collationPicker(_ index: Int) -> some View {
        if controller.collations.isEmpty {
            optionalField(index, \.collation, placeholder: "default")
        } else {
            Picker(
                "",
                selection: Binding(
                    get: { controller.edited?.columns[safe: index]?.collation ?? "" },
                    set: { controller.edited?.columns[safe: index]?.collation = $0.isEmpty ? nil : $0 }
                )
            ) {
                Text("default").tag("")
                ForEach(controller.collations) { collation in
                    Text(collation.name).tag(collation.name)
                }
            }
            .labelsHidden()
            .disabled(!controller.isEditing)
            .accessibilityLabel("collation")
        }
    }

    private func field(
        _ index: Int, _ path: WritableKeyPath<ColumnDefinition, String>, placeholder: String
    ) -> some View {
        TextField(
            placeholder,
            text: Binding(
                get: { controller.edited?.columns[safe: index]?[keyPath: path] ?? "" },
                set: { controller.edited?.columns[safe: index]?[keyPath: path] = $0 }
            )
        )
        .textFieldStyle(.plain)
        .disabled(!controller.isEditing)
    }

    private func optionalField(
        _ index: Int, _ path: WritableKeyPath<ColumnDefinition, String?>, placeholder: String
    ) -> some View {
        TextField(
            placeholder,
            text: Binding(
                get: { controller.edited?.columns[safe: index]?[keyPath: path] ?? "" },
                set: { controller.edited?.columns[safe: index]?[keyPath: path] = $0.isEmpty ? nil : $0 }
            )
        )
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
                        TextField(
                            "name",
                            text: Binding(
                                get: { controller.edited?.indexes[safe: position]?.name ?? "" },
                                set: { controller.edited?.indexes[safe: position]?.name = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField(
                            "column, column",
                            text: Binding(
                                get: {
                                    (controller.edited?.indexes[safe: position]?.columns ?? [])
                                        .map(\.name).joined(separator: ", ")
                                },
                                set: { text in
                                    controller.edited?.indexes[safe: position]?.columns =
                                        text
                                        .split(separator: ",")
                                        .map { IndexColumn(name: $0.trimmingCharacters(in: .whitespaces)) }
                                        .filter { !$0.name.isEmpty }
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[2]) {
                        Picker(
                            "",
                            selection: Binding(
                                get: {
                                    controller.edited?.indexes[safe: position]?.method
                                        ?? methods.first ?? "btree"
                                },
                                set: { controller.edited?.indexes[safe: position]?.method = $0 }
                            )
                        ) {
                            ForEach(methods, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(index.name) method")
                    }
                    Cell(width: widths[3]) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { controller.edited?.indexes[safe: position]?.isUnique ?? false },
                                set: { controller.edited?.indexes[safe: position]?.isUnique = $0 }
                            )
                        )
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(index.name) unique")
                    }
                    Cell(width: widths[4]) {
                        TextField(
                            "predicate",
                            text: Binding(
                                get: { controller.edited?.indexes[safe: position]?.predicate ?? "" },
                                set: {
                                    controller.edited?.indexes[safe: position]?.predicate =
                                        $0.isEmpty ? nil : $0
                                }
                            )
                        )
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
                        controller.edited?.indexes.append(
                            IndexDefinition(
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
                        TextField(
                            "name",
                            text: Binding(
                                get: { controller.edited?.foreignKeys[safe: position]?.name ?? "" },
                                set: { controller.edited?.foreignKeys[safe: position]?.name = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField(
                            "column",
                            text: Binding(
                                get: {
                                    (controller.edited?.foreignKeys[safe: position]?.columns ?? [])
                                        .joined(separator: ", ")
                                },
                                set: {
                                    controller.edited?.foreignKeys[safe: position]?.columns =
                                        Self.splitNames($0)
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[2]) {
                        TextField(
                            "table",
                            text: Binding(
                                get: {
                                    controller.edited?.foreignKeys[safe: position]?
                                        .referencedTable.name ?? ""
                                },
                                set: { name in
                                    guard
                                        let old = controller.edited?.foreignKeys[safe: position]?
                                            .referencedTable
                                    else { return }
                                    controller.edited?.foreignKeys[safe: position]?.referencedTable =
                                        TableRef(database: old.database, schema: old.schema, name: name)
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[3]) {
                        TextField(
                            "column",
                            text: Binding(
                                get: {
                                    (controller.edited?.foreignKeys[safe: position]?
                                        .referencedColumns ?? []).joined(separator: ", ")
                                },
                                set: {
                                    controller.edited?.foreignKeys[safe: position]?
                                        .referencedColumns = Self.splitNames($0)
                                }
                            )
                        )
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
                        controller.edited?.foreignKeys.append(
                            ForeignKeyDefinition(
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
        Picker(
            "",
            selection: Binding(
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
            )
        ) {
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
                        TextField(
                            "name",
                            text: Binding(
                                get: { controller.edited?.checks[safe: position]?.name ?? "" },
                                set: { controller.edited?.checks[safe: position]?.name = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField(
                            "expression",
                            text: Binding(
                                get: { controller.edited?.checks[safe: position]?.expression ?? "" },
                                set: { controller.edited?.checks[safe: position]?.expression = $0 }
                            )
                        )
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
                        controller.edited?.checks.append(
                            CheckDefinition(
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

// MARK: - Triggers

struct TriggersPane: View {
    @Bindable var controller: StructureController

    private var isPostgres: Bool { controller.dialect == .postgresql }

    private var widths: [CGFloat?] {
        isPostgres ? [170, 110, 150, 120, 170, nil] : [170, 110, 110, nil]
    }

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(headers: headers, rows: controller.edited?.triggers ?? []) { trigger, position in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        TextField("name", text: text(position, \.name))
                            .textFieldStyle(.plain)
                            .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        Picker("", selection: value(position, \.timing, .before)) {
                            ForEach(timings, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(trigger.name) timing")
                    }
                    Cell(width: widths[2]) { eventsField(position) }

                    if isPostgres {
                        Cell(width: widths[3]) {
                            Picker("", selection: value(position, \.isRowLevel, true)) {
                                Text("ROW").tag(true)
                                Text("STATEMENT").tag(false)
                            }
                            .labelsHidden()
                            .disabled(!controller.isEditing)
                            .accessibilityLabel("\(trigger.name) level")
                        }
                        Cell(width: widths[4]) {
                            TextField("when", text: optionalText(position, \.condition))
                                .textFieldStyle(.plain)
                                .disabled(!controller.isEditing)
                        }
                        Cell(width: widths[5]) {
                            TextField("schema.function()", text: optionalText(position, \.functionCall))
                                .textFieldStyle(.plain)
                                .disabled(!controller.isEditing)
                        }
                    } else {
                        Cell(width: widths[3]) {
                            TextField("body", text: optionalText(position, \.body))
                                .textFieldStyle(.plain)
                                .disabled(!controller.isEditing)
                        }
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Trigger",
                    onAdd: {
                        let count = (controller.edited?.triggers.count ?? 0) + 1
                        controller.edited?.triggers.append(
                            TriggerInfo(
                                name: "\(controller.table.name)_trg_\(count)",
                                timing: .before,
                                events: [.update],
                                body: isPostgres ? nil : "SET NEW.id = NEW.id",
                                functionCall: isPostgres ? "" : nil
                            ))
                    },
                    onRemove: {
                        guard controller.edited?.triggers.isEmpty == false else { return }
                        controller.edited?.triggers.removeLast()
                    }
                )
            }
        }
    }

    private var headers: [(title: String, width: CGFloat?)] {
        isPostgres
            ? [
                ("Name", widths[0]), ("Timing", widths[1]), ("Events", widths[2]),
                ("Level", widths[3]), ("When", widths[4]), ("Function", widths[5]),
            ]
            : [
                ("Name", widths[0]), ("Timing", widths[1]), ("Event", widths[2]),
                ("Body", widths[3]),
            ]
    }

    /// `INSTEAD OF` is PostgreSQL's and applies to views, so MySQL is not offered it.
    private var timings: [TriggerTiming] {
        isPostgres ? [.before, .after, .insteadOf] : [.before, .after]
    }

    /// A PostgreSQL trigger can fire on several events; MySQL's fires on exactly one, so
    /// anything past the first is dropped rather than written into SQL the server rejects.
    private func eventsField(_ position: Int) -> some View {
        TextField(
            isPostgres ? "INSERT, UPDATE" : "UPDATE",
            text: Binding(
                get: {
                    (controller.edited?.triggers[safe: position]?.events ?? [])
                        .map(\.rawValue).joined(separator: ", ")
                },
                set: { text in
                    let events = text.split(separator: ",").compactMap {
                        TriggerEvent(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased())
                    }
                    controller.edited?.triggers[safe: position]?.events =
                        isPostgres ? events : Array(events.prefix(1))
                }
            )
        )
        .textFieldStyle(.plain)
        .disabled(!controller.isEditing)
    }

    private func text(_ position: Int, _ path: WritableKeyPath<TriggerInfo, String>) -> Binding<String> {
        Binding(
            get: { controller.edited?.triggers[safe: position]?[keyPath: path] ?? "" },
            set: { controller.edited?.triggers[safe: position]?[keyPath: path] = $0 }
        )
    }

    private func optionalText(
        _ position: Int, _ path: WritableKeyPath<TriggerInfo, String?>
    ) -> Binding<String> {
        Binding(
            get: { controller.edited?.triggers[safe: position]?[keyPath: path] ?? "" },
            set: { controller.edited?.triggers[safe: position]?[keyPath: path] = $0.isEmpty ? nil : $0 }
        )
    }

    private func value<T>(
        _ position: Int, _ path: WritableKeyPath<TriggerInfo, T>, _ fallback: T
    ) -> Binding<T> {
        Binding(
            get: { controller.edited?.triggers[safe: position]?[keyPath: path] ?? fallback },
            set: { controller.edited?.triggers[safe: position]?[keyPath: path] = $0 }
        )
    }
}

// MARK: - Partitions

struct PartitionsPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [220, nil, 110]

    var body: some View {
        if let partitioning = controller.edited?.partitioning {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Label(partitioning.strategy.rawValue, systemImage: Icon.partition)
                        .font(.callout.weight(.medium))
                    Text(partitioning.key).font(.system(.callout, design: .monospaced))
                    Spacer()
                    // Changing either means rebuilding the table, which is a migration
                    // rather than an edit (SPEC §15b.1).
                    Text("Strategy and key are fixed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .frame(height: DesignTokens.Metrics.barHeight)
                Divider()

                StructureGrid(
                    headers: [("Partition", widths[0]), ("Bound", widths[1]), ("Rows", widths[2])],
                    rows: partitioning.partitions
                ) { partition, position in
                    HStack(spacing: 0) {
                        Cell(width: widths[0]) {
                            TextField(
                                "name",
                                text: Binding(
                                    get: { self.partition(position)?.name ?? "" },
                                    set: { self.setPartition(position, name: $0, bound: nil) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .disabled(!controller.isEditing)
                        }
                        Cell(width: widths[1]) {
                            TextField(
                                boundPlaceholder,
                                text: Binding(
                                    get: { self.partition(position)?.bound ?? "" },
                                    set: { self.setPartition(position, name: nil, bound: $0) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .disabled(!controller.isEditing)
                        }
                        Cell(width: widths[2]) {
                            Text(partition.approximateRowCount.map { "~\($0)" } ?? "—")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if controller.isEditing {
                    PaneFooter(
                        addTitle: "Add Partition",
                        onAdd: {
                            let count = partitioning.partitions.count + 1
                            appendPartition(
                                PartitionInfo(
                                    name: "\(controller.table.name)_p\(count)",
                                    bound: boundPlaceholder
                                ))
                        },
                        onRemove: { removeLastPartition() }
                    )
                }
            }
        } else {
            EmptyStateView(
                icon: Icon.partition,
                title: "Not partitioned",
                message: "Partitioning is declared when the table is created."
            )
        }
    }

    /// Each engine spells a bound its own way, so the placeholder shows the right shape.
    private var boundPlaceholder: String {
        controller.dialect == .postgresql ? "FOR VALUES FROM (0) TO (10)" : "VALUES LESS THAN (10)"
    }

    private func partition(_ position: Int) -> PartitionInfo? {
        controller.edited?.partitioning?.partitions[safe: position]
    }

    private func setPartition(_ position: Int, name: String?, bound: String?) {
        guard let partitioning = controller.edited?.partitioning,
            let existing = partitioning.partitions[safe: position]
        else { return }
        var partitions = partitioning.partitions
        partitions[position] = PartitionInfo(
            name: name ?? existing.name,
            bound: bound ?? existing.bound,
            approximateRowCount: existing.approximateRowCount
        )
        controller.edited?.partitioning = PartitioningInfo(
            strategy: partitioning.strategy, key: partitioning.key,
            partitions: partitions, partitionCount: partitioning.partitionCount
        )
    }

    private func appendPartition(_ partition: PartitionInfo) {
        guard let partitioning = controller.edited?.partitioning else { return }
        controller.edited?.partitioning = PartitioningInfo(
            strategy: partitioning.strategy, key: partitioning.key,
            partitions: partitioning.partitions + [partition],
            partitionCount: partitioning.partitionCount
        )
    }

    private func removeLastPartition() {
        guard let partitioning = controller.edited?.partitioning,
            !partitioning.partitions.isEmpty
        else { return }
        controller.edited?.partitioning = PartitioningInfo(
            strategy: partitioning.strategy, key: partitioning.key,
            partitions: partitioning.partitions.dropLast(),
            partitionCount: partitioning.partitionCount
        )
    }
}

// MARK: - Table

struct TablePane: View {
    @Bindable var controller: StructureController

    var body: some View {
        Form {
            Section("Table") {
                TextField(
                    "Name",
                    text: Binding(
                        get: { controller.edited?.ref.name ?? "" },
                        set: { name in
                            guard var definition = controller.edited else { return }
                            let old = definition.ref
                            definition.ref = TableRef(
                                database: old.database, schema: old.schema, name: name
                            )
                            controller.edited = definition
                        }
                    )
                )
                .disabled(!controller.isEditing)

                TextField(
                    "Comment",
                    text: Binding(
                        get: { controller.edited?.comment ?? "" },
                        set: { controller.edited?.comment = $0.isEmpty ? nil : $0 }
                    )
                )
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
struct PaneFooter<Extra: View>: View {
    let addTitle: String
    let onAdd: () -> Void
    let onRemove: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            PaneBar {
                Button(action: onAdd) { Label(addTitle, systemImage: Icon.add) }
                IconButton(icon: Icon.remove, label: "Remove the last row", action: onRemove)
                extra
                Spacer()
            }
            .controlSize(.small)
        }
    }
}

extension PaneFooter where Extra == EmptyView {
    init(addTitle: String, onAdd: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.init(addTitle: addTitle, onAdd: onAdd, onRemove: onRemove) { EmptyView() }
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
