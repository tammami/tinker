import DBCore
import DBGrid
import DBSQL
import DBStore
import Foundation

/// The foreign-key side of a grid, shared by table tabs and query results: which cells
/// point at a row of another table, the label shown beside such a value ("Ada" for
/// customer 1), and the picker that chooses a referenced row instead of typing its key.
///
/// A table tab serves one table, so a result column is that table's column of the same
/// name. A query result may read several tables (a JOIN) under aliases; there each
/// column's origin is settled first (`ResultColumnOrigins`), and only columns with a
/// known origin take part.
@MainActor
public final class ReferenceSupport {
    private struct Key {
        let table: TableRef
        let key: ForeignKeyInfo
    }

    private var keys: [Key] = []
    /// The single table every column belongs to, on a table tab.
    private var singleTable: TableRef?
    /// Where each result column came from, on a query result; nil on a table tab.
    private var origins: [Int: ColumnOrigin]?
    /// The label column each referenced table is searched by in the picker, remembered so
    /// the next lookup opens the same way. Keyed by the referenced table's id.
    private var referenceLabels: [String: String] = [:]
    /// The label beside each foreign-key value on the loaded rows, by column index, then
    /// by the value's text. Filled a page at a time, one query per key.
    private var labelCache: [Int: [String: String]] = [:]
    /// The label column of each referenced table once it has been settled, by table id;
    /// an entry holding nil means the table has no column that reads as a name.
    private var settledLabelColumns: [String: String?] = [:]
    private var labelResolution: Task<Void, Never>?

    private let environment: AppEnvironment
    private let connectionID: UUID
    private let dialect: SQLDialect

    public init(environment: AppEnvironment, connectionID: UUID, dialect: SQLDialect) {
        self.environment = environment
        self.connectionID = connectionID
        self.dialect = dialect
    }

    /// The foreign keys of every table taking part, in table order.
    public var foreignKeys: [ForeignKeyInfo] { keys.map(\.key) }

    // MARK: - Loading

    /// Reads `table`'s foreign keys for a grid whose every column is a column of `table`.
    public func load(table: TableRef, session: ConnectionSession) async {
        singleTable = table
        origins = nil
        keys = await foreignKeys(of: [table], session: session)
        await rememberLabelColumns()
    }

    /// Reads the foreign keys of the tables a statement names and settles which of them
    /// each result column came from. Nothing is kept for a result no column of which
    /// belongs to a table with a key.
    public func load(tables: [TableRef], columns: [ColumnMeta], session: ConnectionSession) async {
        singleTable = nil
        var sources: [ResultColumnOrigins.Source] = []
        for table in tables {
            let names =
                (try? await session.introspection(.columns(table)) { try await $0.columns(of: table) })?.map(\.name)
                ?? []
            sources.append(ResultColumnOrigins.Source(table: table, columns: names))
        }
        let resolved = ResultColumnOrigins.resolve(columns: columns, sources: sources)
        origins = resolved
        let involved = tables.filter { table in resolved.values.contains { $0.table.id == table.id } }
        keys = await foreignKeys(of: involved, session: session)
        // A key none of the result's columns carries can never be followed.
        keys = keys.filter { entry in
            entry.key.columns.allSatisfy { column in
                resolved.values.contains { $0.table.id == entry.table.id && $0.column == column }
            }
        }
        await rememberLabelColumns()
    }

    private func foreignKeys(of tables: [TableRef], session: ConnectionSession) async -> [Key] {
        var found: [Key] = []
        for table in tables {
            let keys =
                (try? await session.introspection(.foreignKeys(table)) {
                    try await $0.foreignKeys(of: table)
                }) ?? []
            found.append(contentsOf: keys.map { Key(table: table, key: $0) })
        }
        return found
    }

