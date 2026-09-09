import DBCore
import Foundation

/// One structure statement, with what the user needs to know before running it.
public struct GeneratedDDL: Sendable, Hashable, Identifiable {
    /// What the statement does, which is what the preview groups and colours by.
    public enum Kind: String, Sendable, Hashable, CaseIterable {
        case createTable
        case dropTable
        case renameTable
        case addColumn
        case alterColumn
        case renameColumn
        case dropColumn
        case addPrimaryKey
        case dropPrimaryKey
        case createIndex
        case dropIndex
        case renameIndex
        case addForeignKey
        case dropForeignKey
        case addCheck
        case dropCheck
        case createTrigger
        case dropTrigger
        case comment
        case tableOption
        case partition
    }

    public let kind: Kind
    public let sql: String
    public let table: TableRef
    public let id: UUID

    /// True when running this loses data the user cannot get back: a dropped column, a
    /// dropped table, a narrowed type. The preview lists these apart and leaves them
    /// unchecked (SPEC §15b.4).
    public let isDestructive: Bool

    public init(
        kind: Kind,
        sql: String,
        table: TableRef,
        isDestructive: Bool = false,
        id: UUID = UUID()
    ) {
        self.kind = kind
        self.sql = sql
        self.table = table
        self.isDestructive = isDestructive
        self.id = id
    }
}

/// Turns the difference between two `TableDefinition`s into statements (SPEC §15b.2).
///
/// The generator never talks to a server and never guesses at the current state: it is
/// handed what introspection read and what the user edited, and emits the difference. What
/// it cannot express, it refuses to express rather than approximating.
public struct DDLGenerator: Sendable {
    public let dialect: SQLDialect

    public init(dialect: SQLDialect) {
        self.dialect = dialect
    }

    // MARK: - Create

    /// The statements that build `definition` from nothing (SPEC §15b.3).
    public func create(_ definition: TableDefinition) -> [GeneratedDDL] {
        var statements: [GeneratedDDL] = []
        let table = qualified(definition.ref)

        var body: [String] = definition.columns.map { columnClause($0, in: definition) }
        if !definition.primaryKey.isEmpty, sqliteInlinePrimaryKey(definition) == nil {
            body.append("PRIMARY KEY (\(columnList(definition.primaryKey)))")
        }
        for check in definition.checks {
            body.append("CONSTRAINT \(quote(check.name)) CHECK (\(check.expression))")
        }
        for key in definition.foreignKeys {
            body.append("CONSTRAINT \(quote(key.name)) \(foreignKeyClause(key))")
        }

        var create = "CREATE TABLE \(table) (\n    \(body.joined(separator: ",\n    "))\n)"
        if let suffix = tableSuffix(definition) { create += " \(suffix)" }
        if let partitioning = definition.partitioning {
            create += partitionClause(partitioning)
        }
        statements.append(GeneratedDDL(kind: .createTable, sql: create, table: definition.ref))

        if dialect == .postgresql, let partitioning = definition.partitioning {
            statements.append(
                contentsOf: partitioning.partitions.map {
                    addPartition($0, to: definition.ref)
                })
        }
        statements.append(
            contentsOf: definition.indexes.map {
                GeneratedDDL(kind: .createIndex, sql: createIndexSQL($0, on: definition.ref), table: definition.ref)
            })
        statements.append(contentsOf: comments(for: definition, against: nil))
        statements.append(
            contentsOf: definition.triggers.map {
                GeneratedDDL(kind: .createTrigger, sql: createTriggerSQL($0, on: definition.ref), table: definition.ref)
            })
        return statements
    }

    // MARK: - Alter

    /// The statements that take `current` to `edited`.
    ///
    /// Order matters and is fixed: constraints that might block a column change come off
    /// first, then the columns change, then the constraints that depend on the new shape go
    /// back on. Anything else produces statements the server rejects for reasons that have
    /// nothing to do with what the user asked for.
    public func alter(from current: TableDefinition, to edited: TableDefinition) -> [GeneratedDDL] {
        if dialect == .sqlite { return sqliteAlter(from: current, to: edited) }
        var statements: [GeneratedDDL] = []
        let table = edited.ref

        // 1. Drop what is going away or being rebuilt, dependants first.
        statements.append(contentsOf: droppedTriggers(current, edited))
        statements.append(contentsOf: droppedForeignKeys(current, edited))
        statements.append(contentsOf: droppedChecks(current, edited))
        statements.append(contentsOf: droppedIndexes(current, edited))
        if primaryKeyChanged(current, edited), !current.primaryKey.isEmpty {
            statements.append(dropPrimaryKey(on: table))
        }

        // 2. Columns.
        statements.append(contentsOf: columnStatements(current, edited))

        statements.append(contentsOf: columnOrderStatements(current, edited))

        // 3. Put the constraints back, now that the columns are what they should be.
        if primaryKeyChanged(current, edited), !edited.primaryKey.isEmpty {
            statements.append(
                GeneratedDDL(
                    kind: .addPrimaryKey,
                    sql: "ALTER TABLE \(qualified(table)) ADD PRIMARY KEY (\(columnList(edited.primaryKey)))",
                    table: table
                ))
        }
        statements.append(contentsOf: addedIndexes(current, edited))
        statements.append(contentsOf: addedChecks(current, edited))
        statements.append(contentsOf: addedForeignKeys(current, edited))
        statements.append(contentsOf: addedTriggers(current, edited))
        statements.append(contentsOf: partitionStatements(current, edited))

        // 4. Cosmetics last: they never block anything.
        statements.append(contentsOf: comments(for: edited, against: current))
        statements.append(contentsOf: tableOptionStatements(current, edited))
        if current.ref.name != edited.ref.name {
            statements.append(renameTable(from: current.ref, to: edited.ref))
        }
        return statements
    }

