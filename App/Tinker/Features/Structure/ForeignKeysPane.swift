import DBCore
import DBSQL
import SwiftUI

/// The Foreign Keys pane: the table's keys listed, and the selected one edited beneath.
///
/// Nothing about a key is typed except its name. The columns, the table it points at and
/// the columns there are chosen from what the server has, so a key cannot name something
/// that does not exist; what each action does is said beside it, and what the server
/// would refuse is said before it is asked.
struct ForeignKeysPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [200, 170, 180, 170, 110, nil]

    private var keys: [ForeignKeyDefinition] { controller.edited?.foreignKeys ?? [] }

    private var selectedIndex: Int? {
        guard let id = controller.selectedForeignKeyID else { return nil }
        return keys.firstIndex { $0.id == id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if keys.isEmpty {
                EmptyStateView(
                    icon: Icon.foreignKey,
                    title: "No foreign keys",
                    message: controller.isEditing
                        ? "Add one to tie a column here to a row of another table."
                        : "Press Edit to add one."
                )
                .frame(maxHeight: .infinity)
            } else {
                StructureGrid(
                    headers: [
                        ("Name", widths[0]), ("Columns", widths[1]), ("References", widths[2]),
                        ("Referenced columns", widths[3]), ("On update", widths[4]), ("On delete", widths[5]),
                    ],
                    rows: keys,
                    selectedID: controller.selectedForeignKeyID
                ) { key, _ in
                    row(key)
                }

                if let index = selectedIndex, let key = keys[safe: index] {
                    Divider()
                    ForeignKeyEditor(controller: controller, index: index, key: key)
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Foreign Key",
                    removeTitle: "Remove the selected foreign key",
                    onAdd: add,
                    onRemove: remove
                ) { EmptyView() }
            }
        }
        .task(id: controller.table.id) { await controller.loadReferenceSchemasIfNeeded() }
        .onAppear { selectFirstIfNeeded() }
        .onChange(of: keys.map(\.id)) { _, _ in selectFirstIfNeeded() }
    }

    private func row(_ key: ForeignKeyDefinition) -> some View {
        let isSelected = key.id == controller.selectedForeignKeyID
        return HStack(spacing: 0) {
            Cell(width: widths[0]) { Text(key.name).lineLimit(1) }
            Cell(width: widths[1]) { Text(key.columns.joined(separator: ", ")).lineLimit(1) }
            Cell(width: widths[2]) {
                Text(Self.tableTitle(key.referencedTable, from: controller.currentTable)).lineLimit(1)
            }
            Cell(width: widths[3]) { Text(key.referencedColumns.joined(separator: ", ")).lineLimit(1) }
            Cell(width: widths[4]) { Text(key.onUpdate.rawValue).lineLimit(1) }
            Cell(width: widths[5]) { Text(key.onDelete.rawValue).lineLimit(1) }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .contentShape(Rectangle())
        .onTapGesture { controller.selectedForeignKeyID = key.id }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The table's name, with its schema only when that is not the schema being edited.
    static func tableTitle(_ table: TableRef, from home: TableRef) -> String {
        table.schema == home.schema || table.schema.isEmpty ? table.name : "\(table.schema).\(table.name)"
    }

    private func selectFirstIfNeeded() {
        if selectedIndex == nil { controller.selectedForeignKeyID = keys.first?.id }
    }

    /// A new key starts on the first column that has none yet and points nowhere: the
    /// table is the first thing chosen, and choosing it fills in the rest.
    private func add() {
        let table = controller.currentTable
        let taken = Set(keys.flatMap(\.columns))
        let columns = controller.edited?.columns ?? []
        let primaryKey = Set(controller.edited?.primaryKey ?? [])
        let first =
            columns.first { !taken.contains($0.name) && !primaryKey.contains($0.name) && $0.name.hasSuffix("_id") }
            ?? columns.first { !taken.contains($0.name) && !primaryKey.contains($0.name) }
        let key = ForeignKeyDefinition(
            name: ForeignKeyAdvice.suggestedName(
                table: table.name, columns: first.map { [$0.name] } ?? [], dialect: controller.dialect),
            columns: first.map { [$0.name] } ?? [],
            referencedTable: TableRef(database: table.database, schema: table.schema, name: ""),
            referencedColumns: first == nil ? [] : [""]
        )
        controller.edited?.foreignKeys.append(key)
        controller.selectedForeignKeyID = key.id
    }

    private func remove() {
        guard let index = selectedIndex ?? keys.indices.last else { return }
        controller.edited?.foreignKeys.remove(at: index)
        let remaining = controller.edited?.foreignKeys ?? []
        controller.selectedForeignKeyID = remaining[safe: min(index, remaining.count - 1)]?.id
    }
}

/// The selected foreign key, a field at a time.
private struct ForeignKeyEditor: View {
    @Bindable var controller: StructureController
    let index: Int
    let key: ForeignKeyDefinition

    private var dialect: SQLDialect { controller.dialect }
    private var isEditing: Bool { controller.isEditing }
    private var columns: [ColumnDefinition] { controller.edited?.columns ?? [] }
    private var target: ForeignKeyTarget? { controller.referenceTarget(key.referencedTable) }
    private var tables: [TableRef] { controller.referenceTables[key.referencedTable.schemaRef] ?? [] }
    /// The name this editor would give the key as it stands, to tell a name that was
    /// typed from one that was suggested.
    private var suggestedName: String {
        ForeignKeyAdvice.suggestedName(table: controller.currentTable.name, columns: key.columns, dialect: dialect)
    }

    private var problems: [ForeignKeyAdvice.Problem] {
        // A key that was read from the server and not touched is the server's business.
        guard isEditing else { return [] }
        return ForeignKeyAdvice.problems(
            with: key,
            columns: columns.map { .init(name: $0.name, type: $0.type, isNullable: $0.isNullable) },
            referenced: target?.columns.map { .init(name: $0.name, type: $0.type) },
            referencedKeys: target?.keys ?? [],
            dialect: dialect
        )
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                FieldRow(label: "Name") {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        TextField("name", text: binding(\.name))
                            .disabled(!isEditing)
                            .accessibilityLabel("foreign key name")
                        Button("Suggest") { update { $0.name = suggestedName } }
                            .disabled(!isEditing || key.name == suggestedName)
                            .help("Name the key after its table and columns, as \(dialect.displayName) would")
                    }
                }

                FieldRow(label: "References") {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        if controller.referenceSchemas.count > 1 {
                            BarPopUp(
                                items: controller.referenceSchemas.map {
                                    BarPopUp.Item(id: $0, title: $0.schema, icon: Icon.schema)
                                },
                                selection: Binding(get: { key.referencedTable.schemaRef }, set: setSchema)
                            )
                            .frame(width: 160)
                            .accessibilityLabel("referenced schema")
                        }
                        BarPopUp(
                            items: tableItems,
                            selection: Binding(get: { key.referencedTable.name }, set: setTable)
                        )
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("referenced table")
                    }
                    .disabled(!isEditing)
                }

                FieldRow(label: "Columns") {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        ForEach(Array(key.columns.enumerated()), id: \.offset) { position, _ in
                            pair(position)
                        }
                        if isEditing {
                            Button {
                                addPair()
                            } label: {
                                Label("Add Column", systemImage: Icon.add)
                            }
                            .buttonStyle(.borderless)
                            .disabled(key.columns.count >= columns.count)
                            .help("A key over several columns points at a key of as many")
                        }
                    }
                }

                actionRow("On delete", onDelete: true)
                actionRow("On update", onDelete: false)

                if ForeignKeyAdvice.supportsDeferral(dialect) {
                    FieldRow(label: "Check") {
                        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                            BarPopUp(
                                items: [
                                    BarPopUp.Item(id: 0, title: "After each statement (NOT DEFERRABLE)"),
                                    BarPopUp.Item(id: 1, title: "DEFERRABLE INITIALLY IMMEDIATE"),
                                    BarPopUp.Item(id: 2, title: "DEFERRABLE INITIALLY DEFERRED"),
                                ],
                                selection: Binding(
                                    get: { !key.isDeferrable ? 0 : key.isInitiallyDeferred ? 2 : 1 },
                                    set: { value in
                                        update {
                                            $0.isDeferrable = value > 0
                                            $0.isInitiallyDeferred = value == 2
                                        }
                                    }
                                )
                            )
                            .frame(maxWidth: .infinity)
                            .disabled(!isEditing)
                            .accessibilityLabel("when the key is checked")
                            note(deferralNote)
                        }
                    }
                }

                ForEach(problems) { problem in
                    FieldRow(label: "") {
                        Label {
                            Text(problem.message)
                                .font(.caption)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        } icon: {
                            Image(systemName: problem.severity == .error ? Icon.error : Icon.warning)
                                .foregroundStyle(problem.severity == .error ? Color.red : Color.orange)
                        }
                        .help(problem.message)
                    }
                }
            }
            .controlSize(.small)
            .padding(DesignTokens.Spacing.lg)
            .frame(maxWidth: 640)
            .frame(maxWidth: .infinity)
        }
        .frame(maxHeight: 340)
        .task(id: key.referencedTable) {
            await controller.loadReferenceTables(in: key.referencedTable.schemaRef)
            await controller.loadReferenceTarget(key.referencedTable)
        }
    }

    // MARK: - Rows

    /// One column here and the column it points at.
    private func pair(_ position: Int) -> some View {
        let local = key.columns[safe: position] ?? ""
        let remote = key.referencedColumns[safe: position] ?? ""
        return HStack(spacing: DesignTokens.Spacing.xs) {
            BarPopUp(
                items: localItems(current: local),
                selection: Binding(get: { local }, set: { setLocal($0, at: position) })
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel("column \(position + 1)")

            Image(systemName: Icon.arrowRight)
                .foregroundStyle(.secondary)
                .frame(width: DesignTokens.Metrics.iconWidth)

            BarPopUp(
                items: remoteItems(current: remote),
                selection: Binding(get: { remote }, set: { setRemote($0, at: position) })
            )
            .frame(maxWidth: .infinity)
            .accessibilityLabel("referenced column \(position + 1)")

            if isEditing {
                IconButton(icon: Icon.remove, label: "Remove this column from the key") { removePair(position) }
                    .disabled(key.columns.count <= 1)
            }
        }
        .disabled(!isEditing)
    }

    private func actionRow(_ label: String, onDelete: Bool) -> some View {
        let action = onDelete ? key.onDelete : key.onUpdate
        // An action the engine does not offer is still shown when the key already has it.
        let offered = ForeignKeyAdvice.actions(for: dialect)
        let actions = offered.contains(action) ? offered : offered + [action]
        return FieldRow(label: label) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                BarPopUp(
                    items: actions.map { BarPopUp.Item(id: $0, title: $0.rawValue) },
                    selection: Binding(
                        get: { action },
                        set: { value in update { if onDelete { $0.onDelete = value } else { $0.onUpdate = value } } }
                    )
                )
                .frame(maxWidth: .infinity)
                .disabled(!isEditing)
                .accessibilityLabel("\(key.name) \(label.lowercased())")
                note(ForeignKeyAdvice.explanation(of: action, onDelete: onDelete, dialect: dialect))
            }
        }
    }

    /// Bounded, never `fixedSize`: a text that sizes its own height asks for one line per
    /// word when measured narrow, and the pane then outgrows the window.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(text)
    }

    private var deferralNote: String {
        if !key.isDeferrable { return "Every statement must leave the key satisfied." }
        return key.isInitiallyDeferred
            ? "The key is checked when the transaction commits, so rows can be written in any order inside it."
            : "Checked after each statement, unless a transaction asks for SET CONSTRAINTS … DEFERRED."
    }

    // MARK: - Choices

    private var tableItems: [BarPopUp<String>.Item] {
        var items: [BarPopUp<String>.Item] = []
        let name = key.referencedTable.name
        if name.isEmpty {
            items.append(BarPopUp.Item(id: "", title: "Choose a table…"))
        } else if !tables.contains(where: { $0.name == name }), name != controller.currentTable.name {
            // Still being listed, or a table the list does not carry: shown as it is.
            items.append(BarPopUp.Item(id: name, title: name, icon: Icon.table))
        }
        // The table itself is always a choice — a row can point at another row of its
        // own table — under the name it has in the edit, which the server may not know yet.
        let own = controller.currentTable
        if key.referencedTable.schemaRef == own.schemaRef, !own.name.isEmpty {
            items.append(BarPopUp.Item(id: own.name, title: "\(own.name) (this table)", icon: Icon.table))
        }
        return items
            + tables.filter { $0 != own && $0 != controller.table }.map {
                BarPopUp.Item(id: $0.name, title: $0.name, icon: Icon.table)
            }
    }

    private func localItems(current: String) -> [BarPopUp<String>.Item] {
        let others = Set(key.columns).subtracting([current])
        var items: [BarPopUp<String>.Item] = []
        if !columns.contains(where: { $0.name == current }) {
            items.append(BarPopUp.Item(id: current, title: current.isEmpty ? "Choose a column…" : current))
        }
        return items
            + columns.filter { !others.contains($0.name) }.map {
                BarPopUp.Item(id: $0.name, title: "\($0.name) · \($0.type)", icon: Icon.column)
            }
    }

    /// The referenced table's columns: those of a key first, since only they can be
    /// pointed at, then the rest for the server that allows it.
    private func remoteItems(current: String) -> [BarPopUp<String>.Item] {
        guard let target else {
            return [
                BarPopUp.Item(
                    id: current,
                    title: current.isEmpty
                        ? (key.referencedTable.name.isEmpty ? "Choose a table first" : "Reading the columns…")
                        : current)
            ]
        }
        let keyed = Set(target.keys.flatMap { $0 })
        var items: [BarPopUp<String>.Item] = []
        if !target.columns.contains(where: { $0.name == current }) {
            items.append(BarPopUp.Item(id: current, title: current.isEmpty ? "Choose a column…" : current))
        }
        let primary = Set(target.primaryKey)
        items += target.columns.filter { keyed.contains($0.name) }.map {
            BarPopUp.Item(
                id: $0.name, title: "\($0.name) · \($0.type)", icon: Icon.key,
                section: "Primary key and unique columns",
                help: primary.contains($0.name) ? "Primary key" : "Unique")
        }
        items += target.columns.filter { !keyed.contains($0.name) }.map {
            BarPopUp.Item(
                id: $0.name, title: "\($0.name) · \($0.type)", icon: Icon.column, section: "Other columns",
                help: "Not unique on its own: a key can point here only with an index the engine accepts")
        }
        return items
    }

    // MARK: - Changes

    private func update(_ change: (inout ForeignKeyDefinition) -> Void) {
        guard var edited = controller.edited?.foreignKeys[safe: index] else { return }
        let followsSuggestion = edited.name == suggestedName || edited.name.isEmpty
        change(&edited)
        // Both lists are one list of pairs; a key read with them uneven is evened out.
        while edited.referencedColumns.count < edited.columns.count { edited.referencedColumns.append("") }
        if edited.referencedColumns.count > edited.columns.count {
            edited.referencedColumns.removeLast(edited.referencedColumns.count - edited.columns.count)
        }
        // A name nobody typed keeps following the columns; one that was typed is left alone.
        if followsSuggestion, controller.isExistingKey(edited.id) == false {
            edited.name = ForeignKeyAdvice.suggestedName(
                table: controller.currentTable.name, columns: edited.columns, dialect: dialect)
        }
        controller.edited?.foreignKeys[safe: index] = edited
    }

    private func binding(_ path: WritableKeyPath<ForeignKeyDefinition, String>) -> Binding<String> {
        Binding(
            get: { controller.edited?.foreignKeys[safe: index]?[keyPath: path] ?? "" },
            set: { controller.edited?.foreignKeys[safe: index]?[keyPath: path] = $0 }
        )
    }

    private func setSchema(_ schema: SchemaRef) {
        guard schema != key.referencedTable.schemaRef else { return }
        update {
            $0.referencedTable = TableRef(database: schema.database, schema: schema.schema, name: "")
            $0.referencedColumns = Array(repeating: "", count: $0.columns.count)
        }
    }

    /// Choosing the table fills in what can be known: the columns of its primary key, and
    /// — when the key has one column and nothing was chosen here — the column that is
    /// named after it.
    private func setTable(_ name: String) {
        guard name != key.referencedTable.name, !name.isEmpty else { return }
        let old = key.referencedTable
        let table = TableRef(database: old.database, schema: old.schema, name: name)
        update {
            $0.referencedTable = table
            $0.referencedColumns = Array(repeating: "", count: $0.columns.count)
        }
        Task {
            await controller.loadReferenceTarget(table)
            fillFromPrimaryKey(of: table)
        }
    }

    private func fillFromPrimaryKey(of table: TableRef) {
        guard let current = controller.edited?.foreignKeys[safe: index], current.id == key.id,
            current.referencedTable == table, current.referencedColumns.allSatisfy(\.isEmpty),
            let target = controller.referenceTarget(table), !target.primaryKey.isEmpty
        else { return }
        update { edited in
            if edited.columns.count == target.primaryKey.count {
                edited.referencedColumns = target.primaryKey
            } else if edited.columns.count < target.primaryKey.count, edited.columns.count <= 1 {
                // A composite key: a column here for each of its columns, by name where
                // one matches, and left to be chosen where none does.
                let taken = Set(edited.columns)
                var locals = edited.columns
                for name in target.primaryKey.dropFirst(locals.count) {
                    let match = columns.first { $0.name == name && !taken.contains($0.name) }?.name
                    locals.append(match ?? "")
                }
                edited.columns = locals
                edited.referencedColumns = target.primaryKey
            }
            guard target.primaryKey.count == 1, let local = guessLocalColumn(for: table, key: target.primaryKey[0])
            else { return }
            let others = Set((controller.edited?.foreignKeys ?? []).filter { $0.id != edited.id }.flatMap(\.columns))
            if edited.columns.count == 1, !others.contains(local) { edited.columns = [local] }
        }
    }

    /// `customers.id` is pointed at by `customer_id`, `customers_id` or `id_customer`.
    private func guessLocalColumn(for table: TableRef, key: String) -> String? {
        let name = table.name.lowercased()
        let singular =
            name.hasSuffix("ies")
            ? String(name.dropLast(3)) + "y" : name.hasSuffix("s") ? String(name.dropLast()) : name
        let key = key.lowercased()
        let candidates = [
            "\(singular)_\(key)", "\(name)_\(key)", "\(key)_\(singular)", "\(key)_\(name)", "\(singular)\(key)",
        ]
        return columns.first { candidates.contains($0.name.lowercased()) }?.name
    }

    private func setLocal(_ name: String, at position: Int) {
        update { if $0.columns.indices.contains(position) { $0.columns[position] = name } }
    }

    private func setRemote(_ name: String, at position: Int) {
        update { if $0.referencedColumns.indices.contains(position) { $0.referencedColumns[position] = name } }
    }

    private func addPair() {
        let taken = Set(key.columns)
        guard let next = columns.first(where: { !taken.contains($0.name) }) else { return }
        update {
            $0.columns.append(next.name)
            $0.referencedColumns.append("")
        }
    }

    private func removePair(_ position: Int) {
        update {
            guard $0.columns.indices.contains(position) else { return }
            $0.columns.remove(at: position)
            if $0.referencedColumns.indices.contains(position) { $0.referencedColumns.remove(at: position) }
        }
    }
}