    /// The label column each referenced table was last searched by, so a picker opens the
    /// way it did before. A handful of keys, read once with the structure.
    private func rememberLabelColumns() async {
        for entry in keys where referenceLabels[entry.key.referencedTable.id] == nil {
            let stored = await environment.gridPreferences(
                connectionID: connectionID, table: entry.key.referencedTable.id
            ).labelColumn
            if let stored { referenceLabels[entry.key.referencedTable.id] = stored }
        }
    }

    // MARK: - Columns

    /// The table and column a grid column stands for, when known.
    private func origin(of column: Int, in model: GridModel) -> ColumnOrigin? {
        guard model.columns.indices.contains(column) else { return nil }
        if let origins { return origins[column] }
        guard let singleTable else { return nil }
        return ColumnOrigin(table: singleTable, column: model.columns[column].name)
    }

    /// The grid column that carries `table`'s `column`, if the result has it.
    private func index(of column: String, in table: TableRef, model: GridModel) -> Int? {
        if let origins {
            return origins.first { $0.value.table.id == table.id && $0.value.column == column }?.key
        }
        return model.columns.firstIndex { $0.name == column }
    }

    private func key(forColumn column: Int, in model: GridModel) -> Key? {
        guard let origin = origin(of: column, in: model) else { return nil }
        return keys.first { $0.table.id == origin.table.id && $0.key.columns.contains(origin.column) }
    }

    /// Whether the column is (part of) a foreign key, so its value can be picked.
    public func columnReferences(_ column: Int, in model: GridModel) -> Bool {
        key(forColumn: column, in: model) != nil
    }

    /// The foreign key a column takes part in, and the value the row holds for it, as the
    /// filter that finds the referenced row. Nil when any key column is NULL or missing.
    public func target(row: Int, column: Int, in model: GridModel) -> (table: TableRef, filter: [FilterRule])? {
        guard let entry = key(forColumn: column, in: model) else { return nil }
        var rules: [FilterRule] = []
        for (local, remote) in zip(entry.key.columns, entry.key.referencedColumns) {
            guard let index = index(of: local, in: entry.table, model: model),
                let value = model.value(row: row, column: index), !value.isNull
            else { return nil }
            rules.append(FilterRule(column: remote, op: .equal, values: [value]))
        }
        return rules.isEmpty ? nil : (entry.key.referencedTable, rules)
    }

    // MARK: - Labels

    /// What a foreign-key cell's value points at, once looked up. A dictionary lookup: it
    /// is asked for every visible cell on every reload.
    public func label(row: Int, column: Int, in model: GridModel) -> String? {
        guard let byValue = labelCache[column],
            let text = model.value(row: row, column: column)?.text,
            let label = byValue[text], !label.isEmpty
        else { return nil }
        return label
    }

