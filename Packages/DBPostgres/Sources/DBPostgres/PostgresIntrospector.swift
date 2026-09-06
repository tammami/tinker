import DBCore
import DBSQL
import Foundation
import Logging
import NIOConcurrencyHelpers
import PostgresNIO

/// Reads PostgreSQL's system catalogs.
///
/// Queries read `pg_catalog` directly rather than `information_schema`, because the
/// catalogs expose identity columns, generated columns, partitioning and index methods
/// that the standard views omit. Version-dependent columns are guarded by
/// ``ServerVersion/isAtLeast(_:_:_:)``.
public struct PostgresIntrospector: SchemaIntrospector {
    let connection: PostgresConnection
    let logger: Logger
    let decoder: PostgresBinaryDecoder
    let version: ServerVersion
    let currentDatabase: String

    init(
        connection: PostgresConnection,
        logger: Logger,
        decoder: PostgresBinaryDecoder,
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
            if parameters.isEmpty {
                return try await PostgresSQLConnection.rawQuery(
                    sql, on: connection, logger: logger, decoder: decoder
                )
            }
            let bindings = PostgresParameterEncoder.bindings(for: parameters)
            let collected = NIOLockedValueBox<(columns: [ColumnMeta], rows: [[DBValue]])>(([], []))
            let decoder = decoder
            _ = try await connection.query(
                PostgresQuery(unsafeSQL: sql, binds: bindings), logger: logger
            ) { row in
                collected.withLockedValue { state in
                    if state.columns.isEmpty {
                        state.columns = PostgresSQLConnection.columns(of: row, decoder: decoder)
                    }
                    state.rows.append(PostgresSQLConnection.values(of: row, decoder: decoder))
                }
            }.get()
            let state = collected.withLockedValue { $0 }
            return QueryResult(
                columns: state.columns, rows: state.rows,
                completion: QueryCompletion(durationTotal: .zero)
            )
        } catch {
            throw PostgresErrorMapper.map(error, user: "")
        }
    }

    // MARK: - Databases and schemas

    public func databases() async throws -> [DatabaseInfo] {
        let result = try await query(
            """
            SELECT d.datname,
                   d.datname = current_database(),
                   shobj_description(d.oid, 'pg_database'),
                   pg_encoding_to_char(d.encoding),
                   d.datcollate
            FROM pg_catalog.pg_database d
            WHERE d.datallowconn AND NOT d.datistemplate
            ORDER BY d.datname
            """)
        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            return DatabaseInfo(
                name: name,
                isCurrent: row[1] == .bool(true),
                comment: row[2].text,
                characterSet: row[3].text,
                collation: row[4].text
            )
        }
    }

    public func schemas(in database: String) async throws -> [SchemaInfo] {
        let result = try await query(
            """
            SELECT n.nspname,
                   pg_get_userbyid(n.nspowner),
                   obj_description(n.oid, 'pg_namespace')
            FROM pg_catalog.pg_namespace n
            WHERE n.nspname NOT LIKE 'pg\\_temp\\_%' AND n.nspname NOT LIKE 'pg\\_toast%'
            ORDER BY n.nspname
            """)
        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            return SchemaInfo(
                ref: SchemaRef(database: database, schema: name),
                owner: row[1].text,
                comment: row[2].text,
                isSystem: name == "pg_catalog" || name == "information_schema"
            )
        }
    }

    // MARK: - Tables

    public func tables(in schema: SchemaRef) async throws -> [TableInfo] {
        let result = try await query(
            """
            SELECT c.relname,
                   c.relkind::text,
                   obj_description(c.oid, 'pg_class'),
                   pg_get_userbyid(c.relowner),
                   CASE WHEN c.relkind IN ('r', 'm', 'p') THEN pg_total_relation_size(c.oid) ELSE NULL END::int8,
                   c.reltuples::int8
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
            ORDER BY c.relname
            """, [.string(schema.schema)])
        return Self.tableInfos(result, schema: schema)
    }

    /// One relation's entry: the designer's comment and owner without sizing every
    /// relation in the schema.
    public func tableInfo(of table: TableRef) async throws -> TableInfo? {
        let result = try await query(
            """
            SELECT c.relname,
                   c.relkind::text,
                   obj_description(c.oid, 'pg_class'),
                   pg_get_userbyid(c.relowner),
                   CASE WHEN c.relkind IN ('r', 'm', 'p') THEN pg_total_relation_size(c.oid) ELSE NULL END::int8,
                   c.reltuples::int8
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('r', 'v', 'm', 'f', 'p')
            """, [.string(table.schemaRef.schema), .string(table.name)])
        return Self.tableInfos(result, schema: table.schemaRef).first
    }

    private static func tableInfos(_ result: QueryResult, schema: SchemaRef) -> [TableInfo] {
        result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            let estimate: Int64? = if case let .int(value) = row[5], value >= 0 { value } else { nil }
            let size: Int64? = if case let .int(value) = row[4] { value } else { nil }
            return TableInfo(
                ref: TableRef(schema: schema, name: name),
                kind: Self.kind(fromRelKind: row[1].text ?? "r"),
                comment: row[2].text,
                owner: row[3].text,
                sizeBytes: size,
                approximateRowCount: estimate
            )
        }
    }

    static func kind(fromRelKind relKind: String) -> TableKind {
        switch relKind {
        case "v": .view
        case "m": .materializedView
        case "f": .foreignTable
        case "p": .partitionedTable
        default: .table
        }
    }

    // MARK: - Columns

    public func columns(of table: TableRef) async throws -> [ColumnInfo] {
        // `attgenerated` arrived in PostgreSQL 12; older servers report generated columns
        // only through the default expression.
        let generatedExpression = version.isAtLeast(12) ? "a.attgenerated::text" : "''::text"
        let result = try await query(
            """
            SELECT a.attnum,
                   a.attname,
                   pg_catalog.format_type(a.atttypid, a.atttypmod),
                   a.atttypid::int8,
                   NOT a.attnotnull,
                   pg_get_expr(ad.adbin, ad.adrelid),
                   COALESCE(pk.is_pk, false),
                   a.attidentity::text,
                   \(generatedExpression),
                   col_description(a.attrelid, a.attnum),
                   co.collname,
                   (SELECT array_agg(e.enumlabel ORDER BY e.enumsortorder)
                      FROM pg_catalog.pg_enum e WHERE e.enumtypid = a.atttypid)
            FROM pg_catalog.pg_attribute a
            JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            LEFT JOIN pg_catalog.pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
            LEFT JOIN pg_catalog.pg_collation co ON co.oid = a.attcollation
            LEFT JOIN LATERAL (
                SELECT true AS is_pk
                FROM pg_catalog.pg_index i
                WHERE i.indrelid = a.attrelid AND i.indisprimary AND a.attnum = ANY (i.indkey)
            ) pk ON true
            WHERE n.nspname = $1 AND c.relname = $2 AND a.attnum > 0 AND NOT a.attisdropped
            ORDER BY a.attnum
            """, [.string(table.schema), .string(table.name)])

        return result.rows.compactMap { row in
            guard case let .int(ordinal) = row[0], let name = row[1].text else { return nil }
            let typeOID = if case let .int(value) = row[3], value >= 0 { UInt32(value) } else { UInt32(0) }
            let defaultExpression = row[5].text
            let identity = row[7].text ?? ""
            let generated = row[8].text ?? ""
            let labels: [String]? =
                if case let .array(items) = row[11] {
                    items.compactMap(\.text)
                } else {
                    nil
                }
            return ColumnInfo(
                ordinal: Int(ordinal),
                name: name,
                nativeType: row[2].text ?? "unknown",
                kind: PGOID.kind(for: typeOID, catalog: decoder.catalog),
                isNullable: row[4] == .bool(true),
                defaultExpression: defaultExpression,
                isPrimaryKey: row[6] == .bool(true),
                // A serial column has a `nextval(...)` default; an identity column says so directly.
                isAutoIncrement: !identity.isEmpty || defaultExpression?.hasPrefix("nextval(") == true,
                isGenerated: !generated.isEmpty,
                comment: row[9].text,
                characterSet: nil,
                collation: row[10].text,
                enumLabels: (labels?.isEmpty ?? true) ? nil : labels
            )
        }
    }

    // MARK: - Indexes, keys

    public func indexes(of table: TableRef) async throws -> [IndexInfo] {
        let result = try await query(
            """
            SELECT ic.relname,
                   i.indisunique,
                   i.indisprimary,
                   am.amname,
                   pg_get_expr(i.indpred, i.indrelid),
                   ARRAY(
                       -- indkey is a 0-based int2vector, while pg_get_indexdef numbers
                       -- its columns from 1; passing 0 would return the whole definition.
                       SELECT pg_get_indexdef(i.indexrelid, (k.i + 1)::int, true)
                       FROM generate_subscripts(i.indkey, 1) AS k(i)
                       ORDER BY k.i
                   ),
                   (
                       SELECT bool_and(a.attnotnull)
                       FROM unnest(i.indkey) AS key(attnum)
                       JOIN pg_catalog.pg_attribute a
                         ON a.attrelid = i.indrelid AND a.attnum = key.attnum
                   )
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class ic ON ic.oid = i.indexrelid
            JOIN pg_catalog.pg_class c ON c.oid = i.indrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_am am ON am.oid = ic.relam
            WHERE n.nspname = $1 AND c.relname = $2
            ORDER BY i.indisprimary DESC, ic.relname
            """, [.string(table.schema), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            let columns: [String] = if case let .array(items) = row[5] { items.compactMap(\.text) } else { [] }
            return IndexInfo(
                name: name,
                columns: columns,
                isUnique: row[1] == .bool(true),
                isPrimary: row[2] == .bool(true),
                method: row[3].text,
                predicate: row[4].text,
                isNullableFree: row[6] == .bool(true)
            )
        }
    }

    public func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo] {
        let result = try await query(
            """
            SELECT con.conname,
                   ARRAY(
                       SELECT a.attname FROM unnest(con.conkey) WITH ORDINALITY AS k(attnum, ord)
                       JOIN pg_catalog.pg_attribute a ON a.attrelid = con.conrelid AND a.attnum = k.attnum
                       ORDER BY k.ord
                   ),
                   fn.nspname,
                   fc.relname,
                   ARRAY(
                       SELECT a.attname FROM unnest(con.confkey) WITH ORDINALITY AS k(attnum, ord)
                       JOIN pg_catalog.pg_attribute a ON a.attrelid = con.confrelid AND a.attnum = k.attnum
                       ORDER BY k.ord
                   ),
                   con.confupdtype::text,
                   con.confdeltype::text
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_class fc ON fc.oid = con.confrelid
            JOIN pg_catalog.pg_namespace fn ON fn.oid = fc.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND con.contype = 'f'
            ORDER BY con.conname
            """, [.string(table.schema), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[0].text, let referencedName = row[3].text else { return nil }
            let columns: [String] = if case let .array(items) = row[1] { items.compactMap(\.text) } else { [] }
            let referenced: [String] = if case let .array(items) = row[4] { items.compactMap(\.text) } else { [] }
            return ForeignKeyInfo(
                name: name,
                columns: columns,
                referencedTable: TableRef(
                    database: table.database, schema: row[2].text ?? "public", name: referencedName
                ),
                referencedColumns: referenced,
                onUpdate: Self.action(from: row[5].text ?? "a"),
                onDelete: Self.action(from: row[6].text ?? "a")
            )
        }
    }

    static func action(from code: String) -> ForeignKeyAction {
        switch code {
        case "r": .restrict
        case "c": .cascade
        case "n": .setNull
        case "d": .setDefault
        default: .noAction
        }
    }

    public func primaryKey(of table: TableRef) async throws -> [String]? {
        let result = try await query(
            """
            SELECT ARRAY(
                SELECT a.attname
                FROM unnest(i.indkey) WITH ORDINALITY AS k(attnum, ord)
                JOIN pg_catalog.pg_attribute a ON a.attrelid = i.indrelid AND a.attnum = k.attnum
                ORDER BY k.ord
            )
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class c ON c.oid = i.indrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND i.indisprimary
            """, [.string(table.schema), .string(table.name)])
        guard case let .array(items)? = result.rows.first?.first else { return nil }
        let names = items.compactMap(\.text)
        return names.isEmpty ? nil : names
    }

    // MARK: - Routines

    public func routines(in schema: SchemaRef) async throws -> [RoutineInfo] {
        // `prokind` replaced `proisagg`/`proiswindow` in PostgreSQL 11.
        let kindExpression =
            version.isAtLeast(11)
            ? "p.prokind::text"
            : "CASE WHEN p.proisagg THEN 'a' WHEN p.proiswindow THEN 'w' ELSE 'f' END"
        let result = try await query(
            """
            SELECT p.proname,
                   \(kindExpression),
                   pg_get_function_identity_arguments(p.oid),
                   pg_catalog.format_type(p.prorettype, NULL),
                   l.lanname,
                   obj_description(p.oid, 'pg_proc')
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            JOIN pg_catalog.pg_language l ON l.oid = p.prolang
            WHERE n.nspname = $1
            ORDER BY p.proname
            """, [.string(schema.schema)])

        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            let kind: RoutineKind =
                switch row[1].text ?? "f" {
                case "p": .procedure
                case "a": .aggregate
                case "w": .window
                default: .function
                }
            return RoutineInfo(
                name: name,
                kind: kind,
                signature: row[2].text ?? "",
                returnType: row[3].text,
                language: row[4].text,
                comment: row[5].text
            )
        }
    }

    // MARK: - DDL and size

    /// PostgreSQL has no `SHOW CREATE TABLE`, so the statement is synthesized from the
    /// catalogs. Columns, defaults, identity, primary key, unique and foreign keys,
    /// check constraints, indexes and comments are all included.
    public func tableDDL(_ table: TableRef) async throws -> String {
        let columns = try await columns(of: table)
        guard !columns.isEmpty else {
            throw DBError.server(ServerError(message: "\(table.name) does not exist or is not visible"))
        }
        let qualified = Identifier.qualify([table.schema, table.name], dialect: .postgresql)
        var lines: [String] = []

        for column in columns {
            let isSerial = column.isAutoIncrement && column.defaultExpression?.hasPrefix("nextval(") == true
            // A serial column is spelled as its serial type, so running the DDL elsewhere
            // makes the sequence too instead of pointing at one that does not exist.
            let typeName = isSerial ? Self.serialType(for: column.nativeType) : column.nativeType
            var line = "    \(Identifier.quote(column.name, dialect: .postgresql)) \(typeName)"
            if let collation = column.collation, collation != "default" {
                line += " COLLATE \(Identifier.quote(collation, dialect: .postgresql))"
            }
            if column.isGenerated, let expression = column.defaultExpression {
                line += " GENERATED ALWAYS AS (\(expression)) STORED"
            } else if isSerial {
                // The sequence is implied by the type.
            } else if column.isAutoIncrement, column.defaultExpression == nil {
                line += " GENERATED BY DEFAULT AS IDENTITY"
            } else if let expression = column.defaultExpression {
                line += " DEFAULT \(expression)"
            }
            if !column.isNullable, !isSerial { line += " NOT NULL" }
            lines.append(line)
        }

        let constraints = try await query(
            """
            SELECT con.conname, pg_get_constraintdef(con.oid)
            FROM pg_catalog.pg_constraint con
            JOIN pg_catalog.pg_class c ON c.oid = con.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND con.contype IN ('p', 'u', 'f', 'c')
            ORDER BY con.contype, con.conname
            """, [.string(table.schema), .string(table.name)])
        for row in constraints.rows {
            guard let name = row[0].text, let definition = row[1].text else { continue }
            lines.append("    CONSTRAINT \(Identifier.quote(name, dialect: .postgresql)) \(definition)")
        }

        var ddl = "CREATE TABLE \(qualified) (\n\(lines.joined(separator: ",\n"))\n);"

        let indexes = try await query(
            """
            SELECT pg_get_indexdef(i.indexrelid)
            FROM pg_catalog.pg_index i
            JOIN pg_catalog.pg_class c ON c.oid = i.indrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND NOT i.indisprimary
              AND NOT EXISTS (
                  SELECT 1 FROM pg_catalog.pg_constraint con
                  WHERE con.conindid = i.indexrelid AND con.contype IN ('u', 'p')
              )
            ORDER BY 1
            """, [.string(table.schema), .string(table.name)])
        for row in indexes.rows {
            guard let definition = row[0].text else { continue }
            ddl += "\n\(definition);"
        }

        let tableComment = try await query(
            """
            SELECT obj_description(c.oid, 'pg_class')
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
            """, [.string(table.schema), .string(table.name)])
        if let comment = tableComment.rows.first?.first?.text {
            ddl += "\nCOMMENT ON TABLE \(qualified) IS \(SQLLiteral.quoteString(comment, dialect: .postgresql));"
        }
        for column in columns where column.comment != nil {
            let comment = column.comment ?? ""
            let target = "\(qualified).\(Identifier.quote(column.name, dialect: .postgresql))"
            ddl += "\nCOMMENT ON COLUMN \(target) IS \(SQLLiteral.quoteString(comment, dialect: .postgresql));"
        }
        return ddl
    }

    /// The serial pseudo-type behind an integer column with a `nextval` default.
    static func serialType(for nativeType: String) -> String {
        switch nativeType.lowercased() {
        case "bigint", "int8": "bigserial"
        case "smallint", "int2": "smallserial"
        default: "serial"
        }
    }

    public func approximateRowCount(_ table: TableRef) async throws -> Int64? {
        let result = try await query(
            """
            SELECT c.reltuples::int8
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2
            """, [.string(table.schema), .string(table.name)])
        guard case let .int(value)? = result.rows.first?.first, value >= 0 else { return nil }
        return value
    }
}

