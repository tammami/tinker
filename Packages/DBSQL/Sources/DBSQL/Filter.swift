import DBCore
import Foundation

/// The comparisons the grid's filter bar offers (SPEC §12.2).
public enum FilterOperator: String, Sendable, Hashable, Codable, CaseIterable {
    case equal, notEqual, lessThan, lessOrEqual, greaterThan, greaterOrEqual
    case contains, startsWith, endsWith
    case isNull, isNotNull
    case inList, between

    /// How the operator reads in the picker.
    public var symbol: String {
        switch self {
        case .equal: "="
        case .notEqual: "≠"
        case .lessThan: "<"
        case .lessOrEqual: "≤"
        case .greaterThan: ">"
        case .greaterOrEqual: "≥"
        case .contains: "contains"
        case .startsWith: "starts with"
        case .endsWith: "ends with"
        case .isNull: "is null"
        case .isNotNull: "is not null"
        case .inList: "in (…)"
        case .between: "between"
        }
    }

    /// How many values the operator needs from the user.
    public var operandCount: Int {
        switch self {
        case .isNull, .isNotNull: 0
        case .between: 2
        case .inList: -1        // one or more
        default: 1
        }
    }
}

/// One row of the filter bar.
public struct FilterRule: Sendable, Hashable, Codable, Identifiable {
    public let id: UUID
    public var column: String
    public var op: FilterOperator
    /// Operands in the order the operator expects them.
    public var values: [DBValue]

    public init(id: UUID = UUID(), column: String, op: FilterOperator, values: [DBValue] = []) {
        self.id = id
        self.column = column
        self.op = op
        self.values = values
    }
}

/// Turns filter rules into a `WHERE` clause with bound parameters.
///
/// Values are never interpolated into the SQL; the clause carries placeholders and the
/// values travel separately (SPEC §12.2).
public enum FilterCompiler {
    public struct Compiled: Sendable, Hashable {
        /// The clause without the `WHERE` keyword, or nil when no rule produced anything.
        public let whereClause: String?
        public let parameters: [DBValue]

        public init(whereClause: String?, parameters: [DBValue]) {
            self.whereClause = whereClause
            self.parameters = parameters
        }
    }

    /// Compiles `rules`, combined with `AND`.
    ///
    /// - Parameter startingParameterIndex: one-based index of the first placeholder, so a
    ///   caller that already bound values can continue the numbering.
    public static func compile(
        _ rules: [FilterRule],
        dialect: SQLDialect,
        startingParameterIndex: Int = 1
    ) -> Compiled {
        var parameters: [DBValue] = []
        var clauses: [String] = []
        var nextIndex = startingParameterIndex

        func placeholder(_ value: DBValue) -> String {
            parameters.append(value)
            defer { nextIndex += 1 }
            return SQLLiteral.placeholder(nextIndex, dialect: dialect)
        }

        for rule in rules {
            let column = Identifier.quote(rule.column, dialect: dialect)
            switch rule.op {
            case .isNull:
                clauses.append("\(column) IS NULL")
            case .isNotNull:
                clauses.append("\(column) IS NOT NULL")
            case .equal, .notEqual, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
                guard let value = rule.values.first else { continue }
                let comparison = switch rule.op {
                case .equal: "="
                case .notEqual: "<>"
                case .lessThan: "<"
                case .lessOrEqual: "<="
                case .greaterThan: ">"
                default: ">="
                }
                clauses.append("\(column) \(comparison) \(placeholder(value))")
            case .contains, .startsWith, .endsWith:
                guard let value = rule.values.first, let text = value.text else { continue }
                let escaped = escapeLikePattern(text)
                let pattern = switch rule.op {
                case .contains: "%\(escaped)%"
                case .startsWith: "\(escaped)%"
                default: "%\(escaped)"
                }
                // Casting to text lets the same filter work on numeric and date columns.
                let lhs = dialect == .postgresql ? "\(column)::text" : "CAST(\(column) AS CHAR)"
                clauses.append("\(lhs) LIKE \(placeholder(.string(pattern))) ESCAPE '\\'")
            case .inList:
                guard !rule.values.isEmpty else { continue }
                let items = rule.values.map { placeholder($0) }.joined(separator: ", ")
                clauses.append("\(column) IN (\(items))")
            case .between:
                guard rule.values.count >= 2 else { continue }
                let low = placeholder(rule.values[0])
                let high = placeholder(rule.values[1])
                clauses.append("\(column) BETWEEN \(low) AND \(high)")
            }
        }

        return Compiled(
            whereClause: clauses.isEmpty ? nil : clauses.joined(separator: " AND "),
            parameters: parameters
        )
    }

    /// Escapes the wildcards so a user's `%` or `_` matches itself.
    static func escapeLikePattern(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            if character == "%" || character == "_" || character == "\\" { output.append("\\") }
            output.append(character)
        }
        return output
    }
}
