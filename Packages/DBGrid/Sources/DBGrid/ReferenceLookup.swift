import DBCore
import DBSQL
import Foundation

/// Finds the rows a foreign key can point at, for the grid's reference picker.
///
/// A person editing `orders.customer_id` knows the customer's name, not its id, so the
/// search runs over a *label* column of the referenced table as well as the key, and the
/// query asks only for those columns: a page is fifty narrow rows, never the whole table.
public struct ReferenceLookup: Sendable {
    public static let pageSize = 50

    /// The label column choice for a referenced table.
    ///
    /// Picked by name when the table has a column that reads as one — `name`, `title`,
    /// `label`, `email`… — else the first text column that is not part of the key, else
    /// nothing, in which case the key alone is shown and searched.
    public static let preferredLabelNames = [
        "name", "title", "label", "full_name", "fullname", "display_name", "username", "user_name",
        "email", "code", "slug", "description", "nama", "judul",
    ]

    public struct Page: Sendable {
        public let columns: [ColumnMeta]
        public let rows: [[DBValue]]
        /// True when the table holds more matches than this page carries.
        public let hasMore: Bool
    }

    public let session: ConnectionSession
    public let key: ForeignKeyInfo
    public let dialect: SQLDialect

    public init(session: ConnectionSession, key: ForeignKeyInfo, dialect: SQLDialect) {
        self.session = session
        self.key = key
        self.dialect = dialect
    }

    /// The referenced table's columns, through the session's introspection cache.
    public func columns() async throws -> [ColumnInfo] {
        let table = key.referencedTable
        return try await session.introspection(.columns(table)) { try await $0.columns(of: table) }
    }

    /// Chooses the column that reads as a row's name, or nil when none does.
    public static func labelColumn(among columns: [ColumnInfo], keyColumns: [String]) -> String? {
        let candidates = columns.filter { !keyColumns.contains($0.name) }
        for preferred in preferredLabelNames {
            if let match = candidates.first(where: { $0.name.lowercased() == preferred }) { return match.name }
        }
        return candidates.first { $0.kind == .string }?.name
    }

    /// The columns a picker can label rows with: every non-key column, text ones first.
    public static func labelChoices(among columns: [ColumnInfo], keyColumns: [String]) -> [String] {
        let candidates = columns.filter { !keyColumns.contains($0.name) }
        return candidates.filter { $0.kind == .string }.map(\.name)
            + candidates.filter { $0.kind != .string }.map(\.name)
    }

    /// The page query: the key columns and the label, matching `text` anywhere in any of
    /// them, ordered by the label so paging is stable, one row past the page to learn
    /// whether there is more.
    public static func query(
        key: ForeignKeyInfo, label: String?, text: String, page: Int, dialect: SQLDialect
    ) -> (sql: String, parameters: [DBValue]) {
        let planner = PagePlanner(dialect: dialect, table: key.referencedTable)
        var columns = key.referencedColumns
        if let label, !columns.contains(label) { columns.append(label) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let rules = trimmed.isEmpty ? [] : [FilterRule.search(trimmed, in: columns)]
        let sort = [PagePlanner.SortTerm(column: label ?? key.referencedColumns.first ?? "", ascending: true)]
        // The planner offsets by its limit, which here is one more than a page; the offset
        // is written by hand so pages stay contiguous.
        var query = planner.pageQuery(
            columns: columns,
            filter: FilterCompiler.compile(rules, dialect: dialect),
            sort: sort,
            strategy: .offset,
            page: 0,
            limit: pageSize + 1
        )
        if page > 0 { query.sql += " OFFSET \(page * pageSize)" }
        return query
    }

    /// Runs one page of the search on a leased connection.
    public func search(_ text: String, label: String?, page: Int) async throws -> Page {
        let query = Self.query(key: key, label: label, text: text, page: page, dialect: dialect)
        let result = try await session.withLease { connection in
            try await connection.executeCollecting(query.sql, parameters: query.parameters)
        }
        let hasMore = result.rows.count > Self.pageSize
        return Page(columns: result.columns, rows: Array(result.rows.prefix(Self.pageSize)), hasMore: hasMore)
    }
}

// MARK: - Labels beside values

extension ReferenceLookup {
    /// How many keys one `IN (…)` carries; a page has at most a thousand rows anyway.
    public static let labelBatchSize = 200

    /// `SELECT key, label FROM referenced WHERE key IN (…)`, for the labels the grid shows
    /// beside foreign-key values. Single-column keys only.
    public static func labelsQuery(
        key: ForeignKeyInfo, label: String, keys: [DBValue], dialect: SQLDialect
    ) -> (sql: String, parameters: [DBValue])? {
        guard key.referencedColumns.count == 1, let keyColumn = key.referencedColumns.first, !keys.isEmpty else {
            return nil
        }
        let placeholders = keys.indices.map { SQLLiteral.placeholder($0 + 1, dialect: dialect) }.joined(separator: ", ")
        let sql =
            "SELECT \(Identifier.quote(keyColumn, dialect: dialect)), \(Identifier.quote(label, dialect: dialect)) "
            + "FROM \(Identifier.qualified(key.referencedTable, dialect: dialect)) "
            + "WHERE \(Identifier.quote(keyColumn, dialect: dialect)) IN (\(placeholders))"
        return (sql, keys)
    }

    /// The label of each key, by the key's text. Keys the table does not hold, and rows
    /// whose label is NULL, are absent from the result.
    public func labels(forKeys keys: [DBValue], label: String) async throws -> [String: String] {
        var found: [String: String] = [:]
        try await session.withLease { connection in
            var start = 0
            while start < keys.count {
                let batch = Array(keys[start ..< min(start + Self.labelBatchSize, keys.count)])
                start += Self.labelBatchSize
                guard let query = Self.labelsQuery(key: key, label: label, keys: batch, dialect: dialect) else { break }
                let result = try await connection.executeCollecting(query.sql, parameters: query.parameters)
                for row in result.rows where row.count >= 2 {
                    guard let keyText = row[0].text, !row[1].isNull, let text = row[1].text else { continue }
                    found[keyText] = text
                }
            }
        }
        return found
    }
}
