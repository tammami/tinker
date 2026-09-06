import DBCore
import DBSQL
import Foundation
import Logging
import MySQLNIO

/// Reads MySQL's catalogs.
///
/// MySQL has no schema layer, so a schema *is* a database and `SchemaRef` carries the same
/// name twice (SPEC §8). Queries branch on flavour and version where MariaDB and MySQL 8
/// disagree.
public struct MySQLIntrospector: SchemaIntrospector {
    let connection: MySQLConnection
    let logger: Logger
    let decoder: MySQLValueDecoder
    let version: ServerVersion
    let currentDatabase: String

    init(
        connection: MySQLConnection,
        logger: Logger,
        decoder: MySQLValueDecoder,
        version: ServerVersion,
        currentDatabase: String
    ) {
        self.connection = connection
        self.logger = logger
        self.decoder = decoder
        self.version = version
        self.currentDatabase = currentDatabase
    }

    private func query(_ sql: String, _ parameters: [DBValue] = []) async throws -> QueryResult {
        do {
            return try await MySQLSQLConnection.rawQuery(
                sql, parameters: parameters, on: connection, logger: logger, decoder: decoder
            )
        } catch {
            throw MySQLErrorMapper.map(error, user: "")
        }
    }

    /// Databases the user can see, minus the server's own.
    public func databases() async throws -> [DatabaseInfo] {
        let result = try await query(
            """
            SELECT s.SCHEMA_NAME,
                   s.SCHEMA_NAME = DATABASE(),
                   s.DEFAULT_CHARACTER_SET_NAME,
                   s.DEFAULT_COLLATION_NAME
            FROM information_schema.SCHEMATA s
            ORDER BY s.SCHEMA_NAME
            """)
        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            return DatabaseInfo(
                name: name,
                isCurrent: Self.isTrue(row[1]),
                comment: nil,
                characterSet: row[2].text,
                collation: row[3].text
            )
        }
    }

    /// MySQL's single pseudo-schema per database (SPEC §8).
    public func schemas(in database: String) async throws -> [SchemaInfo] {
        [
            SchemaInfo(
                ref: SchemaRef.mysql(database),
                owner: nil,
                comment: nil,
                isSystem: Self.systemDatabases.contains(database.lowercased())
            )
        ]
    }

    static let systemDatabases: Set<String> = [
        "information_schema", "performance_schema", "mysql", "sys",
    ]

    public func tables(in schema: SchemaRef) async throws -> [TableInfo] {
        let result = try await query(
            """
            SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_COMMENT,
                   t.DATA_LENGTH + t.INDEX_LENGTH, t.TABLE_ROWS,
                   t.ENGINE, t.TABLE_COLLATION
            FROM information_schema.TABLES t
            WHERE t.TABLE_SCHEMA = ?
            ORDER BY t.TABLE_NAME
            """, [.string(schema.database)])
        return Self.tableInfos(result, schema: schema)
    }

    /// One row of `information_schema.TABLES`, so the designer's comment and engine cost
    /// one indexed lookup rather than the sizes of every table in the database.
    public func tableInfo(of table: TableRef) async throws -> TableInfo? {
        let result = try await query(
            """
            SELECT t.TABLE_NAME, t.TABLE_TYPE, t.TABLE_COMMENT,
                   t.DATA_LENGTH + t.INDEX_LENGTH, t.TABLE_ROWS,
                   t.ENGINE, t.TABLE_COLLATION
            FROM information_schema.TABLES t
            WHERE t.TABLE_SCHEMA = ? AND t.TABLE_NAME = ?
            """, [.string(table.schemaRef.database), .string(table.name)])
        return Self.tableInfos(result, schema: table.schemaRef).first
    }

    private static func tableInfos(_ result: QueryResult, schema: SchemaRef) -> [TableInfo] {
        result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            let kind: TableKind =
                switch (row[1].text ?? "BASE TABLE").uppercased() {
                case "VIEW": .view
                case "SYSTEM VIEW": .systemTable
                default: .table
                }
            let size = Self.integer(row[3])
            let rows = Self.integer(row[4])
            let comment = row[2].text
            return TableInfo(
                ref: TableRef(schema: schema, name: name),
                kind: kind,
                comment: (comment?.isEmpty ?? true) ? nil : comment,
                owner: nil,
                sizeBytes: size,
                approximateRowCount: rows,
                engine: row[5].text,
                collation: row[6].text
            )
        }
    }

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        // `GENERATION_EXPRESSION` arrived in MySQL 5.7 and MariaDB 10.2.
        let hasGenerated = version.flavor == .mariadb ? version.isAtLeast(10, 2) : version.isAtLeast(5, 7)
        let generatedColumn = hasGenerated ? "c.GENERATION_EXPRESSION" : "''"
        let result = try await query(
            """
            SELECT c.ORDINAL_POSITION, c.COLUMN_NAME, c.COLUMN_TYPE, c.DATA_TYPE,
                   c.IS_NULLABLE, c.COLUMN_DEFAULT, c.COLUMN_KEY, c.EXTRA,
                   \(generatedColumn), c.COLUMN_COMMENT,
                   c.CHARACTER_SET_NAME, c.COLLATION_NAME
            FROM information_schema.COLUMNS c
            WHERE c.TABLE_SCHEMA = ? AND c.TABLE_NAME = ?
            ORDER BY c.ORDINAL_POSITION
            """, [.string(table.database), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[1].text else { return nil }
            let ordinal = Self.integer(row[0]).map(Int.init) ?? 0
            let columnType = row[2].text ?? "unknown"
            let extra = (row[7].text ?? "").lowercased()
            let generated = row[8].text ?? ""
            let comment = row[9].text
            let enumLabels = Self.enumLabels(from: columnType, dataType: row[3].text ?? "")
            return ColumnInfo(
                ordinal: ordinal,
                name: name,
                nativeType: columnType,
                kind: Self.kind(dataType: row[3].text ?? "", columnType: columnType, decoder: decoder),
                isNullable: (row[4].text ?? "YES").uppercased() == "YES",
                defaultExpression: row[5].text,
                isPrimaryKey: (row[6].text ?? "").uppercased() == "PRI",
                isAutoIncrement: extra.contains("auto_increment"),
                isGenerated: !generated.isEmpty || extra.contains("generated"),
                comment: (comment?.isEmpty ?? true) ? nil : comment,
                characterSet: row[10].text,
                collation: row[11].text,
                enumLabels: enumLabels
            )
        }
    }

    /// The value kind a declared type produces, from `information_schema` rather than a
    /// result set, so the grid knows its editors before any row arrives.
    static func kind(dataType: String, columnType: String, decoder: MySQLValueDecoder) -> DBValueKind {
        let lowered = dataType.lowercased()
        let unsigned = columnType.lowercased().contains("unsigned")
        switch lowered {
        case "tinyint":
            return decoder.settings.tinyint1IsBool && columnType.lowercased().hasPrefix("tinyint(1)") && !unsigned
                ? .bool : .int
        case "smallint", "mediumint", "int", "integer", "year": return .int
        case "bigint": return unsigned ? .uint : .int
        case "float", "double", "real": return .double
        case "decimal", "numeric": return .decimal
        case "date": return .date
        case "time": return .time
        case "datetime", "timestamp": return .timestamp
        case "json": return .json
        case "binary", "varbinary", "blob", "tinyblob", "mediumblob", "longblob": return .bytes
        case "bit", "geometry", "point", "linestring", "polygon": return .raw
        default: return .string
        }
    }

    /// `enum('a','b')` and `set('a','b')` carry their labels in the declared type.
    static func enumLabels(from columnType: String, dataType: String) -> [String]? {
        let lowered = dataType.lowercased()
        guard lowered == "enum" || lowered == "set",
            let open = columnType.firstIndex(of: "("),
            let close = columnType.lastIndex(of: ")")
        else { return nil }
        let inner = columnType[columnType.index(after: open) ..< close]
        var labels: [String] = []
        var current = ""
        var inQuotes = false
        var index = inner.startIndex
        while index < inner.endIndex {
            let character = inner[index]
            if character == "'" {
                let next = inner.index(after: index)
                if inQuotes, next < inner.endIndex, inner[next] == "'" {
                    current.append("'")
                    index = inner.index(after: next)
                    continue
                }
                inQuotes.toggle()
                if !inQuotes { labels.append(current); current = "" }
            } else if inQuotes {
                current.append(character)
            }
            index = inner.index(after: index)
        }
        return labels.isEmpty ? nil : labels
    }

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let result = try await query(
            """
            SELECT s.INDEX_NAME,
                   MIN(s.NON_UNIQUE) = 0,
                   MIN(s.INDEX_TYPE),
                   GROUP_CONCAT(s.COLUMN_NAME ORDER BY s.SEQ_IN_INDEX SEPARATOR ','),
                   MAX(s.NULLABLE = 'YES') = 0
            FROM information_schema.STATISTICS s
            WHERE s.TABLE_SCHEMA = ? AND s.TABLE_NAME = ?
            GROUP BY s.INDEX_NAME
            ORDER BY s.INDEX_NAME = 'PRIMARY' DESC, s.INDEX_NAME
            """, [.string(table.database), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            let columns = (row[3].text ?? "").split(separator: ",").map(String.init)
            return IndexInfo(
                name: name,
                columns: columns,
                isUnique: Self.isTrue(row[1]),
                isPrimary: name == "PRIMARY",
                method: row[2].text,
                predicate: nil,
                isNullableFree: Self.isTrue(row[4])
            )
        }
    }

    public func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] {
        let result = try await query(
            """
            SELECT k.CONSTRAINT_NAME,
                   GROUP_CONCAT(k.COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ','),
                   MIN(k.REFERENCED_TABLE_SCHEMA),
                   MIN(k.REFERENCED_TABLE_NAME),
                   GROUP_CONCAT(k.REFERENCED_COLUMN_NAME ORDER BY k.ORDINAL_POSITION SEPARATOR ','),
                   MIN(r.UPDATE_RULE),
                   MIN(r.DELETE_RULE)
            FROM information_schema.KEY_COLUMN_USAGE k
            JOIN information_schema.REFERENTIAL_CONSTRAINTS r
              ON r.CONSTRAINT_SCHEMA = k.CONSTRAINT_SCHEMA
             AND r.CONSTRAINT_NAME = k.CONSTRAINT_NAME
            WHERE k.TABLE_SCHEMA = ? AND k.TABLE_NAME = ? AND k.REFERENCED_TABLE_NAME IS NOT NULL
            GROUP BY k.CONSTRAINT_NAME
            ORDER BY k.CONSTRAINT_NAME
            """, [.string(table.database), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[0].text, let referenced = row[3].text else { return nil }
            let schema = row[2].text ?? table.database
            return ForeignKeyInfo(
                name: name,
                columns: (row[1].text ?? "").split(separator: ",").map(String.init),
                referencedTable: TableRef(database: schema, schema: schema, name: referenced),
                referencedColumns: (row[4].text ?? "").split(separator: ",").map(String.init),
                onUpdate: ForeignKeyAction(rawValue: (row[5].text ?? "NO ACTION").uppercased()) ?? .noAction,
                onDelete: ForeignKeyAction(rawValue: (row[6].text ?? "NO ACTION").uppercased()) ?? .noAction
            )
        }
    }

    public func primaryKey(of table: TableRef) async throws -> [String]? {
        let result = try await query(
            """
            SELECT GROUP_CONCAT(s.COLUMN_NAME ORDER BY s.SEQ_IN_INDEX SEPARATOR ',')
            FROM information_schema.STATISTICS s
            WHERE s.TABLE_SCHEMA = ? AND s.TABLE_NAME = ? AND s.INDEX_NAME = 'PRIMARY'
            """, [.string(table.database), .string(table.name)])
        guard let joined = result.rows.first?.first?.text, !joined.isEmpty else { return nil }
        return joined.split(separator: ",").map(String.init)
    }

    public func routines(in schema: SchemaRef) async throws -> [RoutineInfo] {
        let result = try await query(
            """
            SELECT r.ROUTINE_NAME, r.ROUTINE_TYPE, r.DTD_IDENTIFIER,
                   r.EXTERNAL_LANGUAGE, r.ROUTINE_COMMENT
            FROM information_schema.ROUTINES r
            WHERE r.ROUTINE_SCHEMA = ?
            ORDER BY r.ROUTINE_NAME
            """, [.string(schema.database)])

        var routines: [RoutineInfo] = []
        for row in result.rows {
            guard let name = row[0].text else { continue }
            let kind: RoutineKind =
                (row[1].text ?? "FUNCTION").uppercased() == "PROCEDURE"
                ? .procedure : .function
            // Parameters live in a separate view; one query per routine is acceptable
            // because the sidebar reads this level only when it is expanded.
            let parameters = try await query(
                """
                SELECT GROUP_CONCAT(
                           CONCAT(COALESCE(p.PARAMETER_NAME, ''), ' ', p.DTD_IDENTIFIER)
                           ORDER BY p.ORDINAL_POSITION SEPARATOR ', '
                       )
                FROM information_schema.PARAMETERS p
                WHERE p.SPECIFIC_SCHEMA = ? AND p.SPECIFIC_NAME = ? AND p.ORDINAL_POSITION > 0
                """, [.string(schema.database), .string(name)])
            let comment = row[4].text
            routines.append(
                RoutineInfo(
                    name: name,
                    kind: kind,
                    signature: parameters.rows.first?.first?.text ?? "",
                    returnType: row[2].text,
                    language: row[3].text ?? "SQL",
                    comment: (comment?.isEmpty ?? true) ? nil : comment
                ))
        }
        return routines
    }

    /// MySQL answers this itself, so the DDL is the server's own rather than synthesized.
    public func tableDDL(_ table: TableRef) async throws -> String {
        let name = Identifier.qualified(table, dialect: .mysql)
        let result = try await query("SHOW CREATE TABLE \(name)")
        guard let row = result.rows.first, row.count >= 2, let ddl = row[1].text else {
            throw DBError.server(ServerError(message: "\(table.name) does not exist or is not visible"))
        }
        return ddl + ";"
    }

    public func approximateRowCount(_ table: TableRef) async throws -> Int64? {
        let result = try await query(
            """
            SELECT t.TABLE_ROWS FROM information_schema.TABLES t
            WHERE t.TABLE_SCHEMA = ? AND t.TABLE_NAME = ?
            """, [.string(table.database), .string(table.name)])
        guard let value = result.rows.first?.first else { return nil }
        return Self.integer(value)
    }

    /// `information_schema` reports counts and sizes as `bigint unsigned`, so they arrive
    /// as `.uint` rather than `.int`.
    static func integer(_ value: DBValue) -> Int64? {
        switch value {
        case let .int(number): number
        case let .uint(number): Int64(exactly: number)
        default: value.text.flatMap(Int64.init)
        }
    }

    /// `information_schema` comparisons come back as 1/0, sometimes typed as a string.
    static func isTrue(_ value: DBValue) -> Bool {
        switch value {
        case let .bool(flag): flag
        case let .int(number): number != 0
        default: value.text == "1"
        }
    }
}

