import DBCore
import Foundation

/// Carries a table definition from one engine to another: column types, defaults, indexes
/// and keys rewritten in the target's terms, and what could not be carried listed by name.
///
/// This is what lets Data Transfer and Structure Synchronization cross engines. The
/// translation is deliberately plain: every type maps to the target's nearest type, a
/// default is kept when the target can read it and dropped with a note when it cannot,
/// and constructs one engine has and another does not — check constraints written in
/// the source's SQL, triggers, generated columns, full-text indexes — are left out and
/// named in the notes rather than written in a form the target would refuse.
public enum SchemaTranslator {
    /// The translated definition and what was left behind.
    public struct Translation: Sendable, Hashable {
        public var definition: TableDefinition
        public var notes: [String]
    }

    /// `definition` as the target engine would declare it. `schema` moves the table and
    /// its foreign-key targets into another schema; nil keeps them where they are.
    /// `targetCollations` are the collations the target server actually has. Pass them and
    /// a collation the target does not know is dropped and named rather than written into
    /// DDL the server will refuse; leave it empty to skip the check.
    public static func translate(
        _ definition: TableDefinition, from source: SQLDialect, to target: SQLDialect,
        into schema: SchemaRef? = nil, targetCollations: Set<String> = []
    ) -> Translation {
        var result = definition
        var notes: [String] = []
        if let schema {
            result.ref = TableRef(schema: schema, name: definition.ref.name)
            result.foreignKeys = result.foreignKeys.map { key in
                var moved = key
                moved.referencedTable = TableRef(schema: schema, name: key.referencedTable.name)
                return moved
            }
        }
        let table = definition.ref.name
        // Same engine family — MySQL to MariaDB is this — so the character set and
        // collation travel as they are. They still have to exist on the other side:
        // MariaDB reads MySQL's `utf8mb4_0900_ai_ci`, but MySQL refuses MariaDB's
        // `utf8mb4_uca1400_ai_ci` outright.
        guard source != target else {
            let pruned = pruneUnknownCollations(
                result, known: targetCollations, dialect: target, table: table)
            return Translation(definition: pruned.definition, notes: pruned.notes)
        }

        var dropped: Set<String> = []
        result.columns = definition.columns.map { column in
            var translated = column
            translated.type = translateType(column.type, enumLabels: column.enumLabels, from: source, to: target)
            // A type the target has no equal for still gets its nearest neighbour, but the
            // person is told which ones those are: a zone, an array or a geometry that
            // becomes text is not something to discover from the data afterwards.
            if let lost = lostInTranslation(column.type, rendered: translated.type, from: source, to: target) {
                notes.append("\(table).\(column.name): \(lost)")
            }
            var translatedDefault = translateDefault(
                column.defaultExpression, columnType: column.type, from: source, to: target)
            // MySQL takes a default on a TEXT, BLOB or JSON column only as an expression.
            if target == .mysql, let literal = translatedDefault, literal.uppercased() != "NULL", !literal.hasPrefix("("),
                ["text", "longtext", "longblob", "json"].contains(where: { translated.type.lowercased().hasPrefix($0) })
            {
                translatedDefault = "(\(literal))"
            }
            if column.defaultExpression != nil, translatedDefault == nil, !column.isAutoIncrement {
                notes.append("\(table).\(column.name): the default \(column.defaultExpression ?? "") was not carried")
            }
            translated.defaultExpression = translatedDefault
            // Across engine families a collation name means nothing on the other side:
            // MySQL names a character set and a collation together, PostgreSQL takes its
            // collations from the operating system, and SQLite has three. The columns get
            // the target's default. Collected and said once per table below, because a
            // note on every text column would bury the ones that matter.
            dropped.formUnion([column.characterSet, column.collation].compactMap { $0 })
            translated.characterSet = nil
            translated.collation = nil
            if column.generatedExpression != nil {
                notes.append("\(table).\(column.name): the generated expression was not carried; the column is plain")
                translated.generatedExpression = nil
            }
            if target == .sqlite { translated.comment = nil }
            if target != .mysql { translated.enumLabels = nil }
            return translated
        }

        if !dropped.isEmpty {
            notes.append(
                "\(table): the character set and collation (\(dropped.sorted().joined(separator: ", ")))"
                    + " were not carried; the columns take \(target.displayName)'s own, which decides"
                    + " how they compare, sort and enforce uniqueness")
        }

        result.indexes = definition.indexes.compactMap { index in
            let method = index.method?.uppercased() ?? ""
            if method == "FULLTEXT" || method == "SPATIAL" || method == "GIN" || method == "GIST" || method == "BRIN" {
                notes.append("\(table): the \(method.lowercased()) index \(index.name) was not carried")
                return nil
            }
            var translated = index
            translated.method = nil
            if index.predicate != nil, target == .mysql {
                notes.append("\(table): the index \(index.name) lost its WHERE clause; MySQL has no partial indexes")
                translated.predicate = nil
            }
            translated.columns = index.columns.map { column in
                var plain = column
                plain.prefixLength = nil
                plain.operatorClass = nil
                // MySQL indexes a TEXT or BLOB column only up to a prefix; 191 characters
                // fits every row format and character set InnoDB has.
                if target == .mysql, let type = result.columns.first(where: { $0.name == column.name })?.type.lowercased(),
                    ["text", "longtext", "mediumtext", "tinytext", "blob", "longblob", "json"].contains(where: { type.hasPrefix($0) })
                {
                    plain.prefixLength = 191
                    notes.append("\(table): the index \(index.name) covers the first 191 characters of \(column.name); MySQL cannot index a whole TEXT column")
                }
                return plain
            }
            return translated
        }

        if !definition.checks.isEmpty {
            notes.append(
                "\(table): \(definition.checks.count) check constraint\(definition.checks.count == 1 ? "" : "s") not carried; the expressions are written in \(source.displayName)'s SQL"
            )
            result.checks = []
        }
        if !definition.triggers.isEmpty {
            notes.append("\(table): \(definition.triggers.count) trigger\(definition.triggers.count == 1 ? "" : "s") not carried")
            result.triggers = []
        }
        if definition.partitioning != nil {
            notes.append("\(table): partitioning was not carried; the target gets one plain table")
            result.partitioning = nil
        }
        result.options = TableOptions()
        if target == .sqlite { result.comment = nil }
        return Translation(definition: result, notes: notes)
    }