// MARK: - Table designer reads (SPEC §8, §15b)

extension PostgresIntrospector {
    public func checkConstraints(of table: TableRef) async throws -> [CheckConstraintInfo] {
        // `pg_get_constraintdef` renders "CHECK ((id > 0))"; the designer wants the
        // predicate on its own, which is what `conbin` deparses to.
        let result = try await query(
            """
            SELECT c.conname,
                   pg_get_expr(c.conbin, c.conrelid),
                   c.convalidated
            FROM pg_catalog.pg_constraint c
            JOIN pg_catalog.pg_class t ON t.oid = c.conrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = $1 AND t.relname = $2 AND c.contype = 'c'
            ORDER BY c.conname
            """, [.string(table.schema), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[0].text, let expression = row[1].text else { return nil }
            return CheckConstraintInfo(
                name: name, expression: expression, isValidated: row[2] != .bool(false)
            )
        }
    }

    public func triggers(of table: TableRef) async throws -> [TriggerInfo] {
        // tgtype is a bit mask: 1 row-level, 2 before, 4 insert, 8 delete, 16 update,
        // 32 truncate, 64 instead-of.
        let result = try await query(
            """
            SELECT t.tgname,
                   t.tgtype::int,
                   pg_get_expr(t.tgqual, t.tgrelid),
                   p.proname,
                   n2.nspname
            FROM pg_catalog.pg_trigger t
            JOIN pg_catalog.pg_class c ON c.oid = t.tgrelid
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_catalog.pg_proc p ON p.oid = t.tgfoid
            JOIN pg_catalog.pg_namespace n2 ON n2.oid = p.pronamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND NOT t.tgisinternal
            ORDER BY t.tgname
            """, [.string(table.schema), .string(table.name)])

        return result.rows.compactMap { row in
            guard let name = row[0].text, let raw = row[1].text.flatMap({ Int($0) }) else {
                return nil
            }
            var events: [TriggerEvent] = []
            if raw & 4 != 0 { events.append(.insert) }
            if raw & 8 != 0 { events.append(.delete) }
            if raw & 16 != 0 { events.append(.update) }
            if raw & 32 != 0 { events.append(.truncate) }

            let timing: TriggerTiming = if raw & 64 != 0 { .insteadOf } else if raw & 2 != 0 { .before } else { .after }

            let call = [row[4].text, row[3].text]
                .compactMap { $0 }
                .map { "\"\($0)\"" }
                .joined(separator: ".")
            return TriggerInfo(
                name: name,
                timing: timing,
                events: events,
                isRowLevel: raw & 1 != 0,
                condition: row[2].text,
                functionCall: "\(call)()"
            )
        }
    }

    public func partitioning(of table: TableRef) async throws -> PartitioningInfo? {
        let result = try await query(
            """
            SELECT pg_get_partkeydef(c.oid)
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind = 'p'
            """, [.string(table.schema), .string(table.name)])

        // `pg_get_partkeydef` renders "RANGE (created_at)"; split the strategy off the key.
        guard let definition = result.rows.first?.first?.text,
            let open = definition.firstIndex(of: "("),
            definition.hasSuffix(")")
        else { return nil }
        let strategyText = definition[definition.startIndex ..< open]
            .trimmingCharacters(in: .whitespaces)
            .uppercased()
        guard let strategy = PartitionStrategy(rawValue: strategyText) else { return nil }
        let key = String(definition[definition.index(after: open) ..< definition.index(before: definition.endIndex)])

        let children = try await query(
            """
            SELECT c.relname,
                   pg_get_expr(c.relpartbound, c.oid),
                   c.reltuples::bigint
            FROM pg_catalog.pg_inherits i
            JOIN pg_catalog.pg_class c ON c.oid = i.inhrelid
            JOIN pg_catalog.pg_class parent ON parent.oid = i.inhparent
            JOIN pg_catalog.pg_namespace n ON n.oid = parent.relnamespace
            WHERE n.nspname = $1 AND parent.relname = $2
            ORDER BY c.relname
            """, [.string(table.schema), .string(table.name)])

        return PartitioningInfo(
            strategy: strategy,
            key: key,
            partitions: children.rows.compactMap { row in
                guard let name = row[0].text else { return nil }
                return PartitionInfo(
                    name: name,
                    bound: row[1].text,
                    approximateRowCount: row[2].text.flatMap { Int64($0) }
                )
            }
        )
    }

    public func collations(in database: String) async throws -> [CollationInfo] {
        // A PostgreSQL collation belongs to a schema, not to a character set, and the same
        // name appears in several encodings; the designer only needs the names.
        let result = try await query(
            """
            SELECT DISTINCT c.collname
            FROM pg_catalog.pg_collation c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.collnamespace
            WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
               OR c.collname IN ('default', 'C', 'POSIX')
            ORDER BY c.collname
            """, [])
        return result.rows.compactMap { row in
            row.first?.text.map { CollationInfo(name: $0, isDefault: $0 == "default") }
        }
    }
}

// MARK: - Server monitoring and definitions

extension PostgresIntrospector: ServerIntrospector {
    public func activity() async throws -> [ServerSessionInfo] {
        let result = try await query(
            """
            SELECT a.pid::text,
                   a.usename,
                   a.datname,
                   COALESCE(host(a.client_addr), 'local'),
                   a.application_name,
                   a.state,
                   CASE WHEN a.state = 'active'
                        THEN date_trunc('second', clock_timestamp() - a.query_start)::text
                        ELSE date_trunc('second', clock_timestamp() - a.state_change)::text END,
                   a.query,
                   a.pid = pg_backend_pid()
            FROM pg_catalog.pg_stat_activity a
            WHERE a.backend_type = 'client backend' OR a.backend_type IS NULL
            ORDER BY a.pid
            """)
        return result.rows.compactMap { row in
            guard let id = row[0].text else { return nil }
            return ServerSessionInfo(
                id: id,
                user: row[1].text,
                database: row[2].text,
                clientAddress: row[3].text,
                application: row[4].text,
                state: row[5].text,
                duration: row[6].text,
                query: row[7].text,
                isCurrent: row[8] == .bool(true)
            )
        }
    }

