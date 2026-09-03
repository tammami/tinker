import Foundation

/// Description of one column in a result set.
public struct ColumnMeta: Sendable, Hashable, Identifiable, Codable {
    /// Zero-based ordinal within the result set.
    public let id: Int
    public let name: String
    /// Driver-specific identity of the table this column came from, when the server
    /// reports one. PostgreSQL: the relation OID. `nil` for computed columns.
    public let tableOID: String?
    /// The server's own spelling of the type, e.g. `int4` or `varchar(255)`.
    public let nativeTypeName: String
    public let kind: DBValueKind
    public let isNullable: Bool?
    /// `nil` when the result set alone cannot say; introspection fills it in.
    public let isPrimaryKey: Bool?

    public init(
        id: Int,
        name: String,
        tableOID: String? = nil,
        nativeTypeName: String,
        kind: DBValueKind,
        isNullable: Bool? = nil,
        isPrimaryKey: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.tableOID = tableOID
        self.nativeTypeName = nativeTypeName
        self.kind = kind
        self.isNullable = isNullable
        self.isPrimaryKey = isPrimaryKey
    }
}

/// A contiguous run of rows, positioned absolutely within its result set.
public struct RowBatch: Sendable, Hashable {
    public let rows: [[DBValue]]
    /// Absolute index of `rows[0]` within the whole result set.
    public let startIndex: Int

    public init(rows: [[DBValue]], startIndex: Int) {
        self.rows = rows
        self.startIndex = startIndex
    }

    public var isEmpty: Bool { rows.isEmpty }
    public var count: Int { rows.count }
}

/// What a statement produced, delivered once the statement finishes.
public struct QueryCompletion: Sendable, Hashable {
    public let affectedRows: Int64?
    /// MySQL only; PostgreSQL reports generated keys through `RETURNING`.
    public let lastInsertID: Int64?
    /// The server's command tag, e.g. `SELECT 42` or `UPDATE 3`.
    public let serverTag: String?
    /// Server-reported execution time where the protocol provides one.
    public let durationServer: Duration?
    /// Wall-clock time from sending the statement to the last row arriving.
    public let durationTotal: Duration
    /// `RAISE NOTICE` and equivalent messages, verbatim.
    public let notices: [String]

    public init(
        affectedRows: Int64? = nil,
        lastInsertID: Int64? = nil,
        serverTag: String? = nil,
        durationServer: Duration? = nil,
        durationTotal: Duration,
        notices: [String] = []
    ) {
        self.affectedRows = affectedRows
        self.lastInsertID = lastInsertID
        self.serverTag = serverTag
        self.durationServer = durationServer
        self.durationTotal = durationTotal
        self.notices = notices
    }
}

/// One step in a statement's result stream.
///
/// Order is guaranteed: `.columns` at most once and always before any `.rows`,
/// then zero or more `.rows`, then exactly one `.complete`.
public enum QueryEvent: Sendable, Hashable {
    case columns([ColumnMeta])
    case rows(RowBatch)
    case complete(QueryCompletion)
}

/// Row-batching thresholds for result streams: a batch is emitted at whichever
/// limit is reached first (SPEC §4).
public enum RowBatching {
    public static let maxRows = 500
    public static let maxBytes = 1_048_576
}