    /// The definition with the facets one engine has and another does not taken off —
    /// character sets, collations, comments, index methods, storage options — so two
    /// tables on different engines compare on what both can express.
    public static func comparable(_ definition: TableDefinition) -> TableDefinition {
        var result = definition
        result.comment = nil
        result.options = TableOptions()
        result.columns = definition.columns.map { column in
            var plain = column
            plain.characterSet = nil
            plain.collation = nil
            plain.comment = nil
            return plain
        }
        result.indexes = definition.indexes.map { index in
            var plain = index
            plain.method = nil
            plain.comment = nil
            plain.columns = index.columns.map { column in
                var bare = column
                bare.prefixLength = nil
                bare.operatorClass = nil
                return bare
            }
            return plain
        }
        return result
    }

    // MARK: - Types

    /// A canonical view of a column type, between the engine it came from and the one it
    /// goes to.
    enum Canonical: Equatable {
        case bool
        case int8, int16, int32, int64, uint32, uint64
        case float32, float64
        case decimal(precision: Int?, scale: Int?)
        case char(Int?), varchar(Int?), text
        case binary(Int?), blob
        case date, time(precision: Int?, zoned: Bool), timestamp(precision: Int?, zoned: Bool), year
        case uuid, json, xml, interval, inet, money, geometry
        case bit(Int?)
        case enumeration([String]), set([String])
        indirect case array(Canonical)
        case other(String)
    }

    /// `type` as the target spells its nearest equivalent.
    public static func translateType(
        _ type: String, enumLabels: [String]? = nil, from source: SQLDialect, to target: SQLDialect
    ) -> String {
        guard source != target else { return type }
        var canonical = canonicalType(type, from: source)
        if case .other = canonical, let labels = enumLabels, !labels.isEmpty { canonical = .enumeration(labels) }
        return render(canonical, for: target)
    }

