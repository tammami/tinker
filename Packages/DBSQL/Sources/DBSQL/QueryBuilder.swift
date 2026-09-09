import DBCore
import Foundation

/// The visual query builder's model: tables on a canvas, the joins between them, the
/// fields chosen, and the clauses that shape the result. `sql(dialect:)` renders it.
///
/// Every identifier is quoted per dialect and every literal condition is rendered through
/// `SQLLiteral`, so what the canvas describes is exactly what the server receives.
public struct QueryBuilderModel: Sendable, Hashable, Codable {
    /// A table placed on the canvas, with the alias the generated SQL refers to it by.
    public struct Table: Sendable, Hashable, Codable, Identifiable {
        public var id: UUID
        public var ref: TableRef
        public var alias: String
        /// Where the card sits on the canvas, in points.
        public var x: Double
        public var y: Double

        public init(id: UUID = UUID(), ref: TableRef, alias: String, x: Double = 40, y: Double = 40) {
            self.id = id
            self.ref = ref
            self.alias = alias
            self.x = x
            self.y = y
        }
    }

    public enum JoinKind: String, Sendable, Hashable, Codable, CaseIterable {
        case inner = "INNER JOIN"
        case left = "LEFT JOIN"
        case right = "RIGHT JOIN"
        case full = "FULL JOIN"
        case cross = "CROSS JOIN"

        public var title: String {
            switch self {
            case .inner: "Inner"
            case .left: "Left"
            case .right: "Right"
            case .full: "Full"
            case .cross: "Cross"
            }
        }
    }

    /// A line between two columns on the canvas.
    public struct Join: Sendable, Hashable, Codable, Identifiable {
        public var id: UUID
        public var kind: JoinKind
        public var leftTable: UUID
        public var leftColumn: String
        public var rightTable: UUID
        public var rightColumn: String

        public init(
            id: UUID = UUID(), kind: JoinKind = .inner,
            leftTable: UUID, leftColumn: String, rightTable: UUID, rightColumn: String
        ) {
            self.id = id
            self.kind = kind
            self.leftTable = leftTable
            self.leftColumn = leftColumn
            self.rightTable = rightTable
            self.rightColumn = rightColumn
        }
    }

    public enum Aggregate: String, Sendable, Hashable, Codable, CaseIterable {
        case none = ""
        case count = "COUNT"
        case sum = "SUM"
        case avg = "AVG"
        case min = "MIN"
        case max = "MAX"

        public var title: String { self == .none ? "None" : rawValue }
    }

    /// One item of the SELECT list: a column, or `*` for a whole table.
    public struct Field: Sendable, Hashable, Codable, Identifiable {
        public var id: UUID
        public var table: UUID
        /// `*` selects every column of the table.
        public var column: String
        public var aggregate: Aggregate
        public var alias: String?

        public init(id: UUID = UUID(), table: UUID, column: String, aggregate: Aggregate = .none, alias: String? = nil)
        {
            self.id = id
            self.table = table
            self.column = column
            self.aggregate = aggregate
            self.alias = alias
        }

        public var isStar: Bool { column == "*" }
    }

    /// One WHERE or HAVING condition. Values are literals rendered per dialect.
    public struct Condition: Sendable, Hashable, Codable, Identifiable {
        public var id: UUID
        public var table: UUID
        public var column: String
        public var op: FilterOperator
        public var values: [DBValue]
        /// `AND` or `OR` with the condition before it. Ignored on the first.
        public var conjunction: Conjunction

        public enum Conjunction: String, Sendable, Hashable, Codable, CaseIterable {
            case and = "AND"
            case or = "OR"
        }

        public init(
            id: UUID = UUID(), table: UUID, column: String, op: FilterOperator = .equal,
            values: [DBValue] = [.string("")], conjunction: Conjunction = .and
        ) {
            self.id = id
            self.table = table
            self.column = column
            self.op = op
            self.values = values
            self.conjunction = conjunction
        }
    }