    /// `pg_terminate_backend` needs the role to own the session or be a superuser; when it
    /// is neither, the server's own message is what the user sees.
    public func terminateSession(id: String) async throws {
        guard let pid = Int32(id) else {
            throw DBError.protocolError("\(id) is not a backend pid")
        }
        let result = try await query("SELECT pg_terminate_backend($1)", [.int(Int64(pid))])
        if result.rows.first?.first != .bool(true) {
            throw DBError.server(
                ServerError(
                    message:
                        "The server did not terminate backend \(pid); it may have already ended, or the role lacks permission"
                ))
        }
    }

    public func users() async throws -> [ServerUserInfo] {
        let result = try await query(
            """
            SELECT r.rolname, r.rolsuper, r.rolcanlogin, r.rolcreatedb, r.rolcreaterole,
                   r.rolreplication, r.rolconnlimit, r.rolvaliduntil::text,
                   ARRAY(SELECT b.rolname FROM pg_catalog.pg_auth_members m
                         JOIN pg_catalog.pg_roles b ON b.oid = m.roleid
                         WHERE m.member = r.oid)::text
            FROM pg_catalog.pg_roles r
            WHERE r.rolname NOT LIKE 'pg\\_%'
            ORDER BY r.rolname
            """)
        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            var notes: [String] = []
            if row[5] == .bool(true) { notes.append("replication") }
            if let limit = row[6].text, limit != "-1" { notes.append("connection limit \(limit)") }
            if let until = row[7].text { notes.append("valid until \(until)") }
            if let members = row[8].text, members != "{}" { notes.append("member of \(members)") }
            return ServerUserInfo(
                name: name,
                isSuperuser: row[1] == .bool(true),
                canLogin: row[2] == .bool(true),
                canCreateDatabase: row[3] == .bool(true),
                canCreateRole: row[4] == .bool(true),
                attributes: notes.isEmpty ? nil : notes.joined(separator: ", ")
            )
        }
    }

