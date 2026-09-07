import DBCore
import Foundation

/// The comparisons the grid's filter bar offers (SPEC §12.2).
public enum FilterOperator: String, Sendable, Hashable, Codable, CaseIterable {
    case equal, notEqual, lessThan, lessOrEqual, greaterThan, greaterOrEqual
    case contains, startsWith, endsWith
    case isNull, isNotNull
    case inList, between
    /// Matches when any of the rule's `targets` contains the text: the quick search.
    case anyContains

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
        case .anyContains: "any column contains"
        }
    }

    /// How many values the operator needs from the user.
    public var operandCount: Int {
        switch self {
        case .isNull, .isNotNull: 0
        case .between: 2
        case .inList: -1  // one or more
        default: 1
        }
    }
}

/// How a filter row joins the row above it.
public enum FilterConjunction: String, Sendable, Hashable, Codable, CaseIterable {
    case and, or

    /// The keyword as SQL spells it.
    public var keyword: String {
        switch self {
        case .and: "AND"
        case .or: "OR"
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
    /// For `.anyContains`, the columns searched. Other operators use `column` alone.
    public var targets: [String]?
    /// How this row joins the one before it; the first row's is not used.
    public var conjunction: FilterConjunction

    public init(
        id: UUID = UUID(),
        column: String,
        op: FilterOperator,
        values: [DBValue] = [],
        targets: [String]? = nil,
        conjunction: FilterConjunction = .and
    ) {
        self.id = id
        self.column = column
        self.op = op
        self.values = values
        self.targets = targets
        self.conjunction = conjunction
    }

    // Rules saved before conjunctions existed have none; they were all AND.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        column = try container.decode(String.self, forKey: .column)
        op = try container.decode(FilterOperator.self, forKey: .op)
        values = try container.decodeIfPresent([DBValue].self, forKey: .values) ?? []
        targets = try container.decodeIfPresent([String].self, forKey: .targets)
        conjunction = try container.decodeIfPresent(FilterConjunction.self, forKey: .conjunction) ?? .and
    }

    /// The quick-search rule: `text` anywhere in any of `columns`.
    public static func search(_ text: String, in columns: [String]) -> FilterRule {
        FilterRule(column: columns.first ?? "", op: .anyContains, values: [.string(text)], targets: columns)
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

    /// Compiles `rules` into one clause.
    ///
    /// Each row joins the one before it with its own `AND` or `OR`. `OR` starts a new
    /// group and the groups are parenthesised, so `a AND b OR c` means `(a AND b) OR (c)`
    /// and never depends on the reader knowing SQL's precedence. The quick search
    /// (`.anyContains`) always narrows the whole result: `(…) AND (search)`.
    ///
    /// - Parameter startingParameterIndex: one-based index of the first placeholder, so a
    ///   caller that already bound values can continue the numbering.
    public static func compile(
        _ rules: [FilterRule],
        dialect: SQLDialect,
        startingParameterIndex: Int = 1
    ) -> Compiled {
        var parameters: [DBValue] = []
        /// The user's rows, grouped: a new group starts at every `OR`.
        var groups: [[String]] = []
        /// Quick-search clauses, applied over every group.
        var searches: [String] = []
        var nextIndex = startingParameterIndex

        func add(_ clause: String, rule: FilterRule) {
            if rule.op == .anyContains {
                searches.append(clause)
            } else if groups.isEmpty || rule.conjunction == .or {
                groups.append([clause])
            } else {
                groups[groups.count - 1].append(clause)
            }
        }

        func placeholder(_ value: DBValue) -> String {
            parameters.append(value)
            defer { nextIndex += 1 }
            return SQLLiteral.placeholder(nextIndex, dialect: dialect)
        }

        for rule in rules {
            let column = Identifier.quote(rule.column, dialect: dialect)
            switch rule.op {
            case .isNull:
                add("\(column) IS NULL", rule: rule)
            case .isNotNull:
                add("\(column) IS NOT NULL", rule: rule)
            case .equal, .notEqual, .lessThan, .lessOrEqual, .greaterThan, .greaterOrEqual:
                guard let value = rule.values.first else { continue }
                let comparison =
                    switch rule.op {
                    case .equal: "="
                    case .notEqual: "<>"
                    case .lessThan: "<"
                    case .lessOrEqual: "<="
                    case .greaterThan: ">"
                    default: ">="
                    }
                add("\(column) \(comparison) \(placeholder(value))", rule: rule)
            case .contains, .startsWith, .endsWith:
                guard let value = rule.values.first, let text = value.text else { continue }
                let escaped = escapeLikePattern(text)
                let pattern =
                    switch rule.op {
                    case .contains: "%\(escaped)%"
                    case .startsWith: "\(escaped)%"
                    default: "%\(escaped)"
                    }
                // Casting to text lets the same filter work on numeric and date columns.
                let lhs = dialect == .postgresql ? "\(column)::text" : "CAST(\(column) AS CHAR)"
                add("\(lhs) LIKE \(placeholder(.string(pattern))) ESCAPE '!'", rule: rule)
            case .inList:
                guard !rule.values.isEmpty else { continue }
                let items = rule.values.map { placeholder($0) }.joined(separator: ", ")
                add("\(column) IN (\(items))", rule: rule)
            case .between:
                guard rule.values.count >= 2 else { continue }
                let low = placeholder(rule.values[0])
                let high = placeholder(rule.values[1])
                add("\(column) BETWEEN \(low) AND \(high)", rule: rule)
            case .anyContains:
                guard let value = rule.values.first, let text = value.text, !text.isEmpty else { continue }
                let targets = (rule.targets ?? [rule.column]).filter { !$0.isEmpty }
                guard !targets.isEmpty else { continue }
                // The pattern is bound once per column: MySQL's placeholders are positional,
                // so a value cannot be referenced twice. The columns are quoted identifiers.
                let pattern = "%\(escapeLikePattern(text))%"
                let parts = targets.map { name -> String in
                    let quoted = Identifier.quote(name, dialect: dialect)
                    let lhs = dialect == .postgresql ? "\(quoted)::text" : "CAST(\(quoted) AS CHAR)"
                    let op = dialect == .postgresql ? "ILIKE" : "LIKE"
                    return "\(lhs) \(op) \(placeholder(.string(pattern))) ESCAPE '!'"
                }
                add("(" + parts.joined(separator: " OR ") + ")", rule: rule)
            }
        }

        var parts: [String] = []
        if groups.count == 1, let only = groups.first {
            parts.append(only.joined(separator: " AND "))
        } else if groups.count > 1 {
            let joined = groups.map { "(" + $0.joined(separator: " AND ") + ")" }.joined(separator: " OR ")
            parts.append(searches.isEmpty ? joined : "(\(joined))")
        }
        parts.append(contentsOf: searches)
        return Compiled(
            whereClause: parts.isEmpty ? nil : parts.joined(separator: " AND "),
            parameters: parameters
        )
    }

    /// Escapes the wildcards so a user's `%` or `_` matches itself.
    ///
    /// The escape character is `!` rather than a backslash: MySQL reads a backslash inside
    /// a string literal as an escape unless `NO_BACKSLASH_ESCAPES` is on, so `ESCAPE '\'`
    /// is a syntax error on one server and a two-character escape on another. `!` means
    /// the same thing on every engine and in every SQL mode.
    static func escapeLikePattern(_ text: String) -> String {
        var output = ""
        output.reserveCapacity(text.count)
        for character in text {
            if character == "%" || character == "_" || character == "!" { output.append("!") }
            output.append(character)
        }
        return output
    }
}
