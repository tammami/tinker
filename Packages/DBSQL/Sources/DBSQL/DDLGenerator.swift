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

        var body: [String] = definition.columns.map { columnClause($0) }
        if !definition.primaryKey.isEmpty {
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

        statements.append(contentsOf: definition.indexes.map {
            GeneratedDDL(kind: .createIndex, sql: createIndexSQL($0, on: definition.ref), table: definition.ref)
        })
        statements.append(contentsOf: comments(for: definition, against: nil))
        statements.append(contentsOf: definition.triggers.map {
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

        // 3. Put the constraints back, now that the columns are what they should be.
        if primaryKeyChanged(current, edited), !edited.primaryKey.isEmpty {
            statements.append(GeneratedDDL(
                kind: .addPrimaryKey,
                sql: "ALTER TABLE \(qualified(table)) ADD PRIMARY KEY (\(columnList(edited.primaryKey)))",
                table: table
            ))
        }
        statements.append(contentsOf: addedIndexes(current, edited))
        statements.append(contentsOf: addedChecks(current, edited))
        statements.append(contentsOf: addedForeignKeys(current, edited))
        statements.append(contentsOf: addedTriggers(current, edited))

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
            statements.append(GeneratedDDL(
                kind: .dropColumn,
                sql: "ALTER TABLE \(qualified(table)) DROP COLUMN \(quote(column.name))",
                table: table,
                isDestructive: true
            ))
        }

        for column in edited.columns {
            guard let before = currentByID[column.id] else {
                statements.append(GeneratedDDL(
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

    /// PostgreSQL changes one facet at a time; MySQL restates the whole column.
    private func alterColumn(
        from before: ColumnDefinition, to after: ColumnDefinition, on table: TableRef
    ) -> [GeneratedDDL] {
        let prefix = "ALTER TABLE \(qualified(table))"
        switch dialect {
        case .mysql:
            return [GeneratedDDL(
                kind: .alterColumn,
                sql: "\(prefix) MODIFY COLUMN \(columnClause(after))",
                table: table,
                isDestructive: before.type != after.type
            )]

        case .postgresql:
            var statements: [GeneratedDDL] = []
            let column = quote(after.name)
            if before.type != after.type {
                // USING lets the server cast what it can; without it a widening that needs
                // a cast fails outright.
                statements.append(GeneratedDDL(
                    kind: .alterColumn,
                    sql: "\(prefix) ALTER COLUMN \(column) TYPE \(after.type) USING \(column)::\(after.type)",
                    table: table,
                    isDestructive: true
                ))
            }
            if before.isNullable != after.isNullable {
                statements.append(GeneratedDDL(
                    kind: .alterColumn,
                    sql: "\(prefix) ALTER COLUMN \(column) \(after.isNullable ? "DROP" : "SET") NOT NULL",
                    table: table
                ))
            }
            if before.defaultExpression != after.defaultExpression {
                let action = after.defaultExpression.map { "SET DEFAULT \($0)" } ?? "DROP DEFAULT"
                statements.append(GeneratedDDL(
                    kind: .alterColumn,
                    sql: "\(prefix) ALTER COLUMN \(column) \(action)",
                    table: table
                ))
            }
            if before.isAutoIncrement != after.isAutoIncrement {
                let action = after.isAutoIncrement
                    ? "ADD GENERATED BY DEFAULT AS IDENTITY"
                    : "DROP IDENTITY IF EXISTS"
                statements.append(GeneratedDDL(
                    kind: .alterColumn,
                    sql: "\(prefix) ALTER COLUMN \(column) \(action)",
                    table: table
                ))
            }
            return statements
        }
    }

    /// The column as it appears inside `CREATE TABLE` or after `ADD COLUMN`.
    func columnClause(_ column: ColumnDefinition) -> String {
        var parts = [quote(column.name), column.type]
        if let characterSet = column.characterSet, dialect == .mysql {
            parts.append("CHARACTER SET \(characterSet)")
        }
        if let collation = column.collation {
            parts.append(dialect == .mysql ? "COLLATE \(collation)" : "COLLATE \(quote(collation))")
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
            parts.append(dialect == .mysql ? "AUTO_INCREMENT" : "GENERATED BY DEFAULT AS IDENTITY")
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
        let sql = switch dialect {
        case .mysql: "ALTER TABLE \(qualified(table)) DROP PRIMARY KEY"
        case .postgresql: "ALTER TABLE \(qualified(table)) DROP CONSTRAINT \(quote("\(table.name)_pkey"))"
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
            // A changed definition means a rebuild; a changed name alone does not.
            guard !index.matchesDefinition(of: after) else { return nil }
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
                return renameIndex(from: before.name, to: index.name, on: edited.ref)
            }
            return nil
        }
    }

    func createIndexSQL(_ index: IndexDefinition, on table: TableRef) -> String {
        let columns = index.columns.map { indexColumnClause($0) }.joined(separator: ", ")
        switch dialect {
        case .postgresql:
            var sql = "CREATE \(index.isUnique ? "UNIQUE " : "")INDEX \(quote(index.name))"
            sql += " ON \(qualified(table))"
            if let method = index.method { sql += " USING \(method)" }
            sql += " (\(columns))"
            if let predicate = index.predicate { sql += " WHERE \(predicate)" }
            return sql

        case .mysql:
            // MySQL spells FULLTEXT and SPATIAL as index kinds, not as USING methods.
            let upper = index.method?.uppercased()
            let kind = switch upper {
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
            clause += " \(operatorClass)"
        }
        if column.isDescending { clause += " DESC" }
        return clause
    }

    private func dropIndex(named name: String, on table: TableRef, destructive: Bool) -> GeneratedDDL {
        let sql = switch dialect {
        // A PostgreSQL index lives in the schema, not on the table.
        case .postgresql: "DROP INDEX \(Identifier.qualify([table.schema, name], dialect: dialect))"
        case .mysql: "DROP INDEX \(quote(name)) ON \(qualified(table))"
        }
        return GeneratedDDL(kind: .dropIndex, sql: sql, table: table, isDestructive: destructive)
    }

    private func renameIndex(from old: String, to new: String, on table: TableRef) -> GeneratedDDL {
        let sql = switch dialect {
        case .postgresql:
            "ALTER INDEX \(Identifier.qualify([table.schema, old], dialect: dialect)) RENAME TO \(quote(new))"
        case .mysql:
            "ALTER TABLE \(qualified(table)) RENAME INDEX \(quote(old)) TO \(quote(new))"
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
        if key.isDeferrable, dialect == .postgresql {
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
               before.expression == check.expression, before.name == check.name {
                return nil
            }
            return GeneratedDDL(
                kind: .addCheck,
                sql: "ALTER TABLE \(qualified(edited.ref)) ADD CONSTRAINT \(quote(check.name)) CHECK (\(check.expression))",
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
        let kept = Set(edited.triggers.filter { trigger in
            current.triggers.contains { $0 == trigger }
        }.map(\.name))
        return current.triggers.filter { !kept.contains($0.name) }.map { trigger in
            let sql = switch dialect {
            case .postgresql: "DROP TRIGGER \(quote(trigger.name)) ON \(qualified(current.ref))"
            case .mysql: "DROP TRIGGER \(Identifier.qualify([current.ref.database, trigger.name], dialect: dialect))"
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

    func createTriggerSQL(_ trigger: TriggerInfo, on table: TableRef) -> String {
        let events = trigger.events.map(\.rawValue).joined(separator: " OR ")
        var sql = "CREATE TRIGGER \(quote(trigger.name)) \(trigger.timing.rawValue) "
        sql += dialect == .mysql
            ? "\(trigger.events.first?.rawValue ?? "INSERT")"
            : events
        sql += " ON \(qualified(table))"
        switch dialect {
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

    // MARK: - Comments and options

    /// PostgreSQL keeps comments in their own statements; MySQL carries them inline, so
    /// only the table comment needs one of its own.
    private func comments(
        for edited: TableDefinition, against current: TableDefinition?
    ) -> [GeneratedDDL] {
        var statements: [GeneratedDDL] = []
        let table = edited.ref

        if edited.comment != current?.comment, let comment = edited.comment ?? current?.comment {
            let text = edited.comment.map { quoteText($0) } ?? "NULL"
            let sql = switch dialect {
            case .postgresql: "COMMENT ON TABLE \(qualified(table)) IS \(text)"
            case .mysql: "ALTER TABLE \(qualified(table)) COMMENT = \(quoteText(edited.comment ?? ""))"
            }
            _ = comment
            statements.append(GeneratedDDL(kind: .comment, sql: sql, table: table))
        }

        guard dialect == .postgresql else { return statements }
        let currentByID = current.map {
            Dictionary(uniqueKeysWithValues: $0.columns.map { ($0.id, $0) })
        } ?? [:]
        for column in edited.columns where column.comment != currentByID[column.id]?.comment {
            guard column.comment != nil || currentByID[column.id]?.comment != nil else { continue }
            let text = column.comment.map { quoteText($0) } ?? "NULL"
            statements.append(GeneratedDDL(
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
            statements.append(GeneratedDDL(
                kind: .tableOption,
                sql: "ALTER TABLE \(qualified(edited.ref)) ENGINE = \(engine)",
                table: edited.ref
            ))
        }
        if current.options.collation != edited.options.collation
            || current.options.characterSet != edited.options.characterSet {
            var sql = "ALTER TABLE \(qualified(edited.ref))"
            if let set = edited.options.characterSet { sql += " CONVERT TO CHARACTER SET \(set)" }
            if let collation = edited.options.collation { sql += " COLLATE \(collation)" }
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
        }
    }

    private func mysqlTableSuffix(_ definition: TableDefinition) -> String? {
        var parts: [String] = []
        if let engine = definition.options.engine { parts.append("ENGINE = \(engine)") }
        if let set = definition.options.characterSet { parts.append("DEFAULT CHARSET = \(set)") }
        if let collation = definition.options.collation { parts.append("COLLATE = \(collation)") }
        if let comment = definition.comment { parts.append("COMMENT = \(quoteText(comment))") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private func partitionClause(_ partitioning: PartitioningInfo) -> String {
        switch dialect {
        case .postgresql:
            " PARTITION BY \(partitioning.strategy.rawValue) (\(partitioning.key))"
        case .mysql:
            if let count = partitioning.partitionCount {
                "\nPARTITION BY \(partitioning.strategy.rawValue) (\(partitioning.key)) PARTITIONS \(count)"
            } else {
                "\nPARTITION BY \(partitioning.strategy.rawValue) (\(partitioning.key))"
            }
        }
    }

    // MARK: - Table

    private func renameTable(from old: TableRef, to new: TableRef) -> GeneratedDDL {
        let sql = switch dialect {
        case .postgresql: "ALTER TABLE \(qualified(old)) RENAME TO \(quote(new.name))"
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

    // MARK: - Helpers

    private func quote(_ name: String) -> String { Identifier.quote(name, dialect: dialect) }
    private func quoteText(_ text: String) -> String {
        SQLLiteral.quoteString(text, dialect: dialect)
    }
    private func qualified(_ table: TableRef) -> String { Identifier.qualified(table, dialect: dialect) }
    private func columnList(_ names: [String]) -> String {
        names.map { quote($0) }.joined(separator: ", ")
    }
}