    /// Looks up, shortly after the grid changed, the labels of foreign-key values that are
    /// loaded and not known yet. Nothing new means no query; `onLearned` runs when the
    /// grid has something new to draw.
    public func scheduleLabels(
        model: GridModel, session: ConnectionSession, onLearned: @escaping @MainActor () -> Void
    ) {
        guard !keys.isEmpty else { return }
        labelResolution?.cancel()
        labelResolution = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled, let self else { return }
            if await self.resolveLabels(model: model, session: session) { onLearned() }
        }
    }

    private func resolveLabels(model: GridModel, session: ConnectionSession) async -> Bool {
        var learned = false
        for entry in keys where entry.key.columns.count == 1 {
            guard let index = index(of: entry.key.columns[0], in: entry.table, model: model) else { continue }
            let lookup = ReferenceLookup(session: session, key: entry.key, dialect: dialect)
            guard let label = await settledLabelColumn(for: entry.key, lookup: lookup) else { continue }

            var known = labelCache[index] ?? [:]
            var unresolved: [String: DBValue] = [:]
            for row in 0 ..< model.rowCount {
                guard let value = model.value(row: row, column: index), !value.isNull, let text = value.text,
                    known[text] == nil, unresolved[text] == nil
                else { continue }
                unresolved[text] = value
            }
            guard !unresolved.isEmpty,
                let found = try? await lookup.labels(forKeys: Array(unresolved.values), label: label)
            else { continue }
            // A key the table does not hold is remembered as blank, so it is not asked again.
            for text in unresolved.keys { known[text] = found[text] ?? "" }
            labelCache[index] = known
            learned = true
        }
        return learned
    }

    /// The remembered label column, else the one the lookup would choose, settled once.
    private func settledLabelColumn(for key: ForeignKeyInfo, lookup: ReferenceLookup) async -> String? {
        let id = key.referencedTable.id
        if let settled = settledLabelColumns[id] { return settled }
        if let stored = referenceLabels[id] {
            settledLabelColumns[id] = stored
            return stored
        }
        let columns = (try? await lookup.columns()) ?? []
        let chosen = ReferenceLookup.labelColumn(among: columns, keyColumns: key.referencedColumns)
        settledLabelColumns[id] = .some(chosen)
        return chosen
    }

    // MARK: - Picking

    /// A picker over the referenced table for this cell, seeded with the current value and
    /// the remembered label column. `onLabelChanged` runs when the picker settles on
    /// another label column, so the grid redraws the labels beside its values.
    public func picker(
        row: Int, column: Int, in model: GridModel, session: ConnectionSession,
        onLabelChanged: @escaping @MainActor () -> Void
    ) -> ReferencePickerModel? {
        guard let entry = key(forColumn: column, in: model) else { return nil }

        // The header shows every local key column's current value, so a composite key is
        // legible too.
        let current =
            entry.key.columns
            .compactMap { local -> String? in
                guard let index = index(of: local, in: entry.table, model: model),
                    let value = model.value(row: row, column: index), !value.isNull
                else { return nil }
                return value.text
            }
            .joined(separator: ", ")
        let isNullable = model.columns[column].isNullable != false

        let referencedTableID = entry.key.referencedTable.id
        return ReferencePickerModel(
            session: session,
            key: entry.key,
            dialect: dialect,
            storedLabel: referenceLabels[referencedTableID],
            currentText: current.isEmpty ? nil : current,
            isNullable: isNullable,
            onPersistLabel: { [weak self] chosen in
                guard let self else { return }
                if let chosen {
                    self.referenceLabels[referencedTableID] = chosen
                } else {
                    self.referenceLabels.removeValue(forKey: referencedTableID)
                }
                // The labels beside the values follow the new column.
                self.settledLabelColumns.removeValue(forKey: referencedTableID)
                for entry in self.keys where entry.key.referencedTable.id == referencedTableID {
                    for local in entry.key.columns {
                        if let index = self.index(of: local, in: entry.table, model: model) {
                            self.labelCache.removeValue(forKey: index)
                        }
                    }
                }
                Task { [weak self] in await self?.persistLabel(chosen, for: referencedTableID) }
                onLabelChanged()
            }
        )
    }

    /// Writes a chosen referenced key, keyed by referenced column name, into the row's
    /// local key columns. Returns false when the column is not a foreign key.
    public func apply(key: [String: DBValue], row: Int, column: Int, in model: GridModel) -> Bool {
        guard let entry = self.key(forColumn: column, in: model) else { return false }
        for (local, referenced) in zip(entry.key.columns, entry.key.referencedColumns) {
            guard let index = index(of: local, in: entry.table, model: model), let value = key[referenced] else {
                continue
            }
            model.setValue(value, row: row, column: index)
        }
        return true
    }

    /// Saves the picker's label choice into the referenced table's own grid preferences,
    /// so it is remembered wherever that table is shown.
    private func persistLabel(_ label: String?, for referencedTable: String) async {
        var preferences = await environment.gridPreferences(connectionID: connectionID, table: referencedTable)
        preferences.labelColumn = label
        await environment.saveGridPreferences(preferences, connectionID: connectionID, table: referencedTable)
    }
}
