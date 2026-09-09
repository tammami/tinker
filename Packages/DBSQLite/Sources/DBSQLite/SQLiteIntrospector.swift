import DBCore
import DBSQL
import Foundation
import Logging
import SQLite3

/// Reads a SQLite database's catalog: `sqlite_master`, the `PRAGMA` table functions, and
/// where SQLite keeps nothing — comments, users, routines — says so instead.
///
/// SQLite has one schema per file, `main`, so ``SchemaRef/sqlite`` is the pseudo-schema
/// every table lives in (SPEC §8 treats MySQL the same way).
public struct SQLiteIntrospector: SchemaIntrospector {
    /// Weak, because the connection owns this value and would otherwise never be freed.
    private weak var connection: SQLiteConnection?

    init(connection: SQLiteConnection) {
        self.connection = connection
    }

    private func query(_ sql: String, _ parameters: [DBValue] = []) async throws -> QueryResult {
        guard let connection else { throw DBError.notConnected }
        return try await connection.query(sql, parameters)
    }

    /// The name that goes into a `PRAGMA schema.function(…)` call.
    private func schemaPrefix(_ schema: String) -> String {
        Identifier.quote(schema.isEmpty ? SchemaRef.sqliteMainSchema : schema, dialect: .sqlite)
    }

    /// The database is the file; attached databases show up beside it.
    public func databases() async throws -> [DatabaseInfo] {
        let result = try await query("PRAGMA database_list")
        let encoding = try? await query("PRAGMA encoding").firstText
        return result.rows.compactMap { row in
            guard row.count >= 2, let name = row[1].text, name != "temp" else { return nil }
            return DatabaseInfo(
                name: name,
                isCurrent: name == SchemaRef.sqliteMainSchema,
                comment: row.count >= 3 ? row[2].text : nil,
                characterSet: encoding ?? nil,
                collation: "BINARY"
            )
        }
    }

    /// One pseudo-schema per database, carrying the database's own name (`main`).
    public func schemas(in database: String) async throws -> [SchemaInfo] {
        [SchemaInfo(ref: SchemaRef(database: database, schema: database), isSystem: false)]
    }