// MARK: - Table designer reads (SPEC §8, §15b)

extension MySQLIntrospector {
    /// True where `information_schema.CHECK_CONSTRAINTS` exists at all.
    var supportsCheckConstraints: Bool {
        version.flavor == .mariadb ? version.isAtLeast(10, 2) : version.isAtLeast(8, 0, 16)
    }

    public func checkConstraints(of table: TableRef) async throws -> [CheckConstraintInfo] {
        // MySQL only grew CHECK constraints in 8.0.16; before that the parser accepted
        // them and threw them away, so there is nothing to read rather than nothing to say.
        guard supportsCheckConstraints else { return [] }
        let result = try await query(
            """
            SELECT tc.CONSTRAINT_NAME, cc.CHECK_CLAUSE
            FROM information_schema.TABLE_CONSTRAINTS tc
            JOIN information_schema.CHECK_CONSTRAINTS cc
              ON cc.CONSTRAINT_SCHEMA = tc.CONSTRAINT_SCHEMA
             AND cc.CONSTRAINT_NAME = tc.CONSTRAINT_NAME
            WHERE tc.TABLE_SCHEMA = ? AND tc.TABLE_NAME = ? AND tc.CONSTRAINT_TYPE = 'CHECK'
            ORDER BY tc.CONSTRAINT_NAME
            """, [.string(table.database), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[0].text, let clause = row[1].text else { return nil }
            return CheckConstraintInfo(name: name, expression: clause)
        }
    }

    public func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        let result = try await query(
            """
            SELECT TRIGGER_NAME,
                   ACTION_TIMING,
                   EVENT_MANIPULATION,
                   ACTION_STATEMENT,
                   ACTION_ORDER
            FROM information_schema.TRIGGERS
            WHERE EVENT_OBJECT_SCHEMA = ? AND EVENT_OBJECT_TABLE = ?
            ORDER BY ACTION_ORDER, TRIGGER_NAME
            """, [.string(table.database), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[0].text,
                let timing = row[1].text.flatMap({ TriggerTiming(rawValue: $0.uppercased()) }),
                let event = row[2].text.flatMap({ TriggerEvent(rawValue: $0.uppercased()) })
            else { return nil }
            // A MySQL trigger fires on exactly one event and is always row-level.
            return TriggerInfo(
                name: name,
                timing: timing,
                events: [event],
                isRowLevel: true,
                body: row[3].text
            )
        }
    }

    public func partitioning(of table: TableRef) async throws -> PartitioningInfo? {
        let result = try await query(
            """
            SELECT PARTITION_NAME,
                   PARTITION_METHOD,
                   PARTITION_EXPRESSION,
                   PARTITION_DESCRIPTION,
                   TABLE_ROWS
            FROM information_schema.PARTITIONS
            WHERE TABLE_SCHEMA = ? AND TABLE_NAME = ? AND PARTITION_NAME IS NOT NULL
            ORDER BY PARTITION_ORDINAL_POSITION
            """, [.string(table.database), .string(table.name)])

        // An unpartitioned table has one row here with a null PARTITION_NAME, which the
        // WHERE clause above has already removed.
        guard let first = result.rows.first,
            let method = first[1].text.flatMap({ PartitionStrategy(rawValue: $0.uppercased()) }),
            let key = first[2].text
        else { return nil }

        let partitions = result.rows.compactMap { row -> PartitionInfo? in
            guard let name = row[0].text else { return nil }
            return PartitionInfo(
                name: name,
                bound: row[3].text,
                approximateRowCount: row[4].text.flatMap { Int64($0) }
            )
        }
        return PartitioningInfo(
            strategy: method,
            key: key,
            partitions: partitions,
            // HASH and KEY are described by how many partitions there are, not by bounds.
            partitionCount: (method == .hash || method == .key || method == .linearHash
                || method == .linearKey) ? partitions.count : nil
        )
    }

    public func collations(in database: String) async throws -> [CollationInfo] {
        let result = try await query(
            """
            SELECT COLLATION_NAME, CHARACTER_SET_NAME, IS_DEFAULT
            FROM information_schema.COLLATIONS
            ORDER BY CHARACTER_SET_NAME, COLLATION_NAME
            """, [])
        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            return CollationInfo(
                name: name,
                characterSet: row[1].text,
                isDefault: (row[2].text ?? "").uppercased() == "YES"
            )
        }
    }
}