    public struct Ordering: Sendable, Hashable, Codable, Identifiable {
        public var id: UUID
        public var table: UUID
        public var column: String
        public var ascending: Bool

        public init(id: UUID = UUID(), table: UUID, column: String, ascending: Bool = true) {
            self.id = id
            self.table = table
            self.column = column
            self.ascending = ascending
        }
    }

    public var tables: [Table] = []
    public var joins: [Join] = []
    public var fields: [Field] = []
    public var conditions: [Condition] = []
    public var groupBy: [Field] = []
    public var having: [Condition] = []
    public var orderBy: [Ordering] = []
    public var limit: Int?
    public var offset: Int?
    public var isDistinct = false
    /// The columns of each placed table, when known. With them, `*` over a join is spelt
    /// out column by column and clashing names get aliases, so the result — and a view
    /// made from it — never has two columns called `id`.
    public var columns: [UUID: [String]] = [:]

    public init() {}

    public func table(_ id: UUID) -> Table? { tables.first { $0.id == id } }

    /// An alias no other table on the canvas uses: `orders`, then `orders_2`, …
    public func uniqueAlias(for ref: TableRef) -> String {
        let base = ref.name
        var candidate = base
        var counter = 2
        while tables.contains(where: { $0.alias == candidate }) {
            candidate = "\(base)_\(counter)"
            counter += 1
        }
        return candidate
    }

    /// Adds a table and returns its id.
    @discardableResult
    public mutating func add(_ ref: TableRef, at point: (Double, Double) = (40, 40)) -> UUID {
        let table = Table(ref: ref, alias: uniqueAlias(for: ref), x: point.0, y: point.1)
        tables.append(table)
        return table.id
    }

    /// Removes a table and everything that referred to it.
    public mutating func remove(table id: UUID) {
        tables.removeAll { $0.id == id }
        joins.removeAll { $0.leftTable == id || $0.rightTable == id }
        fields.removeAll { $0.table == id }
        conditions.removeAll { $0.table == id }
        groupBy.removeAll { $0.table == id }
        having.removeAll { $0.table == id }
        orderBy.removeAll { $0.table == id }
    }

    /// Whether a join already links these two columns, in either direction.
    public func hasJoin(_ a: UUID, _ aColumn: String, _ b: UUID, _ bColumn: String) -> Bool {
        joins.contains {
            ($0.leftTable == a && $0.leftColumn == aColumn && $0.rightTable == b && $0.rightColumn == bColumn)
                || ($0.leftTable == b && $0.leftColumn == bColumn && $0.rightTable == a && $0.rightColumn == aColumn)
        }
    }

    /// Adds joins for every foreign key between `newTable` and the tables already placed,
    /// which is what makes dropping a related table onto the canvas do the obvious thing.
    public mutating func addJoins(fromForeignKeys keys: [ForeignKeyInfo], of newTable: UUID) {
        guard let placed = table(newTable) else { return }
        for key in keys {
            guard key.columns.count == 1, key.referencedColumns.count == 1,
                let target = tables.first(where: { $0.id != newTable && $0.ref == key.referencedTable })
            else { continue }
            if !hasJoin(newTable, key.columns[0], target.id, key.referencedColumns[0]) {
                joins.append(
                    Join(
                        leftTable: target.id, leftColumn: key.referencedColumns[0],
                        rightTable: newTable, rightColumn: key.columns[0]
                    ))
            }
        }
        _ = placed
    }

    /// Joins for foreign keys that point from an already-placed table at `newTable`.
    public mutating func addJoins(
        toNewTable newTable: UUID, fromPlacedForeignKeys keys: [(table: UUID, key: ForeignKeyInfo)]
    ) {
        guard let placed = table(newTable) else { return }
        for (source, key) in keys {
            guard key.columns.count == 1, key.referencedColumns.count == 1,
                key.referencedTable == placed.ref, source != newTable
            else { continue }
            if !hasJoin(source, key.columns[0], newTable, key.referencedColumns[0]) {
                joins.append(
                    Join(
                        leftTable: newTable, leftColumn: key.referencedColumns[0],
                        rightTable: source, rightColumn: key.columns[0]
                    ))
            }
        }
    }