    static func canonicalType(_ text: String, from source: SQLDialect) -> Canonical {
        let spec = ColumnTypeSpec.parse(text)
        var base = spec.base.lowercased().trimmingCharacters(in: .whitespaces)
        let suffix = spec.suffix.lowercased()
        let unsigned = suffix.contains("unsigned")
        let zoned = suffix.contains("with time zone") && !suffix.contains("without")
        if !spec.array.isEmpty {
            let element = canonicalType(spec.base + (spec.length.map { "(\($0)\(spec.decimals.map { ",\($0)" } ?? ""))" } ?? ""), from: source)
            return .array(element)
        }
        if base.hasPrefix("_") { base.removeFirst() }
        switch base {
        case "bool", "boolean": return .bool
        case "tinyint": return spec.length == 1 && !unsigned && source == .mysql ? .bool : (unsigned ? .int16 : .int8)
        case "smallint", "int2", "smallserial", "serial2": return unsigned ? .int32 : .int16
        case "mediumint": return .int32
        case "int", "integer", "int4", "serial", "serial4":
            if source == .sqlite { return .int64 }
            return unsigned ? .uint32 : .int32
        case "bigint", "int8", "bigserial", "serial8": return unsigned ? .uint64 : .int64
        case "float", "float4", "real": return source == .mysql && (spec.length ?? 0) > 24 ? .float64 : (source == .sqlite ? .float64 : .float32)
        case "double", "double precision", "float8": return .float64
        case "decimal", "numeric", "dec", "fixed": return .decimal(precision: spec.length, scale: spec.decimals)
        case "money", "smallmoney": return .money
        case "char", "character", "bpchar", "nchar": return .char(spec.length)
        case "varchar", "character varying", "nvarchar", "varchar2", "string": return .varchar(spec.length)
        case "text", "tinytext", "mediumtext", "longtext", "citext", "clob", "ntext": return .text
        case "binary": return .binary(spec.length)
        case "varbinary": return .binary(spec.length)
        case "blob", "tinyblob", "mediumblob", "longblob", "bytea": return .blob
        case "date": return .date
        case "time", "timetz": return .time(precision: spec.length, zoned: zoned || base == "timetz")
        case "datetime": return .timestamp(precision: spec.length, zoned: false)
        case "timestamp": return .timestamp(precision: spec.length, zoned: zoned || source == .mysql)
        case "timestamptz": return .timestamp(precision: spec.length, zoned: true)
        case "year": return .year
        case "uuid", "uniqueidentifier", "guid": return .uuid
        case "json", "jsonb": return .json
        case "xml": return .xml
        case "interval": return .interval
        case "inet", "cidr", "macaddr", "macaddr8": return .inet
        case "bit", "varbit", "bit varying": return .bit(spec.length)
        case "enum": return .enumeration(spec.values)
        case "set": return .set(spec.values)
        case "geometry", "point", "linestring", "polygon", "multipoint", "multilinestring", "multipolygon",
            "geometrycollection", "geography", "box", "path", "circle", "line", "lseg":
            return .geometry
        case "", "any": return .text
        default:
            return .other(text)
        }
    }

    /// Drops a collation the target server does not have, naming each one.
    ///
    /// Only checks when `known` is non-empty: a caller that cannot reach the target — a
    /// dump writes a script for a server it never opens — passes nothing and keeps what
    /// the source said.
    static func pruneUnknownCollations(
        _ definition: TableDefinition, known: Set<String>, dialect: SQLDialect, table: String
    ) -> (definition: TableDefinition, notes: [String]) {
        // MySQL and MariaDB only. Their names diverge — MySQL refuses MariaDB's `uca1400`
        // spellings — and `information_schema.COLLATIONS` lists every one of them, so an
        // absent name really is absent. PostgreSQL's catalogue read deliberately leaves out
        // `pg_catalog`, where every libc and ICU collation lives, so pruning against it
        // would strip `en_US.utf8` from a PostgreSQL-to-PostgreSQL sync and quietly change
        // how the column sorts. SQLite has three collations and no way to add one in DDL.
        guard dialect == .mysql, !known.isEmpty else { return (definition, []) }
        // MySQL collation names are case-insensitive; PostgreSQL's are not, and this path
        // no longer reaches it.
        let folded = Set(known.map { $0.lowercased() })
        var result = definition
        var notes: [String] = []
        if let collation = definition.options.collation, !folded.contains(collation.lowercased()) {
            notes.append("\(table): the table collation \(collation) is not on the target; its default is used")
            result.options.collation = nil
            result.options.characterSet = nil
        }
        result.columns = definition.columns.map { column in
            guard let collation = column.collation, !folded.contains(collation.lowercased()) else { return column }
            notes.append(
                "\(table).\(column.name): the collation \(collation) is not on the target; its default is used")
            var plain = column
            plain.collation = nil
            plain.characterSet = nil
            return plain
        }
        return (result, notes)
    }

