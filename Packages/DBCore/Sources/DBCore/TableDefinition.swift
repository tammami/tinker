import Foundation

/// A table's structure as the designer edits it (SPEC §15b).
///
/// The introspected `…Info` types describe what the server has; these describe what the
/// user wants. They are separate because an edit needs things a catalog read does not
/// carry — chiefly a stable identity per column and index, without which a rename is
/// indistinguishable from dropping one object and adding another.
public struct TableDefinition: Sendable, Hashable, Codable {
    public var ref: TableRef
    public var comment: String?
    public var columns: [ColumnDefinition]
    /// Primary-key column names in key order. Empty when the table has no primary key.
    public var primaryKey: [String]
    public var indexes: [IndexDefinition]
    public var foreignKeys: [ForeignKeyDefinition]
    public var checks: [CheckDefinition]
    public var triggers: [TriggerInfo]
    public var partitioning: PartitioningInfo?
    public var options: TableOptions

    public init(
        ref: TableRef,
        comment: String? = nil,
        columns: [ColumnDefinition] = [],
        primaryKey: [String] = [],
        indexes: [IndexDefinition] = [],
        foreignKeys: [ForeignKeyDefinition] = [],
        checks: [CheckDefinition] = [],
        triggers: [TriggerInfo] = [],
        partitioning: PartitioningInfo? = nil,
        options: TableOptions = TableOptions()
    ) {
        self.ref = ref
        self.comment = comment
        self.columns = columns
        self.primaryKey = primaryKey
        self.indexes = indexes
        self.foreignKeys = foreignKeys
        self.checks = checks
        self.triggers = triggers
        self.partitioning = partitioning
        self.options = options
    }

    public func column(named name: String) -> ColumnDefinition? {
        columns.first { $0.name == name }
    }
}

/// Whole-table settings. Which of these mean anything depends on the engine.
public struct TableOptions: Sendable, Hashable, Codable {
    /// MySQL storage engine — InnoDB, MyISAM.
    public var engine: String?
    /// MySQL default character set.
    public var characterSet: String?
    /// MySQL default collation.
    public var collation: String?
    /// PostgreSQL tablespace.
    public var tablespace: String?

    public init(
        engine: String? = nil,
        characterSet: String? = nil,
        collation: String? = nil,
        tablespace: String? = nil
    ) {
        self.engine = engine
        self.characterSet = characterSet
        self.collation = collation
        self.tablespace = tablespace
    }
}

/// One column being edited.
///
/// `id` is the column's identity for the diff and never leaves the app: two definitions
/// sharing an `id` are the same column, so a changed `name` is a rename.
public struct ColumnDefinition: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    /// The type exactly as it will be written — `varchar(255)`, `numeric(12,2)`.
    /// Kept as text rather than parsed: every server spells its own types, and a
    /// round trip through a parsed model is where precision goes missing.
    public var type: String
    public var isNullable: Bool
    /// Default expression text, unquoted and unparsed. `nil` means no default.
    public var defaultExpression: String?
    /// PostgreSQL identity, MySQL `AUTO_INCREMENT`.
    public var isAutoIncrement: Bool
    /// A generated column's expression. `nil` for an ordinary column.
    public var generatedExpression: String?
    /// MySQL stores a generated column when true, computes it on read when false.
    public var isGeneratedStored: Bool
    public var characterSet: String?
    public var collation: String?
    public var comment: String?
    /// The members of a PostgreSQL enum type, read from the catalog for display. MySQL
    /// carries its members inside `type` (`enum('a','b')`), so this stays nil there.
    /// Not part of the definition: the members belong to the type, not the column.
    public var enumLabels: [String]?

    public init(
        id: UUID = UUID(),
        name: String,
        type: String,
        isNullable: Bool = true,
        defaultExpression: String? = nil,
        isAutoIncrement: Bool = false,
        generatedExpression: String? = nil,
        isGeneratedStored: Bool = true,
        characterSet: String? = nil,
        collation: String? = nil,
        comment: String? = nil,
        enumLabels: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.isNullable = isNullable
        self.defaultExpression = defaultExpression
        self.isAutoIncrement = isAutoIncrement
        self.generatedExpression = generatedExpression
        self.isGeneratedStored = isGeneratedStored
        self.characterSet = characterSet
        self.collation = collation
        self.comment = comment
        self.enumLabels = enumLabels
    }

    /// Everything about the column except its name, which is what tells a rename from a
    /// change of definition.
    public func matchesDefinition(of other: ColumnDefinition) -> Bool {
        type == other.type
            && isNullable == other.isNullable
            && defaultExpression == other.defaultExpression
            && isAutoIncrement == other.isAutoIncrement
            && generatedExpression == other.generatedExpression
            && isGeneratedStored == other.isGeneratedStored
            && characterSet == other.characterSet
            && collation == other.collation
    }
}

/// One column's place in an index.
public struct IndexColumn: Sendable, Hashable, Codable {
    public var name: String
    public var isDescending: Bool
    /// PostgreSQL operator class, e.g. `gin_trgm_ops`. `nil` for the default.
    public var operatorClass: String?
    /// MySQL prefix length for a text column, e.g. `name(20)`.
    public var prefixLength: Int?