    // MARK: - SQL

    /// The statement the canvas describes, or nil while no table is placed.
    public func sql(dialect: SQLDialect) -> String? {
        guard let first = tables.first else { return nil }
        func quote(_ name: String) -> String { Identifier.quote(name, dialect: dialect) }
        func qualified(_ field: UUID, _ column: String) -> String {
            let alias = table(field)?.alias ?? "?"
            return column == "*" ? "\(quote(alias)).*" : "\(quote(alias)).\(quote(column))"
        }

        var lines: [String] = []

        // SELECT
        let selectItems: [String] =
            expandedFields().isEmpty
            ? ["*"]
            : expandedFields().map { field in
                var expression = qualified(field.table, field.column)
                if field.aggregate != .none {
                    expression = "\(field.aggregate.rawValue)(\(field.isStar ? "*" : expression))"
                }
                if let alias = field.alias, !alias.isEmpty {
                    expression += " AS \(quote(alias))"
                }
                return expression
            }
        lines.append("SELECT" + (isDistinct ? " DISTINCT" : ""))
        lines.append("    " + selectItems.joined(separator: ",\n    "))

        // FROM: the first table, then every joined table in the order it can be reached.
        func fromClause(_ table: Table) -> String {
            let name = Identifier.qualified(table.ref, dialect: dialect)
            return table.alias == table.ref.name ? name : "\(name) AS \(quote(table.alias))"
        }
        lines.append("FROM \(fromClause(first))")
        var placed: Set<UUID> = [first.id]
        var remainingJoins = joins
        var progressed = true
        while progressed, !remainingJoins.isEmpty {
            progressed = false
            for (index, join) in remainingJoins.enumerated() {
                let leftPlaced = placed.contains(join.leftTable)
                let rightPlaced = placed.contains(join.rightTable)
                guard leftPlaced != rightPlaced,
                    let newTable = table(leftPlaced ? join.rightTable : join.leftTable)
                else { continue }
                if join.kind == .cross {
                    lines.append("CROSS JOIN \(fromClause(newTable))")
                } else {
                    lines.append(
                        "\(join.kind.rawValue) \(fromClause(newTable))\n    ON \(qualified(join.leftTable, join.leftColumn)) = \(qualified(join.rightTable, join.rightColumn))"
                    )
                }
                placed.insert(newTable.id)
                remainingJoins.remove(at: index)
                progressed = true
                break
            }
        }
        // Tables with no join to anything placed become a plain cross product.
        for table in tables where !placed.contains(table.id) {
            lines.append("CROSS JOIN \(fromClause(table))")
            placed.insert(table.id)
        }

        if let whereClause = Self.render(conditions, dialect: dialect, qualified: qualified) {
            lines.append("WHERE \(whereClause)")
        }
        if !groupBy.isEmpty {
            lines.append("GROUP BY " + groupBy.map { qualified($0.table, $0.column) }.joined(separator: ", "))
        }
        if let havingClause = Self.render(having, dialect: dialect, qualified: qualified) {
            lines.append("HAVING \(havingClause)")
        }
        if !orderBy.isEmpty {
            lines.append(
                "ORDER BY "
                    + orderBy.map {
                        qualified($0.table, $0.column) + ($0.ascending ? " ASC" : " DESC")
                    }.joined(separator: ", "))
        }
        if let limit, limit > 0 {
            lines.append("LIMIT \(limit)")
            if let offset, offset > 0 { lines.append("OFFSET \(offset)") }
        }
        return lines.joined(separator: "\n")
    }