    public func tables(in schema: SchemaRef) async throws -> [TableInfo] {
        // A schema that is not attached holds nothing, which is what the structure
        // comparison asks when it points at a target that does not exist yet.
        let attached = try await databases().map(\.name)
        guard attached.contains(schema.schema.isEmpty ? SchemaRef.sqliteMainSchema : schema.schema) else { return [] }
        let master = "\(schemaPrefix(schema.schema)).sqlite_master"
        let result = try await query(
            """
            SELECT m.name, m.type
            FROM \(master) m
            WHERE m.type IN ('table', 'view') AND m.name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
            ORDER BY m.name
            """)
        let estimates = try await rowEstimates(in: schema)
        let sizes = try await pageSizes(in: schema)
        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            let kind: TableKind = (row[1].text ?? "table") == "view" ? .view : .table
            return TableInfo(
                ref: TableRef(schema: schema, name: name),
                kind: kind,
                sizeBytes: sizes[name],
                approximateRowCount: estimates[name]
            )
        }
    }

    /// `sqlite_stat1` holds row counts from the last `ANALYZE`, one row per index or table.
    /// Nothing else in SQLite estimates a table's size without scanning it.
    private func rowEstimates(in schema: SchemaRef) async throws -> [String: Int64] {
        let stat = "\(schemaPrefix(schema.schema)).sqlite_stat1"
        guard let result = try? await query("SELECT tbl, stat FROM \(stat)") else { return [:] }
        var estimates: [String: Int64] = [:]
        for row in result.rows {
            guard let table = row[0].text, let stat = row[1].text,
                let first = stat.split(separator: " ").first, let count = Int64(first)
            else { continue }
            estimates[table] = max(estimates[table] ?? 0, count)
        }
        return estimates
    }

    /// Bytes on disk per table from the `dbstat` virtual table, when this SQLite has it.
    private func pageSizes(in schema: SchemaRef) async throws -> [String: Int64] {
        guard
            let result = try? await query(
                "SELECT name, SUM(pgsize) FROM dbstat(\(SQLLiteral.quoteString(schema.schema, dialect: .sqlite))) GROUP BY name")
        else { return [:] }
        var sizes: [String: Int64] = [:]
        for row in result.rows {
            guard let name = row[0].text else { continue }
            sizes[name] = Self.integer(row[1])
        }
        return sizes
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        // `table_xinfo` lists hidden and generated columns too, which `table_info` hides.
        let result = try await query("SELECT * FROM \(schemaPrefix(table.schema)).pragma_table_xinfo(?)", [.string(table.name)])
        let names = result.columns.map(\.name)
        func field(_ row: [DBValue], _ name: String) -> DBValue {
            names.firstIndex(of: name).map { row[$0] } ?? .null
        }
        let primaryKey = result.rows.filter { (Self.integer(field($0, "pk")) ?? 0) > 0 }
        let singleIntegerKey =
            primaryKey.count == 1
            && (field(primaryKey[0], "type").text ?? "").trimmingCharacters(in: .whitespaces).uppercased() == "INTEGER"
        let ddl = try? await createStatement(of: table)
        let declaresAutoincrement = ddl?.uppercased().contains("AUTOINCREMENT") ?? false

        return result.rows.enumerated().compactMap { offset, row in
            guard let name = field(row, "name").text else { return nil }
            let type = field(row, "type").text ?? ""
            let hidden = Self.integer(field(row, "hidden")) ?? 0
            let isKey = (Self.integer(field(row, "pk")) ?? 0) > 0
            let declared = SQLiteValueCodec.DeclaredType(type)
            return ColumnInfo(
                ordinal: offset + 1,
                name: name,
                nativeType: type.isEmpty ? "ANY" : type,
                kind: declared.kind,
                isNullable: (Self.integer(field(row, "notnull")) ?? 0) == 0 && !(isKey && singleIntegerKey),
                defaultExpression: field(row, "dflt_value").text,
                isPrimaryKey: isKey,
                // Only a declared AUTOINCREMENT counts, as the DDL says. A plain INTEGER
                // PRIMARY KEY is the rowid and assigns itself too, but reporting it as
                // auto-increment would make every comparison against another engine differ.
                isAutoIncrement: isKey && singleIntegerKey && declaresAutoincrement,
                isGenerated: hidden == 2 || hidden == 3,
                collation: nil
            )
        }
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let prefix = schemaPrefix(table.schema)
        let list = try await query("SELECT name, \"unique\", origin, partial FROM \(prefix).pragma_index_list(?)", [.string(table.name)])
        let columns = try await columns(of: table)
        let nullable = Set(columns.filter(\.isNullable).map(\.name))
        var indexes: [IndexInfo] = []
        for row in list.rows {
            guard let name = row[0].text else { continue }
            let info = try await query(
                "SELECT name FROM \(prefix).pragma_index_info(?) ORDER BY seqno", [.string(name)])
            let indexColumns = info.rows.compactMap { $0[0].text }
            let origin = row[2].text ?? "c"
            let partial = (Self.integer(row[3]) ?? 0) != 0
            let predicate = partial ? try await indexPredicate(named: name, in: table.schema) : nil
            indexes.append(
                IndexInfo(
                    name: name,
                    columns: indexColumns,
                    isUnique: (Self.integer(row[1]) ?? 0) != 0,
                    isPrimary: origin == "pk",
                    method: "btree",
                    predicate: predicate,
                    isNullableFree: !indexColumns.contains { nullable.contains($0) }
                ))
        }
        return indexes
    }

    /// The `WHERE` clause of a partial index, read from its own `CREATE INDEX`.
    private func indexPredicate(named name: String, in schema: String) async throws -> String? {
        let result = try await query(
            "SELECT sql FROM \(schemaPrefix(schema)).sqlite_master WHERE type = 'index' AND name = ?", [.string(name)])
        guard let sql = result.firstText else { return nil }
        return SQLiteDDLReader.partialIndexPredicate(sql)
    }

    public func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] {
        let result = try await query(
            "SELECT id, seq, \"table\", \"from\", \"to\", on_update, on_delete FROM \(schemaPrefix(table.schema)).pragma_foreign_key_list(?) ORDER BY id, seq",
            [.string(table.name)])
        struct Partial {
            var columns: [String] = []
            var referencedColumns: [String] = []
            var referencedTable: TableRef
            var onUpdate: ForeignKeyAction
            var onDelete: ForeignKeyAction
        }
        var order: [Int64] = []
        var partials: [Int64: Partial] = [:]
        for row in result.rows {
            guard let id = Self.integer(row[0]), let referenced = row[2].text, let column = row[3].text else { continue }
            var partial =
                partials[id]
                ?? Partial(
                    referencedTable: TableRef(database: table.database, schema: table.schema, name: referenced),
                    onUpdate: ForeignKeyAction(rawValue: (row[5].text ?? "NO ACTION").uppercased()) ?? .noAction,
                    onDelete: ForeignKeyAction(rawValue: (row[6].text ?? "NO ACTION").uppercased()) ?? .noAction
                )
            if partials[id] == nil { order.append(id) }
            partial.columns.append(column)
            if let to = row[4].text { partial.referencedColumns.append(to) }
            partials[id] = partial
        }
        // A key that names no target columns points at the referenced table's primary key.
        var keys: [ForeignKeyInfo] = []
        let names = ddlForeignKeyNames(try? await createStatement(of: table))
        for (offset, id) in order.enumerated() {
            guard var partial = partials[id] else { continue }
            if partial.referencedColumns.isEmpty {
                partial.referencedColumns = try await primaryKey(of: partial.referencedTable) ?? []
            }
            keys.append(
                ForeignKeyInfo(
                    name: offset < names.count ? names[offset] : "fk_\(table.name)_\(id)",
                    columns: partial.columns,
                    referencedTable: partial.referencedTable,
                    referencedColumns: partial.referencedColumns,
                    onUpdate: partial.onUpdate,
                    onDelete: partial.onDelete
                ))
        }
        return keys
    }

    /// The `CONSTRAINT name FOREIGN KEY` names in declaration order; SQLite's pragma does
    /// not report them.
    private func ddlForeignKeyNames(_ ddl: String?) -> [String] {
        guard let ddl else { return [] }
        return SQLiteDDLReader.constraintNames(in: ddl, kind: "FOREIGN")
    }

    public func primaryKey(of table: TableRef) async throws -> [String]? {
        let result = try await query(
            "SELECT name FROM \(schemaPrefix(table.schema)).pragma_table_info(?) WHERE pk > 0 ORDER BY pk", [.string(table.name)])
        let columns = result.rows.compactMap { $0[0].text }
        return columns.isEmpty ? nil : columns
    }

    /// SQLite has no stored routines.
    public func routines(in schema: SchemaRef) async throws -> [RoutineInfo] { [] }

    /// The table's own `CREATE TABLE`, followed by its indexes, exactly as SQLite keeps them.
    public func tableDDL(_ table: TableRef) async throws -> String {
        let result = try await query(
            """
            SELECT sql, type FROM \(schemaPrefix(table.schema)).sqlite_master
            WHERE tbl_name = ? AND sql IS NOT NULL AND type IN ('table', 'view', 'index')
            ORDER BY CASE type WHEN 'table' THEN 0 WHEN 'view' THEN 0 ELSE 1 END, name
            """, [.string(table.name)])
        guard !result.rows.isEmpty else {
            throw DBError.server(ServerError(message: "no such table: \(table.name)"))
        }
        return result.rows.compactMap { $0[0].text }.map { $0 + ";" }.joined(separator: "\n")
    }

    private func createStatement(of table: TableRef) async throws -> String? {
        try await query(
            "SELECT sql FROM \(schemaPrefix(table.schema)).sqlite_master WHERE type IN ('table', 'view') AND name = ?",
            [.string(table.name)]
        ).firstText
    }

    /// From `sqlite_stat1` after an `ANALYZE`; nil until one has run.
    public func approximateRowCount(_ table: TableRef) async throws -> Int64? {
        try await rowEstimates(in: table.schemaRef)[table.name]
    }

    static func integer(_ value: DBValue) -> Int64? {
        switch value {
        case let .int(number): number
        case let .uint(number): Int64(exactly: number)
        case let .bool(flag): flag ? 1 : 0
        default: value.text.flatMap(Int64.init)
        }
    }

    // MARK: - Table designer reads

    /// SQLite keeps `CHECK` constraints only in the `CREATE TABLE` text.
    public func checkConstraints(of table: TableRef) async throws -> [CheckConstraintInfo] {
        guard let ddl = try await createStatement(of: table) else { return [] }
        return SQLiteDDLReader.checkConstraints(in: ddl)
    }

    public func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        let result = try await query(
            "SELECT name, sql FROM \(schemaPrefix(table.schema)).sqlite_master WHERE type = 'trigger' AND tbl_name = ? ORDER BY name",
            [.string(table.name)])
        return result.rows.compactMap { row in
            guard let name = row[0].text, let sql = row[1].text else { return nil }
            return SQLiteDDLReader.trigger(named: name, from: sql)
        }
    }

    /// SQLite has no partitioning.
    public func partitioning(of table: TableRef) async throws -> PartitioningInfo? { nil }

    public func collations(in database: String) async throws -> [CollationInfo] {
        let result = try await query("PRAGMA collation_list")
        return result.rows.compactMap { row in
            guard row.count >= 2, let name = row[1].text else { return nil }
            return CollationInfo(name: name, isDefault: name == "BINARY")
        }.sorted { $0.name < $1.name }
    }
}