    public init(
        name: String,
        isDescending: Bool = false,
        operatorClass: String? = nil,
        prefixLength: Int? = nil
    ) {
        self.name = name
        self.isDescending = isDescending
        self.operatorClass = operatorClass
        self.prefixLength = prefixLength
    }
}

/// One index being edited. The primary key is not an index here; it lives on the
/// definition's `primaryKey`, because the user sets it by marking columns.
public struct IndexDefinition: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var columns: [IndexColumn]
    public var isUnique: Bool
    /// btree, hash, gin, gist, brin, spgist (PG); btree, hash, fulltext, spatial (MySQL).
    /// `nil` takes the server's default.
    public var method: String?
    /// PostgreSQL partial-index predicate.
    public var predicate: String?
    public var comment: String?

    public init(
        id: UUID = UUID(),
        name: String,
        columns: [IndexColumn],
        isUnique: Bool = false,
        method: String? = nil,
        predicate: String? = nil,
        comment: String? = nil
    ) {
        self.id = id
        self.name = name
        self.columns = columns
        self.isUnique = isUnique
        self.method = method
        self.predicate = predicate
        self.comment = comment
    }

    /// Everything an index is made of except its name: a change to any of it needs the
    /// index dropped and rebuilt, where a change of name alone may not.
    public func matchesDefinition(of other: IndexDefinition) -> Bool {
        columns == other.columns
            && isUnique == other.isUnique
            && method == other.method
            && predicate == other.predicate
    }
}

public struct ForeignKeyDefinition: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var columns: [String]
    public var referencedTable: TableRef
    public var referencedColumns: [String]
    public var onUpdate: ForeignKeyAction
    public var onDelete: ForeignKeyAction
    /// PostgreSQL `DEFERRABLE INITIALLY DEFERRED`.
    public var isDeferrable: Bool
    public var isInitiallyDeferred: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        columns: [String],
        referencedTable: TableRef,
        referencedColumns: [String],
        onUpdate: ForeignKeyAction = .noAction,
        onDelete: ForeignKeyAction = .noAction,
        isDeferrable: Bool = false,
        isInitiallyDeferred: Bool = false
    ) {
        self.id = id
        self.name = name
        self.columns = columns
        self.referencedTable = referencedTable
        self.referencedColumns = referencedColumns
        self.onUpdate = onUpdate
        self.onDelete = onDelete
        self.isDeferrable = isDeferrable
        self.isInitiallyDeferred = isInitiallyDeferred
    }

    public func matchesDefinition(of other: ForeignKeyDefinition) -> Bool {
        columns == other.columns
            && referencedTable == other.referencedTable
            && referencedColumns == other.referencedColumns
            && onUpdate == other.onUpdate
            && onDelete == other.onDelete
            && isDeferrable == other.isDeferrable
            && isInitiallyDeferred == other.isInitiallyDeferred
    }
}

public struct CheckDefinition: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var name: String
    public var expression: String

    public init(id: UUID = UUID(), name: String, expression: String) {
        self.id = id
        self.name = name
        self.expression = expression
    }
}

// MARK: - Reading a definition back from the catalog

extension TableDefinition {
    /// Builds the definition the designer starts from out of what introspection read.
    ///
    /// The primary key arrives as its own list rather than as an index, and the index that
    /// implements it is dropped from `indexes`: the user sets a primary key by marking
    /// columns, and showing its index beside the others invites editing the same thing
    /// twice.
    public init(
        table: TableRef,
        info: TableInfo?,
        columns columnInfos: [ColumnInfo],
        primaryKey: [String],
        indexes indexInfos: [IndexInfo],
        foreignKeys foreignKeyInfos: [ForeignKeyInfo],
        checks checkInfos: [CheckConstraintInfo] = [],
        triggers: [TriggerInfo] = [],
        partitioning: PartitioningInfo? = nil,
        options: TableOptions = TableOptions()
    ) {
        self.init(
            ref: table,
            comment: info?.comment,
            columns: columnInfos.map { column in
                ColumnDefinition(
                    name: column.name,
                    type: column.nativeType,
                    isNullable: column.isNullable,
                    defaultExpression: column.defaultExpression,
                    isAutoIncrement: column.isAutoIncrement,
                    generatedExpression: nil,
                    characterSet: column.characterSet,
                    collation: column.collation,
                    comment: column.comment,
                    enumLabels: column.enumLabels
                )
            },
            primaryKey: primaryKey,
            indexes:
                indexInfos
                .filter { !$0.isPrimary }
                .map { index in
                    IndexDefinition(
                        name: index.name,
                        columns: index.columns.map { IndexColumn(name: $0) },
                        isUnique: index.isUnique,
                        method: index.method,
                        predicate: index.predicate
                    )
                },
            foreignKeys: foreignKeyInfos.map { key in
                ForeignKeyDefinition(
                    name: key.name,
                    columns: key.columns,
                    referencedTable: key.referencedTable,
                    referencedColumns: key.referencedColumns,
                    onUpdate: key.onUpdate,
                    onDelete: key.onDelete
                )
            },
            checks: checkInfos.map { CheckDefinition(name: $0.name, expression: $0.expression) },
            triggers: triggers,
            partitioning: partitioning,
            options: options
        )
    }
}
