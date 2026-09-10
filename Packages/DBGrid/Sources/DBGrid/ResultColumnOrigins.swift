import DBCore
import Foundation

/// Which table, and which column of it, a result column came from.
public struct ColumnOrigin: Sendable, Hashable {
    public let table: TableRef
    public let column: String

    public init(table: TableRef, column: String) {
        self.table = table
        self.column = column
    }
}

/// Works out where each column of a query result came from, so a JOIN's `customer_id`
/// can still be followed to its customer.
///
/// MySQL says outright which table and column each result column is (`tableOID` as
/// `database.table`, `sourceColumn`), aliases included. PostgreSQL reports only an OID
/// the driver does not surface, so there the column is matched by name against the
/// columns of the tables the statement reads: a name that exactly one of them has is
/// that table's. A name two tables share (`id` in a join) is left unresolved rather
/// than guessed, as is anything computed.
public enum ResultColumnOrigins {
    /// One table the statement reads and the names of its columns.
    public struct Source: Sendable, Hashable {
        public let table: TableRef
        public let columns: [String]

        public init(table: TableRef, columns: [String]) {
            self.table = table
            self.columns = columns
        }
    }

    /// The origin of each result column that could be settled, by column index.
    public static func resolve(columns: [ColumnMeta], sources: [Source]) -> [Int: ColumnOrigin] {
        guard !sources.isEmpty else { return [:] }
        // The names every source's columns are matched by, folded once.
        let lowered = sources.map { source in Set(source.columns.map { $0.lowercased() }) }
        var origins: [Int: ColumnOrigin] = [:]
        for (index, column) in columns.enumerated() {
            if let oid = column.tableOID,
                let sourceIndex = sources.firstIndex(where: { "\($0.table.schema).\($0.table.name)" == oid })
            {
                // The server named the table; the source column when it gave one, else the
                // result name when the table has it.
                let source = sources[sourceIndex]
                if let name = column.sourceColumn {
                    origins[index] = ColumnOrigin(table: source.table, column: name)
                } else if let name = source.columns.first(where: { $0.lowercased() == column.name.lowercased() }) {
                    origins[index] = ColumnOrigin(table: source.table, column: name)
                }
                continue
            }
            let name = column.name.lowercased()
            let owners = lowered.indices.filter { lowered[$0].contains(name) }
            guard owners.count == 1, let owner = owners.first else { continue }
            let source = sources[owner]
            guard let spelled = source.columns.first(where: { $0.lowercased() == name }) else { continue }
            origins[index] = ColumnOrigin(table: source.table, column: spelled)
        }
        return origins
    }
}