    public func variables() async throws -> [ServerVariableInfo] {
        let result = try await query(
            """
            SELECT s.name, s.setting, s.unit, s.category, s.short_desc
            FROM pg_catalog.pg_settings s
            ORDER BY s.category, s.name
            """)
        return result.rows.compactMap { row in
            guard let name = row[0].text else { return nil }
            return ServerVariableInfo(
                name: name, value: row[1].text ?? "", unit: row[2].text,
                category: row[3].text, summary: row[4].text
            )
        }
    }

    public func viewDefinition(_ table: TableRef) async throws -> String {
        let result = try await query(
            """
            SELECT c.relkind::text, pg_get_viewdef(c.oid, true)
            FROM pg_catalog.pg_class c
            JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = $1 AND c.relname = $2 AND c.relkind IN ('v', 'm')
            """, [.string(table.schema), .string(table.name)])
        guard let row = result.rows.first, let body = row[1].text else {
            throw DBError.server(ServerError(message: "\(table.schema).\(table.name) is not a view"))
        }
        let name = Identifier.qualified(table, dialect: .postgresql)
        let verb = row[0].text == "m" ? "CREATE MATERIALIZED VIEW" : "CREATE OR REPLACE VIEW"
        return "\(verb) \(name) AS\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
    }

    /// Which databases the role may connect to, and the attributes it carries.
    public func grants(for user: ServerUserInfo) async throws -> [String] {
        let result = try await query(
            """
            SELECT d.datname
            FROM pg_catalog.pg_database d
            WHERE d.datallowconn AND NOT d.datistemplate
              AND has_database_privilege($1, d.datname, 'CONNECT')
            ORDER BY d.datname
            """, [.string(user.name)])
        var lines: [String] = []
        var attributes: [String] = []
        if user.isSuperuser { attributes.append("SUPERUSER") }
        if user.canLogin { attributes.append("LOGIN") }
        if user.canCreateDatabase { attributes.append("CREATEDB") }
        if user.canCreateRole { attributes.append("CREATEROLE") }
        if !attributes.isEmpty { lines.append(attributes.joined(separator: " ")) }
        let databases = result.rows.compactMap { $0.first?.text }
        if !databases.isEmpty { lines.append("CONNECT ON " + databases.joined(separator: ", ")) }
        if let extra = user.attributes { lines.append(extra) }
        return lines
    }

    public func routineDefinition(
        in schema: SchemaRef, name: String, signature: String, kind: RoutineKind
    ) async throws -> String {
        // The identity arguments pick one overload; a routine with none has an empty string.
        let result = try await query(
            """
            SELECT pg_get_functiondef(p.oid)
            FROM pg_catalog.pg_proc p
            JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = $1 AND p.proname = $2
              AND pg_get_function_identity_arguments(p.oid) = $3
            LIMIT 1
            """, [.string(schema.schema), .string(name), .string(signature)])
        guard let definition = result.rows.first?.first?.text else {
            throw DBError.server(ServerError(message: "\(schema.schema).\(name)(\(signature)) was not found"))
        }
        return definition
    }
}
