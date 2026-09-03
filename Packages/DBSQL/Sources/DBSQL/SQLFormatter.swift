import DBCore
import Foundation

/// One lexical piece of a SQL script.
public struct SQLToken: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case keyword
        case identifier
        case quotedIdentifier
        case string
        case number
        case comment
        case punctuation
        case whitespace
        case parameter
    }

    public let kind: Kind
    public let text: String
    /// UTF-16 range within the script.
    public let utf16Range: Range<Int>

    public init(kind: Kind, text: String, utf16Range: Range<Int>) {
        self.kind = kind
        self.text = text
        self.utf16Range = utf16Range
    }
}

/// Splits SQL into tokens.
///
/// Used by the formatter and as the fallback highlighter when a tree-sitter grammar is
/// unavailable. It is deliberately dialect-aware but not a parser.
public enum SQLTokenizer {
    public static func tokenize(_ sql: String, dialect: SQLDialect) -> [SQLToken] {
        var tokens: [SQLToken] = []
        var scanner = SQLScanner(sql)
        while !scanner.isAtEnd {
            let start = scanner.index
            let startUTF16 = scanner.utf16Offset

            if let consumed = scanner.consumeQuotedOrComment(dialect: dialect) {
                let kind: SQLToken.Kind = if consumed.hasPrefix("--") || consumed.hasPrefix("/*") || consumed.hasPrefix("#") {
                    .comment
                } else if consumed.hasPrefix("'") || consumed.hasPrefix("$") {
                    .string
                } else if dialect == .mysql, consumed.hasPrefix("\"") {
                    .string
                } else {
                    .quotedIdentifier
                }
                tokens.append(SQLToken(kind: kind, text: consumed, utf16Range: startUTF16 ..< scanner.utf16Offset))
                continue
            }

            guard let scalar = scanner.peek() else { break }

            if scalar.properties.isWhitespace {
                while let next = scanner.peek(), next.properties.isWhitespace { scanner.advance() }
                tokens.append(SQLToken(
                    kind: .whitespace, text: scanner.text(from: start),
                    utf16Range: startUTF16 ..< scanner.utf16Offset
                ))
                continue
            }

            if scalar == "$", dialect == .postgresql, let next = scanner.peek(1), next.value >= 0x30, next.value <= 0x39 {
                scanner.advance()
                while let next = scanner.peek(), next.value >= 0x30, next.value <= 0x39 { scanner.advance() }
                tokens.append(SQLToken(
                    kind: .parameter, text: scanner.text(from: start),
                    utf16Range: startUTF16 ..< scanner.utf16Offset
                ))
                continue
            }

            if scalar == "?" , dialect == .mysql {
                scanner.advance()
                tokens.append(SQLToken(kind: .parameter, text: "?", utf16Range: startUTF16 ..< scanner.utf16Offset))
                continue
            }

            if scalar.value >= 0x30, scalar.value <= 0x39 {
                while let next = scanner.peek(),
                      (next.value >= 0x30 && next.value <= 0x39) || next == "." || next == "e" || next == "E" {
                    scanner.advance()
                }
                tokens.append(SQLToken(
                    kind: .number, text: scanner.text(from: start),
                    utf16Range: startUTF16 ..< scanner.utf16Offset
                ))
                continue
            }

            if SQLScanner.isIdentifierScalar(scalar) {
                while let next = scanner.peek(), SQLScanner.isIdentifierScalar(next) { scanner.advance() }
                let text = scanner.text(from: start)
                let kind: SQLToken.Kind = keywords.contains(text.uppercased()) ? .keyword : .identifier
                tokens.append(SQLToken(kind: kind, text: text, utf16Range: startUTF16 ..< scanner.utf16Offset))
                continue
            }

            scanner.advance()
            tokens.append(SQLToken(
                kind: .punctuation, text: scanner.text(from: start),
                utf16Range: startUTF16 ..< scanner.utf16Offset
            ))
        }
        return tokens
    }

    /// The token covering a UTF-16 offset, for marking the position a server error names.
    public static func token(at utf16Offset: Int, in sql: String, dialect: SQLDialect) -> SQLToken? {
        tokenize(sql, dialect: dialect).first { token in
            token.kind != .whitespace && token.utf16Range.contains(utf16Offset)
        }
    }

