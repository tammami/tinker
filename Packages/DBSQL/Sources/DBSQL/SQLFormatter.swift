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
                let kind: SQLToken.Kind =
                    if consumed.hasPrefix("--") || consumed.hasPrefix("/*") || consumed.hasPrefix("#") {
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
                tokens.append(
                    SQLToken(
                        kind: .whitespace, text: scanner.text(from: start),
                        utf16Range: startUTF16 ..< scanner.utf16Offset
                    ))
                continue
            }

            if scalar == "$", dialect == .postgresql, let next = scanner.peek(1), next.value >= 0x30, next.value <= 0x39
            {
                scanner.advance()
                while let next = scanner.peek(), next.value >= 0x30, next.value <= 0x39 { scanner.advance() }
                tokens.append(
                    SQLToken(
                        kind: .parameter, text: scanner.text(from: start),
                        utf16Range: startUTF16 ..< scanner.utf16Offset
                    ))
                continue
            }

            if scalar == "?", dialect == .mysql {
                scanner.advance()
                tokens.append(SQLToken(kind: .parameter, text: "?", utf16Range: startUTF16 ..< scanner.utf16Offset))
                continue
            }

            if scalar.value >= 0x30, scalar.value <= 0x39 {
                while let next = scanner.peek(),
                    (next.value >= 0x30 && next.value <= 0x39) || next == "." || next == "e" || next == "E"
                {
                    scanner.advance()
                }
                tokens.append(
                    SQLToken(
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
            tokens.append(
                SQLToken(
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

/// Lays SQL out the way people read it: each clause keyword on a line of its own, the
/// clause's items indented beneath it one per line, joins and `AND`/`OR` each starting a
/// line, sub-selects indented inside their parentheses (SPEC §13.1).
///
///     SELECT
///       c.id,
///       c.name
///     FROM
///       customers c
///       LEFT JOIN orders o ON o.customer_id = c.id
///     WHERE
///       c.active
///       AND o.total > 0
///     ORDER BY
///       c.name DESC
///     LIMIT
///       10;
///
/// It rewrites whitespace and keyword casing and nothing else. Strings, comments, quoted
/// identifiers and the order of everything else survive untouched.
public enum SQLFormatter {
    /// Keywords that head a clause: on their own line, with the clause body indented under them.
    static let clauseStarters: Set<String> = [
        "SELECT", "FROM", "WHERE", "HAVING", "WINDOW", "LIMIT", "OFFSET", "FETCH", "VALUES", "SET",
        "RETURNING", "WITH", "UPDATE", "UNION", "INTERSECT", "EXCEPT",
    ]
    /// Keywords that head a clause together with the word after them: `GROUP BY`, `INSERT INTO`.
    static let clausePairs: [String: Set<String>] = [
        "GROUP": ["BY"], "ORDER": ["BY"], "INSERT": ["INTO"], "DELETE": ["FROM"],
    ]
    /// The words of a join, kept together on one line that starts fresh.
    static let joinWords: Set<String> = ["JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "CROSS", "NATURAL"]
    /// Keywords that bind to a following parenthesis like a function name does.
    static let functionKeywords: Set<String> = ["CAST", "COALESCE", "REPLACE"]
    /// Characters that make up operators, so `<=` and `||` stay whole.
    static let operatorScalars = Set("<>=!|:&@#?~^*+-/%".unicodeScalars)

    public static func format(_ sql: String, dialect: SQLDialect, indentWidth: Int = 2) -> String {
        let statements = StatementSplitter.split(sql, dialect: dialect)
        guard !statements.isEmpty else { return sql }
        let formatted = statements.map { statement -> String in
            let body = formatStatement(statement.text, dialect: dialect, indentWidth: indentWidth)
            return statement.terminator.map { "\(body)\($0)" } ?? body
        }
        return formatted.joined(separator: "\n\n")
    }

    private enum Paren {
        /// A sub-select: the clauses inside sit two levels in, the closing paren one level in.
        case block(clauseIndent: Int)
        /// A function call, an `IN` list, a column list: everything inside stays on the line.
        case inline
    }

    static func formatStatement(_ sql: String, dialect: SQLDialect, indentWidth: Int) -> String {
        let tokens = SQLTokenizer.tokenize(sql, dialect: dialect).filter { $0.kind != .whitespace }
        guard !tokens.isEmpty else { return sql }

        var output = ""
        /// Indent, in levels, of the clause keywords at the current nesting.
        var clauseIndent = 0
        var parens: [Paren] = []
        /// The clause being written, so `INSERT INTO t (a, b)` keeps the space a call would not.
        var clause = ""
        /// Between `BETWEEN` and its `AND`, which must not start a line.
        var inBetween = false
        var previous: SQLToken?

        var inlineParens: Bool { parens.last.map { if case .inline = $0 { true } else { false } } ?? false }
        var bodyIndent: Int { clauseIndent + 1 }

        /// Starts a fresh line at `level`. Repeated calls collapse into one line break, so
        /// a clause keyword after a sub-select's `(` does not leave an empty line behind.
        func newline(at level: Int) {
            while output.hasSuffix(" ") { output.removeLast() }
            guard !output.isEmpty else { return }
            if !output.hasSuffix("\n") { output += "\n" }
            output += String(repeating: " ", count: level * indentWidth)
        }

        /// Appends `text` after a space, unless what came before binds tightly to it.
        func append(_ text: String, tight: Bool = false) {
            let needsSpace =
                !tight
                && !output.isEmpty
                && !output.hasSuffix(" ")
                && !output.hasSuffix("\n")
                && !output.hasSuffix("(")
                && !output.hasSuffix(".")
                && !output.hasSuffix("::")
            if needsSpace { output += " " }
            output += text
        }

        func isOperator(_ token: SQLToken?) -> Bool {
            guard let token, token.kind == .punctuation else { return false }
            return token.text.unicodeScalars.allSatisfy(operatorScalars.contains)
        }

        var position = 0
        while position < tokens.count {
            let token = tokens[position]
            let next = position + 1 < tokens.count ? tokens[position + 1] : nil
            let upper = token.text.uppercased()
            defer {
                previous = token
                position += 1
            }

            switch token.kind {
            case .comment:
                append(token.text)
                // A line comment owns the rest of its line; what follows must start a new one.
                if !token.text.hasPrefix("/*") { newline(at: output.hasSuffix("\n") ? 0 : bodyIndent) }
                continue

            case .punctuation:
                switch token.text {
                case "(":
                    let opensBlock =
                        next?.kind == .keyword && ["SELECT", "WITH", "VALUES"].contains(next?.text.uppercased() ?? "")
                    // A call binds to its name: `count(*)`. A keyword, or the table of an
                    // INSERT or CREATE, takes a space: `IN (`, `INSERT INTO t (a, b)`.
                    let afterName = previous?.kind == .identifier || previous?.kind == .quotedIdentifier
                    let afterFunctionKeyword =
                        previous?.kind == .keyword && functionKeywords.contains(previous?.text.uppercased() ?? "")
                    let tight = (afterName && !["INSERT INTO", "CREATE"].contains(clause)) || afterFunctionKeyword
                    append("(", tight: tight)
                    if opensBlock {
                        parens.append(.block(clauseIndent: clauseIndent))
                        clauseIndent += 2
                        newline(at: clauseIndent)
                    } else {
                        parens.append(.inline)
                    }
                    continue
                case ")":
                    if case .block(let saved) = parens.popLast() {
                        clauseIndent = saved
                        newline(at: bodyIndent)
                    }
                    append(")", tight: true)
                    continue
                case ",":
                    append(",", tight: true)
                    if inlineParens {
                        output += " "
                    } else {
                        newline(at: bodyIndent)
                    }
                    continue
                case ";":
                    append(";", tight: true)
                    continue
                default:
                    // `.` and `::` bind both sides: `c.id`, `a::text`. The tokenizer hands
                    // the cast over one colon at a time.
                    let adjacentColon =
                        token.text == ":"
                        && ((previous?.text == ":" && previous?.utf16Range.upperBound == token.utf16Range.lowerBound)
                            || (next?.text == ":" && next?.utf16Range.lowerBound == token.utf16Range.upperBound))
                    if token.text == "." || adjacentColon {
                        append(token.text, tight: true)
                        continue
                    }
                    // Adjacent operator characters are one operator: `<=`, `||`, `->>`.
                    let joinsPrevious =
                        isOperator(token) && isOperator(previous)
                        && previous?.utf16Range.upperBound == token.utf16Range.lowerBound
                    append(token.text, tight: joinsPrevious)
                    continue
                }

            case .keyword where !inlineParens:
                if let second = clausePairs[upper], let next, next.kind == .keyword,
                    second.contains(next.text.uppercased())
                {
                    newline(at: clauseIndent)
                    append(upper)
                    append(next.text.uppercased())
                    clause = "\(upper) \(next.text.uppercased())"
                    position += 1
                    previous = next
                    newline(at: bodyIndent)
                    continue
                }
                if clauseStarters.contains(upper) {
                    newline(at: clauseIndent)
                    append(upper)
                    clause = upper
                    // `UNION ALL` is one line; the SELECT after it starts the next.
                    if ["UNION", "INTERSECT", "EXCEPT"].contains(upper), let next, next.kind == .keyword,
                        ["ALL", "DISTINCT"].contains(next.text.uppercased())
                    {
                        append(next.text.uppercased())
                        position += 1
                        previous = next
                    }
                    newline(at: bodyIndent)
                    continue
                }
                if joinWords.contains(upper) {
                    let continuesJoin = previous.map { joinWords.contains($0.text.uppercased()) } ?? false
                    if !continuesJoin { newline(at: bodyIndent) }
                    append(upper)
                    continue
                }
                if upper == "BETWEEN" { inBetween = true }
                if upper == "AND" || upper == "OR" {
                    if inBetween, upper == "AND" {
                        inBetween = false
                    } else {
                        newline(at: bodyIndent)
                    }
                }
                if upper == "CREATE" { clause = "CREATE" }
                append(upper)
                continue

            case .keyword:
                append(upper)
                continue

            default:
                append(token.text)
                continue
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