// MARK: - Server monitoring and definitions

extension MySQLIntrospector: ServerIntrospector {
    public func activity() async throws -> [ServerSessionInfo] {
        let result = try await query(
            """
            SELECT p.ID, p.USER, p.DB, p.HOST, p.COMMAND, p.STATE, p.TIME, p.INFO,
                   p.ID = CONNECTION_ID()
            FROM information_schema.PROCESSLIST p
            ORDER BY p.ID
            """)
        return result.rows.compactMap { row in
            guard let id = row[0].text else { return nil }
            let seconds = Self.integer(row[6]) ?? 0
            return ServerSessionInfo(
                id: id,
                user: row[1].text,
                database: row[2].text,
                clientAddress: row[3].text,
                application: nil,
                state: [row[4].text, row[5].text].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
                duration: Self.duration(seconds),
                query: row[7].text,
                isCurrent: Self.isTrue(row[8])
            )
        }
    }

    /// `KILL` takes no parameters, so the id is parsed as an integer before it is written
    /// into the statement; nothing the user typed reaches the server as text.
    public func terminateSession(id: String) async throws {
        guard let thread = UInt64(id) else {
            throw DBError.protocolError("\(id) is not a thread id")
        }
        _ = try await query("KILL CONNECTION \(thread)")
    }