// MARK: - Server reads

extension SQLiteIntrospector: ServerIntrospector {
    /// A file has one session: this one.
    public func activity() async throws -> [ServerSessionInfo] {
        guard let connection else { throw DBError.notConnected }
        return [
            ServerSessionInfo(
                id: connection.backendID,
                user: NSUserName(),
                database: connection.path,
                clientAddress: "local file",
                application: "Tinker",
                state: await connection.isInTransaction ? "in transaction" : "idle",
                isCurrent: true
            )
        ]
    }

    public func terminateSession(id: String) async throws {
        throw DBError.protocolError("SQLite has no server sessions to terminate; close the connection instead")
    }

    public func users() async throws -> [ServerUserInfo] {
        throw DBError.protocolError("SQLite has no user accounts; access to a database is access to its file")
    }

    /// The pragmas that describe how the file is set up, plus the library's version and
    /// compile options, since there are no server variables.
    public func variables() async throws -> [ServerVariableInfo] {
        var variables = [ServerVariableInfo(name: "sqlite_version", value: String(cString: sqlite3_libversion()), category: "Library")]
        let pragmas: [(String, String)] = [
            ("application_id", "File"), ("auto_vacuum", "Storage"), ("automatic_index", "Planner"),
            ("busy_timeout", "Locking"), ("cache_size", "Memory"), ("cache_spill", "Memory"),
            ("case_sensitive_like", "Text"), ("cell_size_check", "Integrity"), ("data_version", "File"),
            ("defer_foreign_keys", "Constraints"), ("encoding", "Text"), ("foreign_keys", "Constraints"),
            ("freelist_count", "Storage"), ("journal_mode", "Journal"), ("journal_size_limit", "Journal"),
            ("locking_mode", "Locking"), ("max_page_count", "Storage"), ("mmap_size", "Memory"),
            ("page_count", "Storage"), ("page_size", "Storage"), ("query_only", "Session"),
            ("read_uncommitted", "Session"), ("recursive_triggers", "Triggers"), ("reverse_unordered_selects", "Planner"),
            ("secure_delete", "Storage"), ("synchronous", "Journal"), ("temp_store", "Storage"),
            ("threads", "Planner"), ("trusted_schema", "Security"), ("user_version", "File"),
            ("wal_autocheckpoint", "Journal"),
        ]
        for (name, category) in pragmas {
            guard let value = try? await query("PRAGMA \(name)").firstText else { continue }
            variables.append(ServerVariableInfo(name: name, value: value, category: category))
        }
        if let options = try? await query("PRAGMA compile_options") {
            for row in options.rows {
                guard let option = row.first?.text else { continue }
                let parts = option.split(separator: "=", maxSplits: 1)
                variables.append(
                    ServerVariableInfo(
                        name: String(parts[0]), value: parts.count > 1 ? String(parts[1]) : "on", category: "Compile option"))
            }
        }
        return variables
    }

