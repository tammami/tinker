import Foundation

/// Names a schema: a PostgreSQL namespace inside a database, or a MySQL database.
public struct SchemaRef: Sendable, Hashable, Codable, Identifiable, CustomStringConvertible {
    public let database: String
    /// PostgreSQL namespace. MySQL uses ``SchemaRef/mysqlPseudoSchema``.
    public let schema: String

    public init(database: String, schema: String) {
        self.database = database
        self.schema = schema
    }

    /// MySQL has no schema layer; its single pseudo-schema carries the database's own name.
    public static func mysql(_ database: String) -> SchemaRef {
        SchemaRef(database: database, schema: database)
    }

    public var id: String { "\(database).\(schema)" }
    public var description: String { id }
}

/// Names one table, view or materialized view.
public struct TableRef: Sendable, Hashable, Codable, Identifiable, CustomStringConvertible {
    public let database: String
    public let schema: String
    public let name: String

    public init(database: String, schema: String, name: String) {
        self.database = database
        self.schema = schema
        self.name = name
    }

    public init(schema: SchemaRef, name: String) {
        self.init(database: schema.database, schema: schema.schema, name: name)
    }

    public var schemaRef: SchemaRef { SchemaRef(database: database, schema: schema) }
    public var id: String { "\(database).\(schema).\(name)" }
    public var description: String { id }
}

public struct DatabaseInfo: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    public let isCurrent: Bool
    public let comment: String?
    public let characterSet: String?
    public let collation: String?

    public init(
        name: String,
        isCurrent: Bool = false,
        comment: String? = nil,
        characterSet: String? = nil,
        collation: String? = nil
    ) {
        self.name = name
        self.isCurrent = isCurrent
        self.comment = comment
        self.characterSet = characterSet
        self.collation = collation
    }

    public var id: String { name }
}

public struct SchemaInfo: Sendable, Hashable, Codable, Identifiable {
    public let ref: SchemaRef
    public let owner: String?
    public let comment: String?
    /// True for `pg_catalog`, `information_schema` and the like, which the sidebar hides by default.
    public let isSystem: Bool

    public init(ref: SchemaRef, owner: String? = nil, comment: String? = nil, isSystem: Bool = false) {
        self.ref = ref
        self.owner = owner
        self.comment = comment
        self.isSystem = isSystem
    }

    public var id: String { ref.id }
    public var name: String { ref.schema }
}

/// What kind of relation a `TableInfo` describes.
public enum TableKind: String, Sendable, Hashable, Codable, CaseIterable {
    case table
    case view
    case materializedView = "materialized-view"
    case foreignTable = "foreign-table"
    case partitionedTable = "partitioned-table"
    case systemTable = "system-table"

    /// Whether rows can be written directly. Views are read-only in v0.1.
    public var isEditable: Bool { self == .table || self == .partitionedTable }
}

public struct TableInfo: Sendable, Hashable, Codable, Identifiable {
    public let ref: TableRef
    public let kind: TableKind
    public let comment: String?
    public let owner: String?
    /// Storage size in bytes where the server reports one cheaply.
    public let sizeBytes: Int64?
    /// Planner estimate, not a count. `nil` when unknown.
    public let approximateRowCount: Int64?

    public init(
        ref: TableRef,
        kind: TableKind,
        comment: String? = nil,
        owner: String? = nil,
        sizeBytes: Int64? = nil,
        approximateRowCount: Int64? = nil
    ) {
        self.ref = ref
        self.kind = kind
        self.comment = comment
        self.owner = owner
        self.sizeBytes = sizeBytes
        self.approximateRowCount = approximateRowCount
    }

    public var id: String { ref.id }
    public var name: String { ref.name }
}

public struct ColumnInfo: Sendable, Hashable, Codable, Identifiable {
    /// One-based position within the table.
    public let ordinal: Int
    public let name: String
    /// Full native type as the server spells it, e.g. `character varying(255)`.
    public let nativeType: String
    /// The value kind this column produces.
    public let kind: DBValueKind
    public let isNullable: Bool
    /// Default expression text, exactly as stored. `nil` when there is none.
    public let defaultExpression: String?
    public let isPrimaryKey: Bool
    /// PostgreSQL identity/serial, MySQL `AUTO_INCREMENT`.
    public let isAutoIncrement: Bool
    /// PostgreSQL generated column, MySQL generated column.
    public let isGenerated: Bool
    public let comment: String?
    public let characterSet: String?
    public let collation: String?
    /// For `enum` types and MySQL `ENUM`/`SET`, the permitted labels in order.
    public let enumLabels: [String]?