    /// `mysql.user` is off limits to most accounts; `USER_PRIVILEGES` shows every account
    /// the current one is allowed to know about, which for an ordinary user is itself.
    public func users() async throws -> [ServerUserInfo] {
        let result = try await query(
            """
            SELECT u.GRANTEE, GROUP_CONCAT(u.PRIVILEGE_TYPE ORDER BY u.PRIVILEGE_TYPE SEPARATOR ', ')
            FROM information_schema.USER_PRIVILEGES u
            GROUP BY u.GRANTEE
            ORDER BY u.GRANTEE
            """)
        return result.rows.compactMap { row in
            guard let grantee = row[0].text else { return nil }
            // `'name'@'host'`
            let parts = grantee.split(separator: "@", maxSplits: 1).map {
                $0.trimmingCharacters(in: CharacterSet(charactersIn: "'`\""))
            }
            let privileges = row[1].text ?? ""
            let set = Set(privileges.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            return ServerUserInfo(
                name: parts.first ?? grantee,
                host: parts.count > 1 ? parts[1] : nil,
                isSuperuser: set.contains("SUPER"),
                canLogin: true,
                canCreateDatabase: set.contains("CREATE"),
                canCreateRole: set.contains("CREATE USER") || set.contains("CREATE ROLE"),
                attributes: privileges.isEmpty ? nil : privileges
            )
        }
    }

    public func variables() async throws -> [ServerVariableInfo] {
        let result = try await query("SHOW GLOBAL VARIABLES")
        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            return ServerVariableInfo(name: name, value: row[1].text ?? "")
        }
    }