    /// What a column loses when the target has no equal for its type, or nil when the
    /// target's type holds the same thing.
    ///
    /// The test is the round trip: read the rendered type back as a canonical type and see
    /// whether it is still the same kind. Narrowing within a kind — a shorter `varchar`, a
    /// smaller `decimal` — is deliberate and not reported here.
    static func lostInTranslation(
        _ type: String, rendered: String, from source: SQLDialect, to target: SQLDialect
    ) -> String? {
        let before = canonicalType(type, from: source)
        let after = canonicalType(rendered, from: target)
        guard !sameKind(before, after), !widensExactly(before, after) else { return nil }
        let detail: String
        switch before {
        case let .timestamp(_, zoned) where zoned:
            detail = "the time zone is not kept; the value crosses as the server's own text"
        case let .time(_, zoned) where zoned:
            detail = "the offset is not kept; the value crosses as the server's own text"
        case .array:
            detail = "\(target.displayName) has no array type"
        case .geometry:
            detail = "\(target.displayName) has no geometry type here; the shape crosses as text"
        default:
            detail = "\(target.displayName) has no equal for it"
        }
        return "\(type) became \(rendered) — \(detail)"
    }

    /// A whole number carried into something that holds every one of its values.
    ///
    /// PostgreSQL has no unsigned types and SQLite has one integer, so `int unsigned`
    /// becomes `bigint` and `smallint` becomes `INTEGER`. Nothing is lost, and saying so
    /// every time would bury the notes that matter.
    static func widensExactly(_ before: Canonical, _ after: Canonical) -> Bool {
        guard let width = integerWidth(before) else { return false }
        if case .decimal = after { return true }
        guard let target = integerWidth(after) else { return false }
        return target >= width
    }

    /// How many bits a whole-number type needs, signed values included. Nil for the rest.
    private static func integerWidth(_ canonical: Canonical) -> Int? {
        switch canonical {
        case .int8: 8
        case .int16: 16
        case .int32: 32
        case .uint32: 33
        case .int64: 64
        case .uint64: 65
        case .year: 16
        case let .bit(length): (length ?? 1) + 1
        default: nil
        }
    }

    /// Two canonical types describing the same thing, ignoring length and precision.
    static func sameKind(_ lhs: Canonical, _ rhs: Canonical) -> Bool {
        switch (lhs, rhs) {
        case (.bool, .bool), (.date, .date), (.year, .year), (.uuid, .uuid), (.json, .json),
            (.xml, .xml), (.interval, .interval), (.inet, .inet), (.money, .money),
            (.geometry, .geometry), (.text, .text), (.blob, .blob):
            return true
        case (.int8, .int8), (.int16, .int16), (.int32, .int32), (.int64, .int64),
            (.uint32, .uint32), (.uint64, .uint64), (.float32, .float32), (.float64, .float64):
            return true
        case (.decimal, .decimal), (.char, .char), (.varchar, .varchar), (.binary, .binary),
            (.bit, .bit), (.enumeration, .enumeration), (.set, .set):
            return true
        case let (.time(_, left), .time(_, right)), let (.timestamp(_, left), .timestamp(_, right)):
            return left == right
        case let (.array(left), .array(right)):
            return sameKind(left, right)
        case let (.other(left), .other(right)):
            return left == right
        default:
            return false
        }
    }

    static func render(_ canonical: Canonical, for target: SQLDialect) -> String {
        switch target {
        case .postgresql: return renderPostgres(canonical)
        case .mysql: return renderMySQL(canonical)
        case .sqlite: return renderSQLite(canonical)
        }
    }

