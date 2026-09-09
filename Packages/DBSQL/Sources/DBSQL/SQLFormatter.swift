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

            if scalar == "?", dialect != .postgresql {
                scanner.advance()
                tokens.append(SQLToken(kind: .parameter, text: "?", utf16Range: startUTF16 ..< scanner.utf16Offset))
                continue
            }

            if scalar.value >= 0x30, scalar.value <= 0x39 {
                if scalar == "0", let x = scanner.peek(1), x == "x" || x == "X", let digit = scanner.peek(2),
                    digit.properties.isASCIIHexDigit
                {
                    // A hex literal: `0x1F` is one number, not a zero and a name.
                    scanner.advance(2)
                    while let next = scanner.peek(), next.properties.isASCIIHexDigit { scanner.advance() }
                } else {
                    while let next = scanner.peek() {
                        if (next.value >= 0x30 && next.value <= 0x39) || next == "." {
                            scanner.advance()
                        } else if next == "e" || next == "E" {
                            // The exponent may carry a sign: `1e-5` is one number.
                            scanner.advance()
                            if let sign = scanner.peek(), sign == "+" || sign == "-", let digit = scanner.peek(1),
                                digit.value >= 0x30, digit.value <= 0x39
                            {
                                scanner.advance()
                            }
                        } else {
                            break
                        }
                    }
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

    /// Keywords that are also common column or table names, which the formatter must not
    /// re-case: `comment`, `key`, `first`, `window`… stay as typed, and on a MySQL server
    /// with case-sensitive table names `FROM comment` and `FROM COMMENT` are different tables.
    public static let nonReserved: Set<String> = [
        "ADD", "ANALYZE", "BEGIN", "CASCADE", "COLUMN", "COMMENT", "COMMIT", "CONSTRAINT", "CUBE",
        "CURRENT", "DATABASE", "DEFERRABLE", "EXCLUDE", "EXPLAIN", "FILTER", "FIRST", "FOLLOWING", "FUNCTION",
        "GROUPING", "INDEX", "KEY", "LAST", "LATERAL", "MATERIALIZED", "MERGE", "ONLY", "OVER",
        "PARTITION", "PRECEDING", "PROCEDURE", "RANGE", "RECURSIVE", "RENAME", "REPLACE", "RESTRICT", "ROLLBACK",
        "ROLLUP", "ROW", "ROWS", "SAVEPOINT", "SCHEMA", "SHOW", "TEMPORARY", "TRIGGER", "TRUNCATE", "UNBOUNDED",
        "UNLOGGED", "VACUUM", "VIEW", "WINDOW", "WITHOUT",
    ]

    /// The keywords the formatter upper-cases: reserved words, never a name-like one.
    public static var reserved: Set<String> { keywords.subtracting(nonReserved) }

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
        // SQLite
        "ATTACH", "AUTOINCREMENT", "DETACH", "GLOB", "PRAGMA", "REINDEX", "STRICT", "VIRTUAL",
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
    static let functionKeywords: Set<String> = ["CAST", "COALESCE", "REPLACE", "LEFT", "RIGHT"]
    /// Characters that make up operators, so `<=` and `||` stay whole.
    static let operatorScalars = Set("<>=!|:&@#?~^*+-/%".unicodeScalars)

    public static func format(_ sql: String, dialect: SQLDialect, indentWidth: Int = 2) -> String {
        let statements = StatementSplitter.split(sql, dialect: dialect)
        guard !statements.isEmpty else { return sql }
        let units = Array(sql.utf16)
        var paragraphs: [String] = []
        var cursor = 0

        /// Text the splitter left out — comments between or after statements — kept as
        /// its own paragraph rather than dropped.
        func keepGap(upTo end: Int) {
            guard cursor < end, end <= units.count else { return }
            let gap = String(decoding: units[cursor ..< end], as: UTF16.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !gap.isEmpty { paragraphs.append(gap) }
        }

        for statement in statements {
            keepGap(upTo: statement.utf16Range.lowerBound)
            let body = formatStatement(statement.text, dialect: dialect, indentWidth: indentWidth)
            var paragraph = body
            var end = statement.utf16Range.upperBound
            if let terminator = statement.terminator {
                // A body that ends in a line comment must not swallow its terminator.
                paragraph += endsInLineComment(statement.text, dialect: dialect) ? "\n\(terminator)" : terminator
                // Step past the terminator in the source, whitespace before it included.
                while end < units.count, let scalar = UnicodeScalar(units[end]), scalar.properties.isWhitespace {
                    end += 1
                }
                let terminatorUnits = Array(terminator.utf16)
                if end + terminatorUnits.count <= units.count,
                    Array(units[end ..< end + terminatorUnits.count]) == terminatorUnits
                {
                    end += terminatorUnits.count
                }
            }
            paragraphs.append(paragraph)
            cursor = end
        }
        keepGap(upTo: units.count)
        return paragraphs.joined(separator: "\n\n")
    }

    /// True when the last token of `sql` is a `--` or `#` comment, which runs to the end
    /// of its line and would take anything appended after it with it.
    static func endsInLineComment(_ sql: String, dialect: SQLDialect) -> Bool {
        guard let last = SQLTokenizer.tokenize(sql, dialect: dialect).last(where: { $0.kind != .whitespace }) else {
            return false
        }
        return last.kind == .comment && !last.text.hasPrefix("/*")
    }

    private enum Paren {
        /// A sub-select: the clauses inside sit two levels in, the closing paren one level in.
        /// It remembers whether the enclosing text was inside a `BETWEEN … AND`.
        case block(clauseIndent: Int, inBetween: Bool)
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
        /// A `-` or `+` that is a sign, so the number after it binds to it: `= -1`.
        var signPending = false
        var previous: SQLToken?

        /// Tokens that are next to each other in the source with nothing between them.
        func adjacent(_ a: SQLToken?, _ b: SQLToken?) -> Bool {
            guard let a, let b else { return false }
            return a.utf16Range.upperBound == b.utf16Range.lowerBound
        }

        /// How a keyword is written out: reserved words upper-cased, name-like ones as typed.
        /// A keyword next to a `.` is part of a qualified name and stays as typed too.
        func cased(_ token: SQLToken, next: SQLToken?) -> String {
            let upper = token.text.uppercased()
            // `NULLS FIRST` / `NULLS LAST` are one phrase even though FIRST and LAST are names elsewhere.
            if ["FIRST", "LAST"].contains(upper), previous?.text.uppercased() == "NULLS" { return upper }
            guard SQLTokenizer.reserved.contains(upper) else { return token.text }
            if previous?.text == ".", adjacent(previous, token) { return token.text }
            if next?.text == ".", adjacent(token, next) { return token.text }
            return upper
        }

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
                && !output.hasSuffix("[")
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
                if token.text.hasPrefix("/*") {
                    append(token.text)
                } else {
                    // A line comment owns the rest of its line; what follows starts a new
                    // one at the body's indent. The token carries its own newline.
                    append(token.text.trimmingCharacters(in: .newlines))
                    newline(at: bodyIndent)
                }
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
                    append("(", tight: tight || signPending)
                    signPending = false
                    if opensBlock {
                        parens.append(.block(clauseIndent: clauseIndent, inBetween: inBetween))
                        inBetween = false
                        clauseIndent += 2
                        newline(at: clauseIndent)
                    } else {
                        parens.append(.inline)
                    }
                    continue
                case ")":
                    if case .block(let saved, let outerBetween) = parens.popLast() {
                        clauseIndent = saved
                        inBetween = outerBetween
                        newline(at: bodyIndent)
                    }
                    append(")", tight: true)
                    continue
                case "[", "]":
                    // Subscripts bind to their array: `arr[1]`, `matrix[1][2]`.
                    append(token.text, tight: true)
                    continue
                case ",":
                    append(",", tight: true)
                    // MySQL's `LIMIT 10, 20` is one thing; a list item takes a line of its
                    // own, unless a line comment trails the comma and keeps its place.
                    let trailingComment = next?.kind == .comment && !(next?.text.hasPrefix("/*") ?? true)
                    if inlineParens || clause == "LIMIT" || trailingComment {
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
                    let joinsPrevious = isOperator(token) && isOperator(previous) && adjacent(previous, token)
                    append(token.text, tight: joinsPrevious)
                    // A sign rather than a subtraction: nothing operand-like came before it.
                    if token.text == "-" || token.text == "+" {
                        let operandBefore =
                            previous.map {
                                [.identifier, .quotedIdentifier, .number, .string, .parameter].contains($0.kind)
                                    || $0.text == ")" || $0.text == "]"
                            } ?? false
                        signPending = !operandBefore && !joinsPrevious
                    } else if token.text == "@" {
                        // A variable: `@total`, `@@session.sql_mode`.
                        signPending = adjacent(token, next)
                    } else {
                        signPending = false
                    }
                    continue
                }

            case .keyword where !inlineParens:
                let word = cased(token, next: next)
                // `FOR UPDATE` / `ON CONFLICT DO UPDATE SET`: this UPDATE heads no clause.
                let lockingUpdate =
                    upper == "UPDATE" && previous?.kind == .keyword
                    && ["FOR", "KEY", "DO"].contains(previous?.text.uppercased() ?? "")
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
                // A locking clause heads a line of its own: `FOR UPDATE`, `FOR NO KEY UPDATE`.
                if upper == "FOR", let next, next.kind == .keyword,
                    ["UPDATE", "SHARE", "NO", "KEY"].contains(next.text.uppercased())
                {
                    newline(at: clauseIndent)
                    append(upper)
                    clause = "FOR"
                    continue
                }
                if clauseStarters.contains(upper), !lockingUpdate {
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
                // `LEFT(name, 3)` is a function, not a join.
                if joinWords.contains(upper), !(next?.text == "(" && adjacent(token, next)) {
                    let continuesJoin = previous.map { joinWords.contains($0.text.uppercased()) } ?? false
                    if !continuesJoin { newline(at: bodyIndent) }
                    append(word)
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
                append(word)
                continue

            case .keyword:
                append(cased(token, next: next))
                continue

            case .string:
                // A prefix binds to its string: `E'…'`, `X'0A'`, `N'…'`, `_utf8mb4'…'`.
                let prefixed = previous?.kind == .identifier && adjacent(previous, token)
                append(token.text, tight: prefixed || signPending)
                signPending = false
                continue

            default:
                append(token.text, tight: signPending)
                signPending = false
                continue
            }
        }

        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