    public init(
        ordinal: Int,
        name: String,
        nativeType: String,
        kind: DBValueKind,
        isNullable: Bool,
        defaultExpression: String? = nil,
        isPrimaryKey: Bool = false,
        isAutoIncrement: Bool = false,
        isGenerated: Bool = false,
        comment: String? = nil,
        characterSet: String? = nil,
        collation: String? = nil,
        enumLabels: [String]? = nil
    ) {
        self.ordinal = ordinal
        self.name = name
        self.nativeType = nativeType
        self.kind = kind
        self.isNullable = isNullable
        self.defaultExpression = defaultExpression
        self.isPrimaryKey = isPrimaryKey
        self.isAutoIncrement = isAutoIncrement
        self.isGenerated = isGenerated
        self.comment = comment
        self.characterSet = characterSet
        self.collation = collation
        self.enumLabels = enumLabels
    }

    public var id: String { name }
}

public struct IndexInfo: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    public let columns: [String]
    public let isUnique: Bool
    public let isPrimary: Bool
    /// btree, hash, gin, … as the server names it.
    public let method: String?
    /// Partial-index predicate, when there is one.
    public let predicate: String?
    /// True when every indexed column is `NOT NULL`, which makes a unique index
    /// usable as a row identity for editing.
    public let isNullableFree: Bool

    public init(
        name: String,
        columns: [String],
        isUnique: Bool,
        isPrimary: Bool = false,
        method: String? = nil,
        predicate: String? = nil,
        isNullableFree: Bool = false
    ) {
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.isPrimary = isPrimary
        self.method = method
        self.predicate = predicate
        self.isNullableFree = isNullableFree
    }

    public var id: String { name }
}

/// What the server does to child rows when the parent changes.
public enum ForeignKeyAction: String, Sendable, Hashable, Codable, CaseIterable {
    case noAction = "NO ACTION"
    case restrict = "RESTRICT"
    case cascade = "CASCADE"
    case setNull = "SET NULL"
    case setDefault = "SET DEFAULT"
}

public struct ForeignKeyInfo: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    public let columns: [String]
    public let referencedTable: TableRef
    public let referencedColumns: [String]
    public let onUpdate: ForeignKeyAction
    public let onDelete: ForeignKeyAction

    public init(
        name: String,
        columns: [String],
        referencedTable: TableRef,
        referencedColumns: [String],
        onUpdate: ForeignKeyAction = .noAction,
        onDelete: ForeignKeyAction = .noAction
    ) {
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
    }

    public var id: String { name }
}

/// A `CHECK` constraint. The expression is kept exactly as the server renders it.
public struct CheckConstraintInfo: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    /// The predicate as the catalog stores it. Never reformatted (SPEC §5).
    public let expression: String
    /// PostgreSQL can mark a constraint `NOT VALID`, which skips the check on existing rows.
    public let isValidated: Bool

    public init(name: String, expression: String, isValidated: Bool = true) {
        self.name = name
        self.expression = expression
        self.isValidated = isValidated
    }

    public var id: String { name }
}

/// When a trigger runs.
public enum TriggerTiming: String, Sendable, Hashable, Codable, CaseIterable {
    case before = "BEFORE"
    case after = "AFTER"
    /// Views only, and PostgreSQL only.
    case insteadOf = "INSTEAD OF"
}

/// What a trigger fires on.
public enum TriggerEvent: String, Sendable, Hashable, Codable, CaseIterable {
    case insert = "INSERT"
    case update = "UPDATE"
    case delete = "DELETE"
    /// PostgreSQL only.
    case truncate = "TRUNCATE"
}

public struct TriggerInfo: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    public let timing: TriggerTiming
    /// A PostgreSQL trigger can fire on several events; MySQL's fires on one.
    public let events: [TriggerEvent]
    /// `FOR EACH ROW` when true, `FOR EACH STATEMENT` when false.
    public let isRowLevel: Bool
    /// PostgreSQL `WHEN (…)`. `nil` when unconditional.
    public let condition: String?
    /// MySQL keeps the body here. PostgreSQL calls a function and leaves this nil.
    public let body: String?
    /// PostgreSQL's `EXECUTE FUNCTION` target, including its argument list.
    public let functionCall: String?
    /// MySQL orders triggers on the same event with `FOLLOWS`/`PRECEDES`.
    public let orderingHint: String?

    public init(
        name: String,
        timing: TriggerTiming,
        events: [TriggerEvent],
        isRowLevel: Bool = true,
        condition: String? = nil,
        body: String? = nil,
        functionCall: String? = nil,
        orderingHint: String? = nil
    ) {
        self.name = name
        self.timing = timing
        self.events = events
        self.isRowLevel = isRowLevel
        self.condition = condition
        self.body = body
        self.functionCall = functionCall
        self.orderingHint = orderingHint
    }

    public var id: String { name }
}

