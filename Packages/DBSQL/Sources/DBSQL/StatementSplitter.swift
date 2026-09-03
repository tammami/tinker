import DBCore
import Foundation

/// One statement carved out of a script.
public struct SQLStatement: Sendable, Hashable, Identifiable {
    /// The statement text, trimmed, without its terminator.
    public let text: String
    /// UTF-16 range of ``text`` within the original script. Maps directly to `NSRange`.
    public let utf16Range: Range<Int>
    /// One-based line on which the statement starts.
    public let startLine: Int
    /// The delimiter that ended the statement, or nil when the script ended first.
    public let terminator: String?

    public init(text: String, utf16Range: Range<Int>, startLine: Int, terminator: String?) {
        self.text = text
        self.utf16Range = utf16Range
        self.startLine = startLine
        self.terminator = terminator
    }

    public var id: Int { utf16Range.lowerBound }

    /// The first SQL keyword, upper-cased, ignoring leading comments and parentheses.
    public var leadingKeyword: String {
        var scanner = SQLScanner(text)
        while !scanner.isAtEnd {
            if scanner.consumeQuotedOrComment(dialect: .postgresql) != nil { continue }
            guard let scalar = scanner.peek() else { break }
            if scalar.properties.isWhitespace || scalar == "(" {
                scanner.advance()
                continue
            }
            var word = String.UnicodeScalarView()
            while let next = scanner.peek(), SQLScanner.isIdentifierScalar(next), next != "$" {
                word.append(next)
                scanner.advance()
            }
            return String(word).uppercased()
        }
        return ""
    }

    /// True when the statement cannot modify data, used by the read-only guard (SPEC §9).
    ///
    /// Deliberately conservative: a `WITH` that contains any data-modifying keyword is
    /// treated as a write, because PostgreSQL allows `WITH … INSERT`.
    public var isProbablyReadOnly: Bool {
        let keyword = leadingKeyword
        let readOnlyKeywords: Set<String> = ["SELECT", "SHOW", "EXPLAIN", "DESCRIBE", "DESC", "TABLE", "VALUES"]
        if keyword == "WITH" {
            let upper = text.uppercased()
            for writeKeyword in ["INSERT", "UPDATE", "DELETE", "MERGE"] where upper.contains(writeKeyword) {
                return false
            }
            return true
        }
        return readOnlyKeywords.contains(keyword)
    }

    /// A label for a result tab: the first 40 characters on one line.
    public var shortLabel: String {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return collapsed.count <= 40 ? collapsed : String(collapsed.prefix(39)) + "…"
    }
}