    /// The SELECT list with `*` spelt out and clashing names aliased, where the columns
    /// are known. With one table, or no column knowledge, the fields pass through as is.
    public func expandedFields() -> [Field] {
        let base: [Field]
        if fields.isEmpty {
            // Nothing chosen: every column of every table, in canvas order.
            guard tables.count > 1, tables.allSatisfy({ columns[$0.id] != nil }) else { return [] }
            base = tables.map { Field(table: $0.id, column: "*") }
        } else {
            base = fields
        }
        guard tables.count > 1 else { return base }

        var expanded: [Field] = []
        for field in base {
            if field.isStar, field.aggregate == .none, let names = columns[field.table] {
                expanded.append(contentsOf: names.map { Field(table: field.table, column: $0) })
            } else {
                expanded.append(field)
            }
        }
        // A name that appears twice gets `alias_column`, unless the person named it already.
        var counts: [String: Int] = [:]
        for field in expanded where field.aggregate == .none && !field.isStar {
            counts[field.alias ?? field.column, default: 0] += 1
        }
        return expanded.map { field in
            guard field.aggregate == .none, !field.isStar, field.alias == nil,
                counts[field.column, default: 0] > 1,
                let alias = table(field.table)?.alias
            else { return field }
            var renamed = field
            renamed.alias = "\(alias)_\(field.column)"
            return renamed
        }
    }

    /// `CREATE VIEW name AS <select>`; `OR REPLACE` so re-running after a change works.
    /// SQLite has no `OR REPLACE` for views, so it drops the old one first.
    public func createViewSQL(name: TableRef, dialect: SQLDialect) -> String? {
        guard let select = sql(dialect: dialect) else { return nil }
        let qualified = Identifier.qualified(name, dialect: dialect)
        if dialect == .sqlite {
            return "DROP VIEW IF EXISTS \(qualified);\nCREATE VIEW \(qualified) AS\n\(select)"
        }
        return "CREATE OR REPLACE VIEW \(qualified) AS\n\(select)"
    }

    private static func render(
        _ conditions: [Condition], dialect: SQLDialect,
        qualified: (UUID, String) -> String
    ) -> String? {
        var parts: [String] = []
        for condition in conditions {
            let column = qualified(condition.table, condition.column)
            let text: String?
            switch condition.op {
            case .isNull: text = "\(column) IS NULL"
            case .isNotNull: text = "\(column) IS NOT NULL"
            case .equal, .notEqual, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
                guard let value = condition.values.first, !(value.text ?? "").isEmpty else { text = nil; break }
                let symbol: String =
                    switch condition.op {
                    case .equal: "="
                    case .notEqual: "<>"
                    case .lessThan: "<"
                    case .lessOrEqual: "<="
                    case .greaterThan: ">"
                    default: ">="
                    }
                text = "\(column) \(symbol) \(value.sqlLiteral(dialect: dialect))"
            case .contains, .startsWith, .endsWith, .anyContains:
                guard let raw = condition.values.first?.text, !raw.isEmpty else { text = nil; break }
                let escaped = FilterCompiler.escapeLikePattern(raw)
                let pattern: String =
                    switch condition.op {
                    case .startsWith: "\(escaped)%"
                    case .endsWith: "%\(escaped)"
                    default: "%\(escaped)%"
                    }
                let lhs = SQLLiteral.textCast(column, dialect: dialect)
                text = "\(lhs) LIKE \(DBValue.string(pattern).sqlLiteral(dialect: dialect)) ESCAPE '!'"
            case .inList:
                let items = condition.values.filter { !($0.text ?? "").isEmpty }
                guard !items.isEmpty else { text = nil; break }
                text = "\(column) IN (\(items.map { $0.sqlLiteral(dialect: dialect) }.joined(separator: ", ")))"
            case .between:
                guard condition.values.count >= 2 else { text = nil; break }
                text =
                    "\(column) BETWEEN \(condition.values[0].sqlLiteral(dialect: dialect)) AND \(condition.values[1].sqlLiteral(dialect: dialect))"
            }
            guard let text else { continue }
            if parts.isEmpty {
                parts.append(text)
            } else {
                parts.append("\(condition.conjunction.rawValue) \(text)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n    ")
    }
}
