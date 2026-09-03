import DBCore
import Foundation

/// How a Table tab fetches its next page.
public enum PagingStrategy: Sendable, Hashable {
    /// `LIMIT n OFFSET m`. Correct for any table, but the server re-scans the skipped
    /// rows, so it degrades as the offset grows.
    case offset
    /// `WHERE key > last ORDER BY key LIMIT n`. Constant cost at any depth, but only
    /// usable with a single-column ordered key and the table's own ordering.
    case keyset(column: String)

    public var describesKeyset: Bool { if case .keyset = self { true } else { false } }

    /// Text for the status-bar tooltip, so the user can see which strategy is in play.
    public var explanation: String {
        switch self {
        case .offset:
            "Paging with LIMIT/OFFSET"
        case let .keyset(column):
            "Paging on \(column) with a keyset cursor, which stays fast at any depth"
        }
    }
}

/// Chooses the paging strategy and builds the page query for a Table tab (SPEC §12.1).
public struct PagePlanner: Sendable {
    /// Rows per page.
    public static let pageSize = 1_000
    /// `OFFSET` is used up to this page; deeper pages switch to a keyset cursor when one
    /// is available, because the server's cost of skipping rows grows with the offset.
    public static let offsetPageLimit = 50

    public let dialect: SQLDialect
    public let table: TableRef

    public init(dialect: SQLDialect, table: TableRef) {
        self.dialect = dialect
        self.table = table
    }

    /// One column of an `ORDER BY`.
    public struct SortTerm: Sendable, Hashable, Codable {
        public let column: String
        public let ascending: Bool

        public init(column: String, ascending: Bool) {
            self.column = column
            self.ascending = ascending
        }
    }

    /// Picks the strategy for the page about to be fetched.
    ///
    /// A keyset cursor needs a single-column key that the server can order, the table's
    /// natural order (no user sort), and a page deep enough for `OFFSET` to hurt.
    public func strategy(
        page: Int,
        userSort: [SortTerm],
        identityColumns: [String],
        identityKind: DBValueKind?
    ) -> PagingStrategy {
        guard userSort.isEmpty,
              page > Self.offsetPageLimit,
              identityColumns.count == 1,
              let column = identityColumns.first,
              let kind = identityKind,
              kind == .int || kind == .uint
        else { return .offset }
        return .keyset(column: column)
    }

    /// Builds the query for one page.
    ///
    /// - Parameters:
    ///   - columns: the columns to select, or empty for `*`.
    ///   - filter: compiled filter clause and its parameters; its placeholders must have
    ///     been numbered from 1.
    ///   - keysetAnchor: the key value of the last row already loaded, for a keyset page.
    /// - Returns: the SQL and the parameters, in placeholder order.
    public func pageQuery(
        columns: [String] = [],
        filter: FilterCompiler.Compiled = .init(whereClause: nil, parameters: []),
        sort: [SortTerm] = [],
        strategy: PagingStrategy,
        page: Int,
        keysetAnchor: DBValue? = nil,
        limit: Int = PagePlanner.pageSize
    ) -> (sql: String, parameters: [DBValue]) {
        var parameters = filter.parameters
        var predicates: [String] = []
        if let clause = filter.whereClause { predicates.append(clause) }

        var orderTerms = sort
        if case let .keyset(column) = strategy {
            if let anchor = keysetAnchor {
                let placeholder = SQLLiteral.placeholder(parameters.count + 1, dialect: dialect)
                predicates.append("\(Identifier.quote(column, dialect: dialect)) > \(placeholder)")
                parameters.append(anchor)
            }
            orderTerms = [SortTerm(column: column, ascending: true)]
        }

        let selectList = columns.isEmpty
            ? "*"
            : columns.map { Identifier.quote($0, dialect: dialect) }.joined(separator: ", ")
        var sql = "SELECT \(selectList) FROM \(Identifier.qualified(table, dialect: dialect))"
        if !predicates.isEmpty { sql += " WHERE \(predicates.joined(separator: " AND "))" }
        if !orderTerms.isEmpty {
            let order = orderTerms
                .map { "\(Identifier.quote($0.column, dialect: dialect)) \($0.ascending ? "ASC" : "DESC")" }
                .joined(separator: ", ")
            sql += " ORDER BY \(order)"
        }
        sql += " LIMIT \(limit)"
        if case .offset = strategy, page > 0 { sql += " OFFSET \(page * limit)" }
        return (sql, parameters)
    }

    /// `SELECT COUNT(*)` for the current filter, used when the user asks for an exact count.
    public func countQuery(
        filter: FilterCompiler.Compiled = .init(whereClause: nil, parameters: [])
    ) -> (sql: String, parameters: [DBValue]) {
        var sql = "SELECT COUNT(*) FROM \(Identifier.qualified(table, dialect: dialect))"
        if let clause = filter.whereClause { sql += " WHERE \(clause)" }
        return (sql, filter.parameters)
    }
}
