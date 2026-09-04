import DBCore
import DBSQL
import Foundation

/// The one table a `SELECT` reads, when it reads exactly one.
///
/// A result grid can be edited only when every row is a row of one table and that
/// table's key is in the result; this finds the table. It is deliberately strict: a
/// join, a subquery in `FROM`, `GROUP BY`, `DISTINCT ON`, a set operation, or anything
/// it does not understand means "not editable", never a wrong table.
public enum QuerySourceTable {
    public struct Match: Sendable, Hashable {
        public let schema: String?
        public let name: String
    }

    public static func detect(_ sql: String, dialect: SQLDialect) -> Match? {
        let tokens = SQLTokenizer.tokenize(sql, dialect: dialect).filter {
            $0.kind != .whitespace && $0.kind != .comment
        }
        guard let first = tokens.first, first.kind == .keyword, first.text.uppercased() == "SELECT" else { return nil }

        // Anything at the top level that changes what a row is.
        var depth = 0
        var fromIndex: Int?
        for (index, token) in tokens.enumerated() {
            if token.kind == .punctuation {
                if token.text == "(" { depth += 1 }
                if token.text == ")" { depth -= 1 }
                continue
            }
            guard depth == 0, token.kind == .keyword else { continue }
            switch token.text.uppercased() {
            case "GROUP", "HAVING", "UNION", "INTERSECT", "EXCEPT", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS",
                "NATURAL", "INTO", "WINDOW":
                return nil
            case "FROM":
                if fromIndex == nil { fromIndex = index }
            default:
                break
            }
        }
        guard let fromIndex, fromIndex + 1 < tokens.count else { return nil }

        // `DISTINCT ON (…)` picks rows the key does not identify.
        if tokens.count > 2, tokens[1].text.uppercased() == "DISTINCT", tokens[2].text.uppercased() == "ON" {
            return nil
        }

        var index = fromIndex + 1
        func identifier() -> String? {
            guard index < tokens.count else { return nil }
            let token = tokens[index]
            guard token.kind == .identifier || token.kind == .quotedIdentifier else { return nil }
            index += 1
            return Identifier.unquote(token.text, dialect: dialect)
        }
        guard let firstPart = identifier() else { return nil }
        var parts = [firstPart]
        while index < tokens.count, tokens[index].text == "." {
            index += 1
            guard let next = identifier() else { return nil }
            parts.append(next)
        }
        guard parts.count <= 3 else { return nil }
        // An alias, with or without AS.
        if index < tokens.count, tokens[index].text.uppercased() == "AS" { index += 1 }
        if index < tokens.count, tokens[index].kind == .identifier || tokens[index].kind == .quotedIdentifier {
            index += 1
        }
        // Only a second table, a join or a subquery disqualifies; the rest of the
        // statement (WHERE, ORDER, LIMIT…) is the select's own business.
        if index < tokens.count {
            let next = tokens[index]
            if next.text == "," || next.text == "(" { return nil }
            if next.kind == .keyword,
                ["JOIN", "INNER", "LEFT", "RIGHT", "FULL", "CROSS", "NATURAL", "TABLESAMPLE"].contains(
                    next.text.uppercased())
            {
                return nil
            }
        }
        return Match(schema: parts.count >= 2 ? parts[parts.count - 2] : nil, name: parts[parts.count - 1])
    }
}