    // MARK: - Columns

    private func columnStatements(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        var statements: [GeneratedDDL] = []
        let table = edited.ref
        let currentByID = Dictionary(uniqueKeysWithValues: current.columns.map { ($0.id, $0) })
        let editedIDs = Set(edited.columns.map(\.id))

        // Dropped: in the original, gone from the edit.
        for column in current.columns where !editedIDs.contains(column.id) {
            statements.append(
                GeneratedDDL(
                    kind: .dropColumn,
                    sql: "ALTER TABLE \(qualified(table)) DROP COLUMN \(quote(column.name))",
                    table: table,
                    isDestructive: true
                ))
        }

        for column in edited.columns {
            guard let before = currentByID[column.id] else {
                statements.append(
                    GeneratedDDL(
                        kind: .addColumn,
                        sql: "ALTER TABLE \(qualified(table)) ADD COLUMN \(columnClause(column))",
                        table: table
                    ))
                continue
            }
            // A rename is a different statement from a change of definition, and on MySQL
            // the two are the same statement, so the order below matters.
            if before.name != column.name {
                statements.append(renameColumn(from: before.name, to: column.name, on: table))
            }
            if !before.matchesDefinition(of: column) {
                statements.append(contentsOf: alterColumn(from: before, to: column, on: table))
            }
        }
        return statements
    }

    private func renameColumn(from old: String, to new: String, on table: TableRef) -> GeneratedDDL {
        GeneratedDDL(
            kind: .renameColumn,
            sql: "ALTER TABLE \(qualified(table)) RENAME COLUMN \(quote(old)) TO \(quote(new))",
            table: table
        )
    }

    /// PostgreSQL changes one facet at a time; MySQL restates the whole column. SQLite
    /// has no `ALTER COLUMN` at all and never reaches this: ``sqliteAlter(from:to:)``
    /// rebuilds the table instead.
    private func alterColumn(
        from before: ColumnDefinition, to after: ColumnDefinition, on table: TableRef
    ) -> [GeneratedDDL] {
        let prefix = "ALTER TABLE \(qualified(table))"
        switch dialect {
        case .sqlite:
            return []
        case .mysql:
            return [
                GeneratedDDL(
                    kind: .alterColumn,
                    sql: "\(prefix) MODIFY COLUMN \(columnClause(after))",
                    table: table,
                    isDestructive: before.type != after.type
                )
            ]

        case .postgresql:
            var statements: [GeneratedDDL] = []
            let column = quote(after.name)
            if before.type != after.type {
                // USING lets the server cast what it can; without it a widening that needs
                // a cast fails outright.
                statements.append(
                    GeneratedDDL(
                        kind: .alterColumn,
                        sql:
                            "\(prefix) ALTER COLUMN \(column) TYPE \(typeText(after.type)) "
                            + "USING \(column)::\(typeText(after.type))",
                        table: table,
                        isDestructive: true
                    ))
            }
            if before.isNullable != after.isNullable {
                statements.append(
                    GeneratedDDL(
                        kind: .alterColumn,
                        sql: "\(prefix) ALTER COLUMN \(column) \(after.isNullable ? "DROP" : "SET") NOT NULL",
                        table: table
                    ))
            }
            if before.defaultExpression != after.defaultExpression {
                let action = after.defaultExpression.map { "SET DEFAULT \($0)" } ?? "DROP DEFAULT"
                statements.append(
                    GeneratedDDL(
                        kind: .alterColumn,
                        sql: "\(prefix) ALTER COLUMN \(column) \(action)",
                        table: table
                    ))
            }
            if before.isAutoIncrement != after.isAutoIncrement {
                let action =
                    after.isAutoIncrement
                    ? "ADD GENERATED BY DEFAULT AS IDENTITY"
                    : "DROP IDENTITY IF EXISTS"
                statements.append(
                    GeneratedDDL(
                        kind: .alterColumn,
                        sql: "\(prefix) ALTER COLUMN \(column) \(action)",
                        table: table
                    ))
            }
            return statements
        }
    }

    /// The column as it appears inside `CREATE TABLE` or after `ADD COLUMN`.
    public func columnClause(_ column: ColumnDefinition) -> String {
        columnClause(column, in: nil)
    }