/// How a partitioned table divides its rows.
public enum PartitionStrategy: String, Sendable, Hashable, Codable, CaseIterable {
    case range = "RANGE"
    case list = "LIST"
    case hash = "HASH"
    /// MySQL only.
    case key = "KEY"
    /// MySQL only.
    case linearHash = "LINEAR HASH"
    /// MySQL only.
    case linearKey = "LINEAR KEY"
}

public struct PartitionInfo: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    /// The bound as the server spells it: `FROM ('2024-01-01') TO ('2025-01-01')`,
    /// `IN (1, 2)`, `WITH (MODULUS 4, REMAINDER 0)`, or MySQL's `VALUES LESS THAN (…)`.
    public let bound: String?
    public let approximateRowCount: Int64?

    public init(name: String, bound: String? = nil, approximateRowCount: Int64? = nil) {
        self.name = name
        self.bound = bound
        self.approximateRowCount = approximateRowCount
    }

    public var id: String { name }
}

public struct PartitioningInfo: Sendable, Hashable, Codable {
    public let strategy: PartitionStrategy
    /// The partition key expression, as the server renders it.
    public let key: String
    public let partitions: [PartitionInfo]
    /// MySQL `PARTITIONS n` for hash and key strategies.
    public let partitionCount: Int?

    public init(
        strategy: PartitionStrategy,
        key: String,
        partitions: [PartitionInfo] = [],
        partitionCount: Int? = nil
    ) {
        self.strategy = strategy
        self.key = key
        self.partitions = partitions
        self.partitionCount = partitionCount
    }
}

/// A collation the server offers, for the column editor's picker.
public struct CollationInfo: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    /// MySQL groups collations under a character set; PostgreSQL leaves this nil.
    public let characterSet: String?
    public let isDefault: Bool

    public init(name: String, characterSet: String? = nil, isDefault: Bool = false) {
        self.name = name
        self.characterSet = characterSet
        self.isDefault = isDefault
    }

    public var id: String { characterSet.map { "\($0).\(name)" } ?? name }
}

public enum RoutineKind: String, Sendable, Hashable, Codable, CaseIterable {
    case function, procedure, aggregate, window, trigger
}

public struct RoutineInfo: Sendable, Hashable, Codable, Identifiable {
    public let name: String
    public let kind: RoutineKind
    /// Argument list as the server renders it, without the body.
    public let signature: String
    public let returnType: String?
    public let language: String?
    public let comment: String?

    public init(
        name: String,
        kind: RoutineKind,
        signature: String,
        returnType: String? = nil,
        language: String? = nil,
        comment: String? = nil
    ) {
        self.name = name
        self.kind = kind
        self.signature = signature
        self.returnType = returnType
        self.language = language
        self.comment = comment
    }

    public var id: String { "\(name)(\(signature))" }
}

/// Reads a server's catalogs.
///
/// Results are cached by `ConnectionSession` and invalidated explicitly — on the user's
/// Refresh, or after the app itself runs DDL. Nothing here refreshes on a timer.
public protocol SchemaIntrospector: Sendable {
    /// MySQL reports its schemas here; PostgreSQL reports databases, which need a
    /// reconnect to switch between.
    func databases() async throws -> [DatabaseInfo]
    func schemas(in database: String) async throws -> [SchemaInfo]
    /// Tables, views and materialized views, each tagged with its kind.
    func tables(in schema: SchemaRef) async throws -> [TableInfo]
    func columns(of table: TableRef) async throws -> [ColumnInfo]
    func indexes(of table: TableRef) async throws -> [IndexInfo]
    func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo]
    /// Primary-key column names in key order, or nil when the table has none.
    func primaryKey(of table: TableRef) async throws -> [String]?
    func routines(in schema: SchemaRef) async throws -> [RoutineInfo]
    func tableDDL(_ table: TableRef) async throws -> String
    /// Planner estimate. Never a `COUNT(*)`, which would scan the table.
    func approximateRowCount(_ table: TableRef) async throws -> Int64?
}

extension SchemaIntrospector {
    /// The columns that identify a row for editing: the primary key, or failing that
    /// the first unique index whose columns are all `NOT NULL` (SPEC §12.3).
    /// `nil` when the table has no usable identity, which makes the grid read-only.
    public func rowIdentity(of table: TableRef) async throws -> [String]? {
        if let primaryKey = try await primaryKey(of: table), !primaryKey.isEmpty { return primaryKey }
        let candidates = try await indexes(of: table)
            .filter { $0.isUnique && $0.isNullableFree && $0.predicate == nil && !$0.columns.isEmpty }
            .sorted { ($0.columns.count, $0.name) < ($1.columns.count, $1.name) }
        return candidates.first?.columns
    }
}