    /// PostgreSQL's own spellings, as `format_type` writes them, so a translated column
    /// compares equal to what introspection reads back.
    private static func renderPostgres(_ canonical: Canonical) -> String {
        switch canonical {
        case .bool: return "boolean"
        case .int8, .int16: return "smallint"
        case .int32: return "integer"
        case .int64, .uint32: return "bigint"
        case .uint64: return "numeric(20,0)"
        case .float32: return "real"
        case .float64: return "double precision"
        case let .decimal(precision, scale):
            guard let precision else { return "numeric" }
            return "numeric(\(min(precision, 1_000)),\(scale ?? 0))"
        case let .char(length): return "character(\(length ?? 1))"
        case let .varchar(length): return length.map { "character varying(\($0))" } ?? "character varying"
        case .text: return "text"
        case .binary, .blob: return "bytea"
        case .date: return "date"
        case let .time(precision, zoned):
            let width = precision.map { "(\($0))" } ?? ""
            return "time\(width) \(zoned ? "with" : "without") time zone"
        case let .timestamp(precision, zoned):
            let width = precision.map { "(\($0))" } ?? ""
            return "timestamp\(width) \(zoned ? "with" : "without") time zone"
        case .year: return "smallint"
        case .uuid: return "uuid"
        case .json: return "jsonb"
        case .xml: return "xml"
        case .interval: return "interval"
        case .inet: return "inet"
        case .money: return "numeric(19,2)"
        case .geometry: return "text"
        case let .bit(length): return length == 1 || length == nil ? "boolean" : "bit(\(length ?? 1))"
        case .enumeration, .set: return "text"
        case let .array(element): return renderPostgres(element) + "[]"
        case .other: return "text"
        }
    }

    /// MySQL's spellings as `information_schema.COLUMN_TYPE` reports them.
    private static func renderMySQL(_ canonical: Canonical) -> String {
        switch canonical {
        case .bool: return "tinyint(1)"
        case .int8: return "tinyint"
        case .int16: return "smallint"
        case .int32: return "int"
        case .int64: return "bigint"
        case .uint32: return "int unsigned"
        case .uint64: return "bigint unsigned"
        case .float32: return "float"
        case .float64: return "double"
        case let .decimal(precision, scale):
            // An unconstrained `numeric` holds any precision; `decimal(10,0)` would throw
            // every fractional digit away and overflow past ten digits, so it takes
            // MySQL's widest instead.
            guard let precision else { return "decimal(65,30)" }
            let width = min(precision, 65)
            return "decimal(\(width),\(min(scale ?? 0, min(30, width))))"
        case let .char(length): return "char(\(min(length ?? 1, 255)))"
        case let .varchar(length):
            guard let length else { return "text" }
            return length <= 16_383 ? "varchar(\(length))" : "text"
        case .text: return "longtext"
        case let .binary(length): return "varbinary(\(min(length ?? 255, 65_535)))"
        case .blob: return "longblob"
        case .date: return "date"
        case let .time(precision, zoned):
            // MySQL's TIME has no offset: `02:30:00+07` is refused, not truncated. The
            // server's text is kept whole in a string column instead.
            if zoned { return "varchar(32)" }
            return precision.map { "time(\(min($0, 6)))" } ?? "time"
        case let .timestamp(precision, _):
            // DATETIME rather than TIMESTAMP: no 2038 ceiling and no session-zone rewriting.
            return precision.map { "datetime(\(min($0, 6)))" } ?? "datetime"
        case .year: return "year"
        case .uuid: return "char(36)"
        case .json: return "json"
        case .xml: return "longtext"
        case .interval: return "varchar(64)"
        case .inet: return "varchar(45)"
        case .money: return "decimal(19,2)"
        case .geometry: return "text"
        case let .bit(length): return "bit(\(length ?? 1))"
        case let .enumeration(labels):
            guard !labels.isEmpty else { return "varchar(255)" }
            return "enum(" + labels.map { SQLLiteral.quoteString($0, dialect: .mysql) }.joined(separator: ",") + ")"
        case let .set(labels):
            guard !labels.isEmpty else { return "varchar(255)" }
            return "set(" + labels.map { SQLLiteral.quoteString($0, dialect: .mysql) }.joined(separator: ",") + ")"
        case .array: return "json"
        case .other: return "text"
        }
    }

    /// SQLite's conventional names: affinity does the storing, the name says the intent.
    private static func renderSQLite(_ canonical: Canonical) -> String {
        switch canonical {
        case .bool: return "BOOLEAN"
        case .int8, .int16, .int32, .int64, .uint32, .uint64, .year, .bit: return "INTEGER"
        case .float32, .float64: return "REAL"
        case let .decimal(precision, scale):
            guard let precision else { return "NUMERIC" }
            return "NUMERIC(\(precision),\(scale ?? 0))"
        case let .char(length): return "CHAR(\(length ?? 1))"
        case let .varchar(length): return length.map { "VARCHAR(\($0))" } ?? "TEXT"
        case .text, .xml, .interval, .inet, .geometry, .enumeration, .set, .other: return "TEXT"
        case .binary, .blob: return "BLOB"
        case .date: return "DATE"
        // A zoned time keeps its offset as text; SQLite's TIME affinity would not.
        case let .time(_, zoned): return zoned ? "TEXT" : "TIME"
        case .timestamp: return "DATETIME"
        case .uuid: return "UUID"
        case .json, .array: return "JSON"
        case .money: return "NUMERIC(19,2)"
        }
    }