    /// The column clause, knowing the table it sits in: on SQLite a lone `INTEGER` primary
    /// key is declared inline, because that is the only way to ask for `AUTOINCREMENT`.
    func columnClause(_ column: ColumnDefinition, in definition: TableDefinition?) -> String {
        var parts = [quote(column.name), typeText(column.type)]
        if let characterSet = column.characterSet, dialect == .mysql {
            parts.append("CHARACTER SET \(safeName(characterSet))")
        }
        if let collation = column.collation {
            // PostgreSQL collations are identifiers; MySQL's and SQLite's are bare names.
            parts.append(dialect == .postgresql ? "COLLATE \(quote(collation))" : "COLLATE \(safeName(collation))")
        }
        if dialect == .sqlite, let definition, sqliteInlinePrimaryKey(definition) == column.name {
            parts.append("PRIMARY KEY AUTOINCREMENT")
        }
        if let generated = column.generatedExpression {
            parts.append("GENERATED ALWAYS AS (\(generated))")
            parts.append(column.isGeneratedStored ? "STORED" : "VIRTUAL")
            // A generated column takes neither a default nor NOT NULL in the usual way.
            return parts.joined(separator: " ")
        }
        if !column.isNullable { parts.append("NOT NULL") }
        if let expression = column.defaultExpression {
            parts.append("DEFAULT \(expression)")
        }
        if column.isAutoIncrement {
            switch dialect {
            case .mysql: parts.append("AUTO_INCREMENT")
            case .postgresql: parts.append("GENERATED BY DEFAULT AS IDENTITY")
            // Handled above: SQLite has AUTOINCREMENT only on an inline INTEGER PRIMARY KEY,
            // and any other column simply cannot have one.
            case .sqlite: break
            }
        }
        if let comment = column.comment, dialect == .mysql, !comment.isEmpty {
            parts.append("COMMENT \(quoteText(comment))")
        }
        return parts.joined(separator: " ")
    }

    // MARK: - Primary key

    private func primaryKeyChanged(_ current: TableDefinition, _ edited: TableDefinition) -> Bool {
        current.primaryKey != edited.primaryKey
    }

    private func dropPrimaryKey(on table: TableRef) -> GeneratedDDL {
        // PostgreSQL drops the constraint by name and names it <table>_pkey by default;
        // MySQL has the dedicated syntax.
        let sql =
            switch dialect {
            case .mysql: "ALTER TABLE \(qualified(table)) DROP PRIMARY KEY"
            case .postgresql: "ALTER TABLE \(qualified(table)) DROP CONSTRAINT \(quote("\(table.name)_pkey"))"
            // Unreachable: SQLite rebuilds the table. Kept honest rather than silent.
            case .sqlite: "-- SQLite cannot drop a primary key in place; the table is rebuilt"
            }
        return GeneratedDDL(kind: .dropPrimaryKey, sql: sql, table: table, isDestructive: true)
    }

    // MARK: - Indexes

    private func droppedIndexes(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        let editedByID = Dictionary(uniqueKeysWithValues: edited.indexes.map { ($0.id, $0) })
        return current.indexes.compactMap { index in
            guard let after = editedByID[index.id] else {
                return dropIndex(named: index.name, on: current.ref, destructive: true)
            }
            // A changed definition means a rebuild; a changed name alone does not, except
            // on SQLite, which cannot rename an index.
            guard !index.matchesDefinition(of: after) || (dialect == .sqlite && index.name != after.name) else {
                return nil
            }
            return dropIndex(named: index.name, on: current.ref, destructive: false)
        }
    }