    public func viewDefinition(_ table: TableRef) async throws -> String {
        let result = try await query(
            "SELECT sql FROM \(schemaPrefix(table.schema)).sqlite_master WHERE type = 'view' AND name = ?",
            [.string(table.name)])
        guard let sql = result.firstText else {
            throw DBError.server(ServerError(message: "no such view: \(table.name)"))
        }
        return sql + ";\n"
    }

    public func routineDefinition(
        in schema: SchemaRef, name: String, signature: String, kind: RoutineKind
    ) async throws -> String {
        throw DBError.protocolError("SQLite has no stored routines")
    }

    public func grants(for user: ServerUserInfo) async throws -> [String] {
        throw DBError.protocolError("SQLite has no user accounts or grants")
    }
}

/// Reads what SQLite keeps only as DDL text: check constraints, constraint names, the
/// predicate of a partial index, and a trigger's timing and event.
enum SQLiteDDLReader {
    /// `CHECK (…)` clauses, named after the `CONSTRAINT name` before them or by position.
    static func checkConstraints(in ddl: String) -> [CheckConstraintInfo] {
        let tokens = SQLTokenizer.tokenize(ddl, dialect: .sqlite).filter { $0.kind != .whitespace && $0.kind != .comment }
        var checks: [CheckConstraintInfo] = []
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            guard token.kind == .keyword || token.kind == .identifier, token.text.uppercased() == "CHECK",
                index + 1 < tokens.count, tokens[index + 1].text == "("
            else {
                index += 1
                continue
            }
            var name: String?
            if index >= 2, tokens[index - 2].text.uppercased() == "CONSTRAINT" {
                name = Identifier.unquote(tokens[index - 1].text, dialect: .sqlite)
            }
            var depth = 0
            var cursor = index + 1
            var start: Int?
            var end: Int?
            while cursor < tokens.count {
                if tokens[cursor].text == "(" {
                    depth += 1
                    if depth == 1 { start = tokens[cursor].utf16Range.upperBound }
                } else if tokens[cursor].text == ")" {
                    depth -= 1
                    if depth == 0 {
                        end = tokens[cursor].utf16Range.lowerBound
                        break
                    }
                }
                cursor += 1
            }
            if let start, let end, start <= end {
                let utf16 = Array(ddl.utf16)
                let expression = String(decoding: utf16[start ..< end], as: UTF16.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                checks.append(CheckConstraintInfo(name: name ?? "check_\(checks.count + 1)", expression: expression))
            }
            index = cursor + 1
        }
        return checks
    }