    /// Keywords recognised for highlighting, formatting and autocomplete.
    public static let keywords: Set<String> = [
        "ADD", "ALL", "ALTER", "ANALYZE", "AND", "ANY", "AS", "ASC", "BEGIN", "BETWEEN", "BY", "CASCADE",
        "CASE", "CAST", "CHECK", "COALESCE", "COLLATE", "COLUMN", "COMMENT", "COMMIT", "CONFLICT",
        "CONSTRAINT", "CREATE", "CROSS", "CUBE", "CURRENT", "DATABASE", "DEFAULT", "DEFERRABLE", "DELETE",
        "DESC", "DISTINCT", "DO", "DROP", "ELSE", "END", "ESCAPE", "EXCEPT", "EXCLUDE", "EXISTS", "EXPLAIN",
        "FALSE", "FETCH", "FILTER", "FIRST", "FOLLOWING", "FOR", "FOREIGN", "FROM", "FULL", "FUNCTION",
        "GRANT", "GROUP", "GROUPING", "HAVING", "IF", "ILIKE", "IN", "INDEX", "INNER", "INSERT", "INTERSECT",
        "INTO", "IS", "JOIN", "KEY", "LAST", "LATERAL", "LEFT", "LIKE", "LIMIT", "MATERIALIZED", "MERGE",
        "NATURAL", "NOT", "NOTHING", "NULL", "NULLS", "OFFSET", "ON", "ONLY", "OR", "ORDER", "OUTER", "OVER",
        "PARTITION", "PRECEDING", "PRIMARY", "PROCEDURE", "RANGE", "RECURSIVE", "REFERENCES", "RENAME",
        "REPLACE", "RESTRICT", "RETURNING", "RIGHT", "ROLLBACK", "ROLLUP", "ROW", "ROWS", "SAVEPOINT",
        "SCHEMA", "SELECT", "SET", "SHOW", "SIMILAR", "SOME", "TABLE", "TEMPORARY", "THEN", "TRIGGER",
        "TRUE", "TRUNCATE", "UNBOUNDED", "UNION", "UNIQUE", "UNLOGGED", "UPDATE", "USING", "VACUUM",
        "VALUES", "VIEW", "WHEN", "WHERE", "WINDOW", "WITH", "WITHOUT",
    ]
}

/// A conservative SQL formatter: upper-cases keywords, puts each clause on its own line
/// and indents parenthesised sub-selects (SPEC §13.1).
///
/// It rewrites whitespace and keyword casing and nothing else. Strings, comments,
/// quoted identifiers and the order of everything else survive untouched.
public enum SQLFormatter {
    /// Keywords that begin a clause and therefore begin a line.
    static let clauseStarters: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "WINDOW", "LIMIT", "OFFSET", "FETCH",
        "UNION", "INTERSECT", "EXCEPT", "VALUES", "SET", "RETURNING", "INTO",
        "JOIN", "ON", "USING", "WITH",
    ]
    /// Keywords that begin a clause only together with the word after them.
    static let clausePairs: Set<String> = ["GROUP", "ORDER", "INSERT", "DELETE", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL"]

    public static func format(_ sql: String, dialect: SQLDialect, indentWidth: Int = 4) -> String {
        let statements = StatementSplitter.split(sql, dialect: dialect)
        guard !statements.isEmpty else { return sql }
        let formatted = statements.map { statement -> String in
            let body = formatStatement(statement.text, dialect: dialect, indentWidth: indentWidth)
            return statement.terminator.map { "\(body)\($0)" } ?? body
        }
        return formatted.joined(separator: "\n\n")
    }

    static func formatStatement(_ sql: String, dialect: SQLDialect, indentWidth: Int) -> String {
        let tokens = SQLTokenizer.tokenize(sql, dialect: dialect).filter { $0.kind != .whitespace }
        guard !tokens.isEmpty else { return sql }

        var output = ""
        var depth = 0
        /// One entry per open parenthesis: true when it opened an indented sub-select block.
        var parenStack: [Bool] = []
        var previous: SQLToken?

        /// Starts a fresh line at the current indent. Calling it twice in a row is a no-op,
        /// so an opening sub-select paren and the SELECT that follows share one line break.
        func newline() {
            while output.hasSuffix(" ") { output.removeLast() }
            guard !output.isEmpty else { return }
            if !output.hasSuffix("\n") { output += "\n" }
            output += String(repeating: " ", count: depth * indentWidth)
        }

        /// Appends `text`, inserting a separating space unless one would be wrong.
        func append(_ text: String) {
            let needsSpace = !output.isEmpty
                && !output.hasSuffix(" ")
                && !output.hasSuffix("\n")
                && !output.hasSuffix("(")
            if needsSpace { output += " " }
            output += text
        }

        for (position, token) in tokens.enumerated() {
            let text = token.kind == .keyword ? token.text.uppercased() : token.text
            let next = position + 1 < tokens.count ? tokens[position + 1] : nil

            if token.kind == .punctuation {
                switch text {
                case "(":
                    let opensSubSelect = next?.kind == .keyword
                        && ["SELECT", "WITH", "VALUES"].contains(next?.text.uppercased() ?? "")
                    // A function call binds tightly to its name; a keyword takes a space.
                    if previous?.kind == .keyword || previous == nil {
                        append("(")
                    } else {
                        output += "("
                    }
                    parenStack.append(opensSubSelect)
                    if opensSubSelect {
                        depth += 1
                        newline()
                    }
                    previous = token
                    continue
                case ")":
                    if parenStack.popLast() == true {
                        depth = max(0, depth - 1)
                        newline()
                    }
                    while output.hasSuffix(" ") { output.removeLast() }
                    output += ")"
                    previous = token
                    continue
                case ",":
                    while output.hasSuffix(" ") { output.removeLast() }
                    output += ", "
                    previous = token
                    continue
                case ".", "::":
                    while output.hasSuffix(" ") { output.removeLast() }
                    output += text
                    previous = token
                    continue
                default:
                    break
                }
            }

            if token.kind == .keyword {
                let startsClause = clauseStarters.contains(text)
                    || (clausePairs.contains(text) && next?.kind == .keyword)
                    || text == "INSERT" || text == "DELETE"
                if startsClause, !output.isEmpty {
                    if text == "ON" || text == "USING" {
                        // A join condition reads better indented under its JOIN.
                        depth += 1
                        newline()
                        depth -= 1
                    } else {
                        newline()
                    }
                }
            }

            append(text)
            previous = token
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