    /// `SHOW GRANTS`, one statement per line, exactly as the server writes them.
    public func grants(for user: ServerUserInfo) async throws -> [String] {
        let account =
            "\(SQLLiteral.quoteString(user.name, dialect: .mysql))@\(SQLLiteral.quoteString(user.host ?? "%", dialect: .mysql))"
        let result = try await query("SHOW GRANTS FOR \(account)")
        return result.rows.compactMap { $0.first?.text }
    }

    public func viewDefinition(_ table: TableRef) async throws -> String {
        let name = Identifier.qualified(table, dialect: .mysql)
        let result = try await query("SHOW CREATE VIEW \(name)")
        guard let row = result.rows.first, row.count >= 2, let ddl = row[1].text else {
            throw DBError.server(ServerError(message: "\(table.name) is not a view or is not visible"))
        }
        return ddl + ";\n"
    }

    public func routineDefinition(
        in schema: SchemaRef, name: String, signature: String, kind: RoutineKind
    ) async throws -> String {
        let qualified = Identifier.qualify([schema.database, name], dialect: .mysql)
        let verb = kind == .procedure ? "PROCEDURE" : "FUNCTION"
        let result = try await query("SHOW CREATE \(verb) \(qualified)")
        // Columns: Procedure/Function, sql_mode, Create Procedure/Function, …
        guard let row = result.rows.first, row.count >= 3, let ddl = row[2].text, !ddl.isEmpty else {
            throw DBError.server(
                ServerError(message: "\(name) was not found, or its body is not visible to this account"))
        }
        return ddl + ";\n"
    }

    static func duration(_ seconds: Int64) -> String {
        let hours = seconds / 3_600
        let minutes = (seconds % 3_600) / 60
        let rest = seconds % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, rest)
    }
}