/// Splits a script into statements.
///
/// Drivers never split; this is the only splitter, and the app executes the statements it
/// returns one at a time on the same connection (SPEC §7.2). It understands string
/// literals, quoted identifiers, line and block comments, PostgreSQL dollar-quoted bodies
/// and nested block comments, and the MySQL client's `DELIMITER` directive, so pasted dumps
/// containing stored procedures split correctly.
public enum StatementSplitter {
    public static func split(_ sql: String, dialect: SQLDialect) -> [SQLStatement] {
        var statements: [SQLStatement] = []
        var scanner = SQLScanner(sql)
        var delimiter = ";"
        var statementStart = scanner.index
        var statementStartUTF16 = scanner.utf16Offset
        var statementStartLine = scanner.line

        /// Emits everything from the recorded start up to `end`, if it holds anything but
        /// whitespace and comments.
        func flush(end: Int, endUTF16: Int, terminator: String?) {
            let raw = scanner.text(from: statementStart, to: end)
            let trimmedLeading = raw.prefix { $0.isWhitespace }.count
            let trimmedTrailing = raw.reversed().prefix { $0.isWhitespace }.count
            let trimmed = raw.dropFirst(trimmedLeading).dropLast(trimmedTrailing)
            if !trimmed.isEmpty, !isOnlyComments(String(trimmed), dialect: dialect) {
                let leadingUTF16 = String(raw.prefix(trimmedLeading)).utf16.count
                let trailingUTF16 = String(raw.suffix(trimmedTrailing)).utf16.count
                let extraLines = raw.prefix(trimmedLeading).filter { $0 == "\n" }.count
                statements.append(SQLStatement(
                    text: String(trimmed),
                    utf16Range: (statementStartUTF16 + leadingUTF16) ..< (endUTF16 - trailingUTF16),
                    startLine: statementStartLine + extraLines,
                    terminator: terminator
                ))
            }
        }

        while !scanner.isAtEnd {
            if scanner.consumeQuotedOrComment(dialect: dialect) != nil { continue }

            // `DELIMITER x` is a client directive, not SQL. MySQL dumps rely on it to define
            // routines whose bodies contain semicolons.
            if dialect == .mysql, isAtStatementStart(scanner, from: statementStart),
               scanner.matchesKeyword("DELIMITER", at: scanner.index) {
                scanner.advance(9)
                while let scalar = scanner.peek(), scalar == " " || scalar == "\t" { scanner.advance() }
                var token = String.UnicodeScalarView()
                while let scalar = scanner.peek(), !scalar.properties.isWhitespace {
                    token.append(scalar)
                    scanner.advance()
                }
                if !token.isEmpty { delimiter = String(token) }
                while let scalar = scanner.peek(), scalar != "\n" { scanner.advance() }
                if scanner.peek() == "\n" { scanner.advance() }
                statementStart = scanner.index
                statementStartUTF16 = scanner.utf16Offset
                statementStartLine = scanner.line
                continue
            }

            if matchesDelimiter(scanner, delimiter) {
                let end = scanner.index
                let endUTF16 = scanner.utf16Offset
                scanner.advance(delimiter.unicodeScalars.count)
                flush(end: end, endUTF16: endUTF16, terminator: delimiter)
                statementStart = scanner.index
                statementStartUTF16 = scanner.utf16Offset
                statementStartLine = scanner.line
                continue
            }

            scanner.advance()
        }
        flush(end: scanner.index, endUTF16: scanner.utf16Offset, terminator: nil)
        return statements
    }

    /// The statement containing `utf16Offset`, for "run the statement under the cursor".
    ///
    /// A cursor resting just after a terminator, or in the whitespace that follows one,
    /// belongs to the statement that ended there rather than to the next one.
    public static func statement(
        at utf16Offset: Int,
        in sql: String,
        dialect: SQLDialect
    ) -> SQLStatement? {
        let statements = split(sql, dialect: dialect)
        guard !statements.isEmpty else { return nil }
        for statement in statements where statement.utf16Range.contains(utf16Offset) {
            return statement
        }
        // Between statements: prefer the one that ends closest before the cursor.
        let before = statements.last { $0.utf16Range.upperBound <= utf16Offset }
        return before ?? statements.first
    }

    /// True when the text holds nothing executable — only comments and whitespace.
    static func isOnlyComments(_ text: String, dialect: SQLDialect) -> Bool {
        var scanner = SQLScanner(text)
        while !scanner.isAtEnd {
            if let consumed = scanner.consumeQuotedOrComment(dialect: dialect) {
                if consumed.hasPrefix("--") || consumed.hasPrefix("/*") || consumed.hasPrefix("#") { continue }
                return false
            }
            guard let scalar = scanner.peek() else { break }
            if !scalar.properties.isWhitespace { return false }
            scanner.advance()
        }
        return true
    }

    /// True when only whitespace and comments separate the cursor from the statement start,
    /// which is where a `DELIMITER` directive is allowed to appear.
    private static func isAtStatementStart(_ scanner: SQLScanner, from statementStart: Int) -> Bool {
        isOnlyComments(scanner.text(from: statementStart, to: scanner.index), dialect: .mysql)
    }

    private static func matchesDelimiter(_ scanner: SQLScanner, _ delimiter: String) -> Bool {
        let scalars = Array(delimiter.unicodeScalars)
        guard !scalars.isEmpty else { return false }
        for (offset, expected) in scalars.enumerated() {
            guard let actual = scanner.peek(offset), actual == expected else { return false }
        }
        return true
    }
}