    private func addedIndexes(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.indexes.map { ($0.id, $0) })
        return edited.indexes.compactMap { index in
            guard let before = currentByID[index.id] else {
                return GeneratedDDL(
                    kind: .createIndex, sql: createIndexSQL(index, on: edited.ref), table: edited.ref
                )
            }
            if !before.matchesDefinition(of: index) {
                return GeneratedDDL(
                    kind: .createIndex, sql: createIndexSQL(index, on: edited.ref), table: edited.ref
                )
            }
            if before.name != index.name {
                if dialect == .sqlite {
                    return GeneratedDDL(
                        kind: .createIndex, sql: createIndexSQL(index, on: edited.ref), table: edited.ref
                    )
                }
                return renameIndex(from: before.name, to: index.name, on: edited.ref)
            }
            return nil
        }
    }

    public func createIndexSQL(_ index: IndexDefinition, on table: TableRef) -> String {
        let columns = index.columns.map { indexColumnClause($0) }.joined(separator: ", ")
        switch dialect {
        case .sqlite:
            // An index is a schema object: its name takes the schema, the table does not.
            var sql = "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(sqliteSchemaObject(index.name, in: table))"
            sql += " ON \(quote(table.name)) (\(columns))"
            if let predicate = index.predicate { sql += " WHERE \(predicate)" }
            return sql

        case .postgresql:
            var sql = "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(quote(index.name))"
            sql += " ON \(qualified(table))"
            if let method = index.method { sql += " USING \(safeName(method))" }
            sql += " (\(columns))"
            if let predicate = index.predicate { sql += " WHERE \(predicate)" }
            return sql

        case .mysql:
            // MySQL spells FULLTEXT and SPATIAL as index kinds, not as USING methods.
            let upper = index.method?.uppercased()
            let kind =
                switch upper {
                case "FULLTEXT": "FULLTEXT "
                case "SPATIAL": "SPATIAL "
                default: index.isUnique ? "UNIQUE " : ""
                }
            var sql = "CREATE \(kind)INDEX \(quote(index.name)) ON \(qualified(table)) (\(columns))"
            if let method = upper, method == "BTREE" || method == "HASH" {
                sql += " USING \(method)"
            }
            return sql
        }
    }

    private func indexColumnClause(_ column: IndexColumn) -> String {
        var clause = quote(column.name)
        if let prefix = column.prefixLength, dialect == .mysql { clause += "(\(prefix))" }
        if let operatorClass = column.operatorClass, dialect == .postgresql {
            clause += " \(safeName(operatorClass))"
        }
        if column.isDescending { clause += " DESC" }
        return clause
    }

    private func dropIndex(named name: String, on table: TableRef, destructive: Bool) -> GeneratedDDL {
        let sql =
            switch dialect {
            // A PostgreSQL index lives in the schema, not on the table.
            case .postgresql: "DROP INDEX \(Identifier.qualify([table.schema, name], dialect: dialect))"
            case .mysql: "DROP INDEX \(quote(name)) ON \(qualified(table))"
            case .sqlite: "DROP INDEX \(sqliteSchemaObject(name, in: table))"
            }
        return GeneratedDDL(kind: .dropIndex, sql: sql, table: table, isDestructive: destructive)
    }

    private func renameIndex(from old: String, to new: String, on table: TableRef) -> GeneratedDDL {
        let sql =
            switch dialect {
            case .postgresql:
                "ALTER INDEX \(Identifier.qualify([table.schema, old], dialect: dialect)) RENAME TO \(quote(new))"
            case .mysql:
                "ALTER TABLE \(qualified(table)) RENAME INDEX \(quote(old)) TO \(quote(new))"
            // Unreachable: SQLite has no index rename, so the caller drops and recreates.
            case .sqlite:
                "-- SQLite cannot rename an index; it is dropped and created again"
            }
        return GeneratedDDL(kind: .renameIndex, sql: sql, table: table)
    }

    // MARK: - Foreign keys and checks

    private func droppedForeignKeys(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        let editedByID = Dictionary(uniqueKeysWithValues: edited.foreignKeys.map { ($0.id, $0) })
        return current.foreignKeys.compactMap { key in
            let after = editedByID[key.id]
            guard after == nil || !key.matchesDefinition(of: after!) || key.name != after!.name else {
                return nil
            }
            return GeneratedDDL(
                kind: .dropForeignKey,
                sql: dropConstraintSQL(named: key.name, on: current.ref, isForeignKey: true),
                table: current.ref,
                isDestructive: after == nil
            )
        }
    }

    private func addedForeignKeys(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.foreignKeys.map { ($0.id, $0) })
        return edited.foreignKeys.compactMap { key in
            if let before = currentByID[key.id], before.matchesDefinition(of: key), before.name == key.name {
                return nil
            }
            return GeneratedDDL(
                kind: .addForeignKey,
                sql: "ALTER TABLE \(qualified(edited.ref)) ADD CONSTRAINT \(quote(key.name)) \(foreignKeyClause(key))",
                table: edited.ref
            )
        }
    }

    private func foreignKeyClause(_ key: ForeignKeyDefinition) -> String {
        var clause = "FOREIGN KEY (\(columnList(key.columns)))"
        clause += " REFERENCES \(qualified(key.referencedTable)) (\(columnList(key.referencedColumns)))"
        clause += " ON UPDATE \(key.onUpdate.rawValue)"
        clause += " ON DELETE \(key.onDelete.rawValue)"
        if key.isDeferrable, dialect != .mysql {
            clause += key.isInitiallyDeferred ? " DEFERRABLE INITIALLY DEFERRED" : " DEFERRABLE"
        }
        return clause
    }

    private func droppedChecks(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        let editedByID = Dictionary(uniqueKeysWithValues: edited.checks.map { ($0.id, $0) })
        return current.checks.compactMap { check in
            let after = editedByID[check.id]
            guard after == nil || after!.expression != check.expression || after!.name != check.name else {
                return nil
            }
            return GeneratedDDL(
                kind: .dropCheck,
                sql: dropConstraintSQL(named: check.name, on: current.ref, isForeignKey: false),
                table: current.ref,
                isDestructive: after == nil
            )
        }
    }

    private func addedChecks(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        let currentByID = Dictionary(uniqueKeysWithValues: current.checks.map { ($0.id, $0) })
        return edited.checks.compactMap { check in
            if let before = currentByID[check.id],
                before.expression == check.expression, before.name == check.name
            {
                return nil
            }
            return GeneratedDDL(
                kind: .addCheck,
                sql:
                    "ALTER TABLE \(qualified(edited.ref)) ADD CONSTRAINT \(quote(check.name)) CHECK (\(check.expression))",
                table: edited.ref
            )
        }
    }

    /// MySQL drops a foreign key with its own syntax and everything else as a constraint.
    private func dropConstraintSQL(named name: String, on table: TableRef, isForeignKey: Bool) -> String {
        let keyword = (dialect == .mysql && isForeignKey) ? "DROP FOREIGN KEY" : "DROP CONSTRAINT"
        return "ALTER TABLE \(qualified(table)) \(keyword) \(quote(name))"
    }

    // MARK: - Triggers

    private func droppedTriggers(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        let kept = Set(
            edited.triggers.filter { trigger in
                current.triggers.contains { $0 == trigger }
            }.map(\.name))
        return current.triggers.filter { !kept.contains($0.name) }.map { trigger in
            let sql =
                switch dialect {
                case .postgresql: "DROP TRIGGER \(quote(trigger.name)) ON \(qualified(current.ref))"
                case .mysql:
                    "DROP TRIGGER \(Identifier.qualify([current.ref.database, trigger.name], dialect: dialect))"
                case .sqlite:
                    "DROP TRIGGER \(sqliteSchemaObject(trigger.name, in: current.ref))"
                }
            return GeneratedDDL(kind: .dropTrigger, sql: sql, table: current.ref, isDestructive: true)
        }
    }

    private func addedTriggers(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        edited.triggers.filter { trigger in
            !current.triggers.contains { $0 == trigger }
        }.map {
            GeneratedDDL(kind: .createTrigger, sql: createTriggerSQL($0, on: edited.ref), table: edited.ref)
        }
    }

    public func createTriggerSQL(_ trigger: TriggerInfo, on table: TableRef) -> String {
        let events = trigger.events.map(\.rawValue).joined(separator: " OR ")
        let name = dialect == .sqlite ? sqliteSchemaObject(trigger.name, in: table) : quote(trigger.name)
        var sql = "CREATE TRIGGER \(name) \(trigger.timing.rawValue) "
        // MySQL and SQLite triggers fire on one event each.
        sql +=
            dialect == .postgresql
            ? events
            : "\(trigger.events.first?.rawValue ?? "INSERT")"
        sql += " ON \(dialect == .sqlite ? quote(table.name) : qualified(table))"
        switch dialect {
        case .sqlite:
            sql += " FOR EACH ROW"
            if let condition = trigger.condition { sql += " WHEN (\(condition))" }
            sql += "\n\(trigger.body ?? "BEGIN SELECT 1; END")"
        case .postgresql:
            sql += " FOR EACH \(trigger.isRowLevel ? "ROW" : "STATEMENT")"
            if let condition = trigger.condition { sql += " WHEN (\(condition))" }
            sql += " EXECUTE FUNCTION \(trigger.functionCall ?? "")"
        case .mysql:
            sql += " FOR EACH ROW"
            if let ordering = trigger.orderingHint { sql += " \(ordering)" }
            sql += "\n\(trigger.body ?? "BEGIN END")"
        }
        return sql
    }

    // MARK: - Column order

    /// Moves columns that changed place, which only MySQL can do.
    ///
    /// PostgreSQL has no syntax for it: a column's position is its `attnum` and the server
    /// offers no way to change it. The designer does not offer the control there, so this
    /// returns nothing rather than emitting something that cannot work.
    private func columnOrderStatements(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        guard dialect == .mysql else { return [] }
        let before = current.columns.map(\.id)
        let after = edited.columns.map(\.id)
        // Only the columns present in both, in each order: an added or dropped column
        // changes the sequence without anything having moved.
        let survivingBefore = before.filter { after.contains($0) }
        let survivingAfter = after.filter { before.contains($0) }
        guard survivingBefore != survivingAfter else { return [] }

        var statements: [GeneratedDDL] = []
        for (index, column) in edited.columns.enumerated() {
            // Every column is restated in its new place, because MySQL positions a column
            // relative to another and a partial reorder leaves the rest where they were.
            guard current.columns.contains(where: { $0.id == column.id }) else { continue }
            let place =
                index == 0
                ? "FIRST"
                : "AFTER \(quote(edited.columns[index - 1].name))"
            statements.append(
                GeneratedDDL(
                    kind: .alterColumn,
                    sql: "ALTER TABLE \(qualified(edited.ref)) MODIFY COLUMN \(columnClause(column)) \(place)",
                    table: edited.ref
                ))
        }
        return statements
    }

    // MARK: - Partitions

    /// Adds and removes partitions. Changing the strategy or the key is not offered:
    /// both engines require the table to be rebuilt, which is a migration rather than an
    /// edit (SPEC §15b.1).
    private func partitionStatements(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        guard let editedPartitioning = edited.partitioning else { return [] }
        let currentPartitions = current.partitioning?.partitions ?? []
        let currentNames = Set(currentPartitions.map(\.name))
        let editedNames = Set(editedPartitioning.partitions.map(\.name))

        var statements: [GeneratedDDL] = []
        for partition in currentPartitions where !editedNames.contains(partition.name) {
            statements.append(dropPartition(partition, from: edited.ref))
        }
        for partition in editedPartitioning.partitions where !currentNames.contains(partition.name) {
            statements.append(addPartition(partition, to: edited.ref))
        }
        return statements
    }

    private func addPartition(_ partition: PartitionInfo, to table: TableRef) -> GeneratedDDL {
        let bound = partition.bound ?? "DEFAULT"
        let sql =
            switch dialect {
            case .postgresql:
                // A PostgreSQL partition is a table of its own, created as part of the parent.
                "CREATE TABLE \(Identifier.qualify([table.schema, partition.name], dialect: dialect)) "
                    + "PARTITION OF \(qualified(table)) \(bound)"
            case .mysql:
                "ALTER TABLE \(qualified(table)) ADD PARTITION "
                    + "(PARTITION \(quote(partition.name)) \(bound))"
            case .sqlite:
                "-- SQLite has no table partitioning"
            }
        return GeneratedDDL(kind: .partition, sql: sql, table: table)
    }

    /// PostgreSQL detaches, which keeps the rows in a table of their own. MySQL drops,
    /// which discards them, so only one of the two is destructive.
    private func dropPartition(_ partition: PartitionInfo, from table: TableRef) -> GeneratedDDL {
        switch dialect {
        case .postgresql:
            GeneratedDDL(
                kind: .partition,
                sql: "ALTER TABLE \(qualified(table)) DETACH PARTITION "
                    + "\(Identifier.qualify([table.schema, partition.name], dialect: dialect))",
                table: table
            )
        case .mysql:
            GeneratedDDL(
                kind: .partition,
                sql: "ALTER TABLE \(qualified(table)) DROP PARTITION \(quote(partition.name))",
                table: table,
                isDestructive: true
            )
        case .sqlite:
            GeneratedDDL(kind: .partition, sql: "-- SQLite has no table partitioning", table: table)
        }
    }

    // MARK: - Comments and options

    /// PostgreSQL keeps comments in their own statements; MySQL carries them inline, so
    /// only the table comment needs one of its own.
    private func comments(
        for edited: TableDefinition, against current: TableDefinition?
    ) -> [GeneratedDDL] {
        var statements: [GeneratedDDL] = []
        let table = edited.ref
        // SQLite keeps no comments on anything.
        guard dialect != .sqlite else { return statements }

        if edited.comment != current?.comment, let comment = edited.comment ?? current?.comment {
            let text = edited.comment.map { quoteText($0) } ?? "NULL"
            let sql =
                switch dialect {
                case .postgresql: "COMMENT ON TABLE \(qualified(table)) IS \(text)"
                case .mysql: "ALTER TABLE \(qualified(table)) COMMENT = \(quoteText(edited.comment ?? ""))"
                case .sqlite: ""
                }
            _ = comment
            statements.append(GeneratedDDL(kind: .comment, sql: sql, table: table))
        }

        guard dialect == .postgresql else { return statements }
        let currentByID =
            current.map {
                Dictionary(uniqueKeysWithValues: $0.columns.map { ($0.id, $0) })
            } ?? [:]
        for column in edited.columns where column.comment != currentByID[column.id]?.comment {
            guard column.comment != nil || currentByID[column.id]?.comment != nil else { continue }
            let text = column.comment.map { quoteText($0) } ?? "NULL"
            statements.append(
                GeneratedDDL(
                    kind: .comment,
                    sql: "COMMENT ON COLUMN \(qualified(table)).\(quote(column.name)) IS \(text)",
                    table: table
                ))
        }
        return statements
    }

    private func tableOptionStatements(
        _ current: TableDefinition, _ edited: TableDefinition
    ) -> [GeneratedDDL] {
        guard dialect == .mysql else { return [] }
        var statements: [GeneratedDDL] = []
        if current.options.engine != edited.options.engine, let engine = edited.options.engine {
            statements.append(
                GeneratedDDL(
                    kind: .tableOption,
                    sql: "ALTER TABLE \(qualified(edited.ref)) ENGINE = \(safeName(engine))",
                    table: edited.ref
                ))
        }
        if current.options.collation != edited.options.collation
            || current.options.characterSet != edited.options.characterSet
        {
            var sql = "ALTER TABLE \(qualified(edited.ref))"
            if let set = edited.options.characterSet { sql += " CONVERT TO CHARACTER SET \(safeName(set))" }
            if let collation = edited.options.collation { sql += " COLLATE \(safeName(collation))" }
            statements.append(GeneratedDDL(kind: .tableOption, sql: sql, table: edited.ref))
        }
        return statements
    }

    private func tableSuffix(_ definition: TableDefinition) -> String? {
        switch dialect {
        case .postgresql:
            definition.options.tablespace.map { "TABLESPACE \(quote($0))" }
        case .mysql:
            mysqlTableSuffix(definition)
        case .sqlite:
            nil
        }
    }

    private func mysqlTableSuffix(_ definition: TableDefinition) -> String? {
        var parts: [String] = []
        if let engine = definition.options.engine { parts.append("ENGINE = \(safeName(engine))") }
        if let set = definition.options.characterSet { parts.append("DEFAULT CHARSET = \(safeName(set))") }
        if let collation = definition.options.collation { parts.append("COLLATE = \(safeName(collation))") }
        if let comment = definition.comment { parts.append("COMMENT = \(quoteText(comment))") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func partitionClause(_ partitioning: PartitioningInfo) -> String {
        let head = "PARTITION BY \(partitioning.strategy.rawValue) (\(partitioning.key))"
        switch dialect {
        case .sqlite:
            return ""
        case .postgresql:
            // A PostgreSQL partition is a table of its own, created separately.
            return " \(head)"
        case .mysql:
            // MySQL will not accept a RANGE or LIST table whose partitions are not declared
            // here: "For RANGE partitions each partition must be defined".
            if let count = partitioning.partitionCount {
                return "\n\(head) PARTITIONS \(count)"
            }
            guard !partitioning.partitions.isEmpty else { return "\n\(head)" }
            let list = partitioning.partitions
                .map { "    PARTITION \(quote($0.name)) \($0.bound ?? "")" }
                .joined(separator: ",\n")
            return "\n\(head) (\n\(list)\n)"
        }
    }

    // MARK: - Table

    private func renameTable(from old: TableRef, to new: TableRef) -> GeneratedDDL {
        let sql =
            switch dialect {
            case .postgresql, .sqlite: "ALTER TABLE \(qualified(old)) RENAME TO \(quote(new.name))"
            case .mysql: "RENAME TABLE \(qualified(old)) TO \(qualified(new))"
            }
        return GeneratedDDL(kind: .renameTable, sql: sql, table: new)
    }

    /// `DROP TABLE`, which the designer only ever produces from an explicit request.
    public func drop(_ table: TableRef) -> GeneratedDDL {
        GeneratedDDL(
            kind: .dropTable,
            sql: "DROP TABLE \(qualified(table))",
            table: table,
            isDestructive: true
        )
    }

    // MARK: - SQLite

    /// The one column SQLite declares as `INTEGER PRIMARY KEY AUTOINCREMENT`, when the
    /// table's key is a single auto-incrementing integer column; nil otherwise.
    private func sqliteInlinePrimaryKey(_ definition: TableDefinition) -> String? {
        guard dialect == .sqlite, definition.primaryKey.count == 1,
            let column = definition.column(named: definition.primaryKey[0]),
            column.isAutoIncrement,
            column.type.trimmingCharacters(in: .whitespaces).uppercased() == "INTEGER"
        else { return nil }
        return column.name
    }

    /// An index or trigger name, qualified with the table's schema when that is not `main`.
    private func sqliteSchemaObject(_ name: String, in table: TableRef) -> String {
        table.schema == SchemaRef.sqliteMainSchema || table.schema.isEmpty
            ? quote(name)
            : Identifier.qualify([table.schema, name], dialect: dialect)
    }

    /// SQLite's `ALTER TABLE` renames tables and columns, adds columns and drops
    /// unconstrained ones, and nothing else. Every other change goes through the procedure
    /// SQLite's own documentation prescribes: create the new table, copy the rows, drop
    /// the old table, rename the new one into place, and put the indexes and triggers
    /// back. The executor runs it in one transaction, so a failure part-way leaves the
    /// file as it was.
    private func sqliteAlter(from current: TableDefinition, to edited: TableDefinition) -> [GeneratedDDL] {
        if sqliteNeedsRebuild(from: current, to: edited) {
            return sqliteRebuild(from: current, to: edited)
        }

        var statements: [GeneratedDDL] = []
        let table = current.ref
        statements.append(contentsOf: droppedTriggers(current, edited))
        statements.append(contentsOf: droppedIndexes(current, edited))

        let currentByID = Dictionary(uniqueKeysWithValues: current.columns.map { ($0.id, $0) })
        let editedIDs = Set(edited.columns.map(\.id))
        for column in current.columns where !editedIDs.contains(column.id) {
            statements.append(
                GeneratedDDL(
                    kind: .dropColumn,
                    sql: "ALTER TABLE \(qualified(table)) DROP COLUMN \(quote(column.name))",
                    table: table,
                    isDestructive: true
                ))
        }
        for column in edited.columns {
            guard let before = currentByID[column.id] else {
                statements.append(
                    GeneratedDDL(
                        kind: .addColumn,
                        sql: "ALTER TABLE \(qualified(table)) ADD COLUMN \(columnClause(column, in: edited))",
                        table: table
                    ))
                continue
            }
            if before.name != column.name {
                statements.append(renameColumn(from: before.name, to: column.name, on: table))
            }
        }

        // Indexes and triggers are created against the table's final name.
        var renamed = edited
        renamed.ref = current.ref
        statements.append(contentsOf: addedIndexes(current, renamed))
        statements.append(contentsOf: addedTriggers(current, renamed))
        if current.ref.name != edited.ref.name {
            statements.append(renameTable(from: current.ref, to: edited.ref))
        }
        return statements
    }

    /// True when the edit asks for something SQLite's `ALTER TABLE` cannot express, so
    /// the table is rebuilt instead. Public so the designer can warn before it runs.
    public func sqliteNeedsRebuild(from current: TableDefinition, to edited: TableDefinition) -> Bool {
        if current.primaryKey != edited.primaryKey { return true }
        if current.checks != edited.checks { return true }
        if current.foreignKeys != edited.foreignKeys { return true }
        let currentByID = Dictionary(uniqueKeysWithValues: current.columns.map { ($0.id, $0) })
        let editedIDs = Set(edited.columns.map(\.id))

        // The surviving columns must keep their order: SQLite appends a new column at the
        // end and has no way to move one.
        let survivingBefore = current.columns.map(\.id).filter { editedIDs.contains($0) }
        let survivingAfter = edited.columns.map(\.id).filter { currentByID[$0] != nil }
        if survivingBefore != survivingAfter { return true }

        let constrained = Set(
            current.primaryKey + current.indexes.flatMap { $0.columns.map(\.name) }
                + current.foreignKeys.flatMap(\.columns))
        for column in current.columns where !editedIDs.contains(column.id) {
            // DROP COLUMN refuses a column that is indexed or part of a key.
            if constrained.contains(column.name) { return true }
        }
        for column in edited.columns {
            guard let before = currentByID[column.id] else {
                // ADD COLUMN takes no PRIMARY KEY, no UNIQUE, and NOT NULL only with a default.
                if edited.primaryKey.contains(column.name) { return true }
                if !column.isNullable, column.defaultExpression == nil, column.generatedExpression == nil {
                    return true
                }
                if column.generatedExpression != nil, column.isGeneratedStored { return true }
                continue
            }
            if !before.matchesDefinition(of: column) { return true }
        }
        // A new column that is the only one in a new index is fine; anything else about
        // indexes and triggers is expressible with CREATE and DROP.
        return false
    }

    /// The rebuild procedure from SQLite's `ALTER TABLE` documentation, as statements.
    private func sqliteRebuild(from current: TableDefinition, to edited: TableDefinition) -> [GeneratedDDL] {
        var statements: [GeneratedDDL] = []
        let scratchName = "\(edited.ref.name)__tinker_rebuild"
        var scratch = edited
        scratch.ref = TableRef(database: current.ref.database, schema: current.ref.schema, name: scratchName)

        // Other tables' foreign keys point at the old table by name. Deferring the checks
        // to the commit lets the drop and the rename happen in between; the rename in
        // SQLite 3.26+ then leaves every reference pointing at the rebuilt table.
        statements.append(
            GeneratedDDL(
                kind: .tableOption,
                sql: "-- SQLite cannot change a column in place; the table is rebuilt\nPRAGMA defer_foreign_keys = ON",
                table: edited.ref
            ))

        let body = sqliteCreateBody(scratch)
        statements.append(
            GeneratedDDL(
                kind: .createTable,
                sql: "CREATE TABLE \(qualified(scratch.ref)) (\n    \(body.joined(separator: ",\n    "))\n)",
                table: edited.ref
            ))

        let currentByID = Dictionary(uniqueKeysWithValues: current.columns.map { ($0.id, $0) })
        var targets: [String] = []
        var sources: [String] = []
        var narrowed = false
        for column in edited.columns where column.generatedExpression == nil {
            guard let before = currentByID[column.id] else { continue }
            targets.append(quote(column.name))
            sources.append(quote(before.name))
            if before.type != column.type { narrowed = true }
        }
        let droppedColumns = current.columns.contains { !edited.columns.map(\.id).contains($0.id) }
        if !targets.isEmpty {
            statements.append(
                GeneratedDDL(
                    kind: .alterColumn,
                    sql: "INSERT INTO \(qualified(scratch.ref)) (\(targets.joined(separator: ", ")))\n"
                        + "SELECT \(sources.joined(separator: ", ")) FROM \(qualified(current.ref))",
                    table: edited.ref,
                    isDestructive: narrowed || droppedColumns
                ))
        }
        statements.append(
            GeneratedDDL(kind: .alterColumn, sql: "DROP TABLE \(qualified(current.ref))", table: edited.ref))
        statements.append(
            GeneratedDDL(
                kind: .alterColumn,
                sql: "ALTER TABLE \(qualified(scratch.ref)) RENAME TO \(quote(edited.ref.name))",
                table: edited.ref
            ))
        statements.append(
            contentsOf: edited.indexes.map {
                GeneratedDDL(kind: .createIndex, sql: createIndexSQL($0, on: edited.ref), table: edited.ref)
            })
        statements.append(
            contentsOf: edited.triggers.map {
                GeneratedDDL(kind: .createTrigger, sql: createTriggerSQL($0, on: edited.ref), table: edited.ref)
            })
        return statements
    }

    /// The column and constraint lines of a SQLite `CREATE TABLE`.
    private func sqliteCreateBody(_ definition: TableDefinition) -> [String] {
        var body: [String] = definition.columns.map { columnClause($0, in: definition) }
        if !definition.primaryKey.isEmpty, sqliteInlinePrimaryKey(definition) == nil {
            body.append("PRIMARY KEY (\(columnList(definition.primaryKey)))")
        }
        for check in definition.checks {
            body.append("CONSTRAINT \(quote(check.name)) CHECK (\(check.expression))")
        }
        for key in definition.foreignKeys {
            body.append("CONSTRAINT \(quote(key.name)) \(foreignKeyClause(key))")
        }
        return body
    }

    // MARK: - Helpers

    private func quote(_ name: String) -> String { Identifier.quote(name, dialect: dialect) }

    /// A character set, collation, engine, index method or operator class as it goes into
    /// a statement. These are bare words on every server; a name that is anything more
    /// than letters, digits and underscores is quoted, so a value read from a hostile
    /// catalogue cannot close the clause and start another statement.
    private func safeName(_ name: String) -> String {
        let plain = name.unicodeScalars.allSatisfy { scalar in
            switch scalar {
            case "a" ... "z", "A" ... "Z", "0" ... "9", "_": true
            default: false
            }
        }
        return plain && !name.isEmpty ? name : quote(name)
    }

    /// A column type as it goes into a statement: read apart and written back through
    /// `ColumnTypeSpec`, which quotes enum members and drops anything a type cannot
    /// contain.
    private func typeText(_ type: String) -> String {
        ColumnTypeSpec.normalized(type, dialect: dialect)
    }
    private func quoteText(_ text: String) -> String {
        SQLLiteral.quoteString(text, dialect: dialect)
    }
    private func qualified(_ table: TableRef) -> String { Identifier.qualified(table, dialect: dialect) }
    private func columnList(_ names: [String]) -> String {
        names.map { quote($0) }.joined(separator: ", ")
    }
}