    // MARK: - Defaults

    /// A default expression the target can read, or nil when there is none it could.
    /// `columnType` is what tells a boolean's `1` from an integer's: MySQL writes both as
    /// `1`, and PostgreSQL refuses `boolean DEFAULT 1`.
    public static func translateDefault(
        _ expression: String?, columnType: String? = nil, from source: SQLDialect, to target: SQLDialect
    ) -> String? {
        guard let expression else { return nil }
        guard source != target else { return expression }
        var text = expression.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // PostgreSQL writes `'x'::character varying`; the cast is noise elsewhere.
        text = stripCasts(text)
        let lowered = text.lowercased()

        if lowered.hasPrefix("nextval(") { return nil }
        if lowered == "null" { return "NULL" }
        if ["current_timestamp", "current_timestamp()", "now()", "localtimestamp", "sysdate()", "transaction_timestamp()", "statement_timestamp()"].contains(lowered)
            || lowered.hasPrefix("current_timestamp(")
        {
            return "CURRENT_TIMESTAMP"
        }
        if ["current_date", "curdate()"].contains(lowered) { return "CURRENT_DATE" }
        if ["current_time", "curtime()"].contains(lowered) { return "CURRENT_TIME" }
        let isBoolean = columnType.map { canonicalType($0, from: source) == .bool } ?? false
        if ["true", "b'1'"].contains(lowered) || (isBoolean && lowered == "1") {
            return boolLiteral(true, for: target)
        }
        if ["false", "b'0'"].contains(lowered) || (isBoolean && lowered == "0") {
            return boolLiteral(false, for: target)
        }
        if lowered == "0000-00-00" || lowered == "'0000-00-00'" || lowered.hasPrefix("'0000-00-00") { return nil }
        if ["gen_random_uuid()", "uuid_generate_v4()", "uuid()"].contains(lowered) {
            switch target {
            case .postgresql: return "gen_random_uuid()"
            case .mysql: return "(uuid())"
            case .sqlite: return nil
            }
        }
        // A literal travels as it is: a number, or a quoted string.
        if Double(text) != nil { return text }
        if text.hasPrefix("'"), text.hasSuffix("'"), text.count >= 2 {
            let inner = String(text.dropFirst().dropLast())
            return SQLLiteral.quoteString(inner.replacingOccurrences(of: "''", with: "'"), dialect: target)
        }
        // Anything else is an expression in the source's SQL.
        switch target {
        case .postgresql: return text
        case .mysql: return text.hasPrefix("(") ? text : "(\(text))"
        case .sqlite: return nil
        }
    }

    private static func boolLiteral(_ value: Bool, for target: SQLDialect) -> String {
        target == .postgresql ? (value ? "true" : "false") : (value ? "1" : "0")
    }

    /// `'x'::text`, `'{}'::jsonb`, `0::smallint` → `'x'`, `'{}'`, `0`.
    static func stripCasts(_ text: String) -> String {
        var result = text
        while let range = result.range(of: "::") {
            var end = range.upperBound
            // A type name: words, then an optional `(10,2)` and any number of `[]`. A
            // closing parenthesis on its own belongs to whatever wrapped the literal.
            while end < result.endIndex {
                let character = result[end]
                if character.isLetter || character.isNumber || character == "_" || character == " " {
                    end = result.index(after: end)
                } else if character == "(", let close = result[end...].firstIndex(of: ")") {
                    end = result.index(after: close)
                } else if character == "[", let close = result[end...].firstIndex(of: "]") {
                    end = result.index(after: close)
                } else {
                    break
                }
            }
            result.removeSubrange(range.lowerBound ..< end)
        }
        var trimmed = result.trimmingCharacters(in: .whitespaces)
        // A cast may have wrapped the literal in parentheses: `('x'::text)`.
        while trimmed.hasPrefix("("), trimmed.hasSuffix(")"), trimmed.count > 2,
            !trimmed.dropFirst().dropLast().contains("(")
        {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return trimmed
    }
}