    /// The names of `CONSTRAINT name <kind>` clauses, in order, where `kind` is the
    /// keyword that follows the name (`FOREIGN`, `CHECK`, `UNIQUE`, `PRIMARY`).
    static func constraintNames(in ddl: String, kind: String) -> [String] {
        let tokens = SQLTokenizer.tokenize(ddl, dialect: .sqlite).filter { $0.kind != .whitespace && $0.kind != .comment }
        var names: [String] = []
        for index in tokens.indices where index + 2 < tokens.count {
            guard tokens[index].text.uppercased() == "CONSTRAINT", tokens[index + 2].text.uppercased() == kind.uppercased()
            else { continue }
            names.append(Identifier.unquote(tokens[index + 1].text, dialect: .sqlite))
        }
        return names
    }

    /// The text after the top-level `WHERE` of a `CREATE INDEX`, or nil.
    static func partialIndexPredicate(_ ddl: String) -> String? {
        let tokens = SQLTokenizer.tokenize(ddl, dialect: .sqlite)
        var depth = 0
        for token in tokens {
            if token.text == "(" { depth += 1 } else if token.text == ")" { depth -= 1 }
            if depth == 0, token.kind == .keyword, token.text.uppercased() == "WHERE" {
                let utf16 = Array(ddl.utf16)
                return String(decoding: utf16[token.utf16Range.upperBound...], as: UTF16.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: ";"))
            }
        }
        return nil
    }

    /// `CREATE TRIGGER name [BEFORE|AFTER|INSTEAD OF] event ON table [FOR EACH ROW]
    /// [WHEN expr] BEGIN … END`, read into the app's model. The body — `BEGIN … END` —
    /// is kept verbatim.
    static func trigger(named name: String, from sql: String) -> TriggerInfo? {
        let tokens = SQLTokenizer.tokenize(sql, dialect: .sqlite).filter { $0.kind != .whitespace && $0.kind != .comment }
        let words = tokens.map { $0.text.uppercased() }
        var timing = TriggerTiming.after
        var event: TriggerEvent?
        var whenStart: Int?
        var beginIndex: Int?
        var index = 0
        while index < tokens.count {
            switch words[index] {
            case "BEFORE" where event == nil: timing = .before
            case "AFTER" where event == nil: timing = .after
            case "INSTEAD" where event == nil: timing = .insteadOf
            case "INSERT" where event == nil: event = .insert
            case "UPDATE" where event == nil: event = .update
            case "DELETE" where event == nil: event = .delete
            case "WHEN" where beginIndex == nil && event != nil: whenStart = tokens[index].utf16Range.upperBound
            case "BEGIN" where event != nil:
                beginIndex = index
            default: break
            }
            if beginIndex != nil { break }
            index += 1
        }
        guard let event, let beginIndex else { return nil }
        let utf16 = Array(sql.utf16)
        let bodyStart = tokens[beginIndex].utf16Range.lowerBound
        let body = String(decoding: utf16[bodyStart...], as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var condition: String?
        if let whenStart {
            condition = String(decoding: utf16[whenStart ..< bodyStart], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let text = condition, text.hasPrefix("("), text.hasSuffix(")") {
                condition = String(text.dropFirst().dropLast())
            }
        }
        return TriggerInfo(name: name, timing: timing, events: [event], isRowLevel: true, condition: condition, body: body)
    }
}
