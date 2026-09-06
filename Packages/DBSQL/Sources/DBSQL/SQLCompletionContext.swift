import DBCore
import Foundation

/// A table a statement names, with the alias it gave it.
public struct SQLTableMention: Sendable, Hashable {
    /// The schema (PostgreSQL) or database (MySQL) qualifier, when the statement wrote one.
    public let schema: String?
    public let name: String
    public let alias: String?

    public init(schema: String? = nil, name: String, alias: String? = nil) {
        self.schema = schema
        self.name = name
        self.alias = alias
    }

    /// True when `qualifier` names this table: by alias, by name, or by `schema.name`.
    public func answers(to qualifier: String) -> Bool {
        if let alias, alias.caseInsensitiveCompare(qualifier) == .orderedSame { return true }
        if name.caseInsensitiveCompare(qualifier) == .orderedSame { return true }
        if let schema, "\(schema).\(name)".caseInsensitiveCompare(qualifier) == .orderedSame { return true }
        return false
    }
}

/// Where the caret sits in a statement, and therefore what autocomplete should offer.
///
/// Built from the statement's tokens, not a parse, so it stays cheap enough to run on
/// every keystroke and tolerant of the half-typed SQL it is always given.
public struct SQLCompletionContext: Sendable, Hashable {
    public enum Expecting: Sendable, Hashable {
        /// After `FROM`, `JOIN`, `INTO`, `UPDATE`, `TABLE`: a table or schema name.
        case tables
        /// In a select list, a condition, `SET`, `ORDER BY`…: a column of a mentioned table.
        case columns
        /// After `alias.`, `table.` or `schema.`: only what that qualifier holds.
        case qualified(String)
        /// Anywhere else: keywords and tables, as before.
        case any
    }

    public let expecting: Expecting
    /// The word being typed, without its qualifier; empty right after a space.
    public let prefix: String
    /// Every table the statement names, in order of appearance.
    public let tables: [SQLTableMention]

    /// Keywords after which a table name is expected.
    static let tableIntroducers: Set<String> = ["FROM", "JOIN", "INTO", "UPDATE", "TABLE"]
    /// Keywords after which a column is expected.
    static let columnIntroducers: Set<String> = [
        "SELECT", "WHERE", "AND", "OR", "ON", "SET", "BY", "HAVING", "RETURNING", "DISTINCT", "NOT", "WHEN", "THEN",
        "ELSE", "CASE", "BETWEEN", "LIKE", "ILIKE", "IN", "IS", "AS", "USING",
    ]
    /// Clause keywords whose lists hold columns, so a comma in them asks for another column.
    static let columnClauses: Set<String> = [
        "SELECT", "WHERE", "SET", "BY", "HAVING", "RETURNING", "ON", "USING", "DISTINCT",
    ]
    /// Clause keywords whose lists hold tables.
    static let tableClauses: Set<String> = ["FROM", "JOIN", "UPDATE"]
    /// Words that end a table reference, so they are never mistaken for an alias.
    static let notAliases: Set<String> = SQLTokenizer.keywords

    public init(expecting: Expecting, prefix: String, tables: [SQLTableMention]) {
        self.expecting = expecting
        self.prefix = prefix
        self.tables = tables
    }

    /// Reads the context at `caretOffset` (UTF-16, within `statement`).
    public static func detect(statement: String, caretOffset: Int, dialect: SQLDialect) -> SQLCompletionContext {
        let tokens = SQLTokenizer.tokenize(statement, dialect: dialect).filter {
            $0.kind != .whitespace && $0.kind != .comment
        }
        let caret = max(0, min(caretOffset, statement.utf16.count))
        let tables = mentions(in: tokens, dialect: dialect)

        // The tokens before the caret, with the word being typed split off the end.
        var before = tokens.filter { $0.utf16Range.upperBound <= caret }
        var prefix = ""
        if let last = before.last, last.utf16Range.upperBound == caret,
            last.kind == .identifier || last.kind == .keyword || last.kind == .quotedIdentifier
        {
            prefix = last.text
            before.removeLast()
        } else if let split = tokens.first(where: {
            $0.utf16Range.lowerBound < caret && caret < $0.utf16Range.upperBound
        }),
            split.kind == .identifier || split.kind == .keyword
        {
            // The caret sits inside a word: what is typed so far is the prefix.
            let units = Array(split.text.utf16)
            prefix = String(decoding: units[..<(caret - split.utf16Range.lowerBound)], as: UTF16.self)
        }

        // `u.na` or `u.`: the qualifier decides everything.
        var qualifier: [String] = []
        while before.count >= 2, before[before.count - 1].text == ".",
            before[before.count - 2].kind == .identifier || before[before.count - 2].kind == .quotedIdentifier,
            before[before.count - 2].utf16Range.upperBound == before[before.count - 1].utf16Range.lowerBound
        {
            qualifier.insert(Identifier.unquote(before[before.count - 2].text, dialect: dialect), at: 0)
            before.removeLast(2)
        }
        if !qualifier.isEmpty {
            return SQLCompletionContext(
                expecting: .qualified(qualifier.joined(separator: ".")), prefix: prefix, tables: tables)
        }

        guard let previous = before.last else {
            return SQLCompletionContext(expecting: .any, prefix: prefix, tables: tables)
        }
        let clause = currentClause(before)
        let previousWord = previous.text.uppercased()

        if previous.kind == .keyword, tableIntroducers.contains(previousWord) {
            return SQLCompletionContext(expecting: .tables, prefix: prefix, tables: tables)
        }
        if previous.kind == .keyword, columnIntroducers.contains(previousWord) {
            return SQLCompletionContext(expecting: .columns, prefix: prefix, tables: tables)
        }
        if previous.kind == .punctuation {
            switch previous.text {
            case ",":
                if let clause {
                    if tableClauses.contains(clause) {
                        return SQLCompletionContext(expecting: .tables, prefix: prefix, tables: tables)
                    }
                    // `INSERT INTO t (a, ` is still the column list.
                    if columnClauses.contains(clause) || clause == "INTO" || clause == "INSERT" {
                        return SQLCompletionContext(expecting: .columns, prefix: prefix, tables: tables)
                    }
                }
            case "(":
                // `INSERT INTO t (` lists columns; `IN (` and `count(` take a column too.
                if clause == "INTO" || clause == "INSERT" || (clause.map(columnClauses.contains) ?? false) {
                    return SQLCompletionContext(expecting: .columns, prefix: prefix, tables: tables)
                }
            default:
                // An operator in a condition or assignment: `WHERE a = `, `SET a = `.
                if previous.text.unicodeScalars.allSatisfy({ "<>=!+-*/%|".unicodeScalars.contains($0) }),
                    let clause, columnClauses.contains(clause)
                {
                    return SQLCompletionContext(expecting: .columns, prefix: prefix, tables: tables)
                }
            }
        }
        return SQLCompletionContext(expecting: .any, prefix: prefix, tables: tables)
    }

    /// The table `qualifier` stands for, when the statement gives one.
    public func table(for qualifier: String) -> SQLTableMention? {
        tables.first { $0.answers(to: qualifier) }
    }

    /// The last clause keyword before the caret at the current nesting, or nil.
    private static func currentClause(_ tokens: [SQLToken]) -> String? {
        var depth = 0
        for token in tokens.reversed() {
            if token.kind == .punctuation {
                if token.text == ")" { depth += 1 }
                if token.text == "(" {
                    if depth == 0 { continue }
                    depth -= 1
                }
                continue
            }
            guard depth == 0, token.kind == .keyword else { continue }
            let word = token.text.uppercased()
            if tableClauses.contains(word) || columnClauses.contains(word) || word == "INTO" || word == "INSERT"
                || word == "VALUES"
            {
                return word
            }
        }
        return nil
    }

    /// Every `[schema.]table [AS] [alias]` after FROM, JOIN, INTO, UPDATE or TABLE, and
    /// the further ones a comma adds to a FROM list.
    static func mentions(in tokens: [SQLToken], dialect: SQLDialect) -> [SQLTableMention] {
        var found: [SQLTableMention] = []
        var index = 0
        func isName(_ token: SQLToken) -> Bool { token.kind == .identifier || token.kind == .quotedIdentifier }
        while index < tokens.count {
            let token = tokens[index]
            guard token.kind == .keyword, tableIntroducers.contains(token.text.uppercased()) else {
                index += 1
                continue
            }
            var cursor = index + 1
            var more = true
            while more, cursor < tokens.count, isName(tokens[cursor]) {
                var schema: String?
                var name = Identifier.unquote(tokens[cursor].text, dialect: dialect)
                cursor += 1
                if cursor < tokens.count, tokens[cursor].text == "." {
                    // `schema.` with nothing after it yet names no table at all.
                    guard cursor + 1 < tokens.count, isName(tokens[cursor + 1]) else { break }
                    schema = name
                    name = Identifier.unquote(tokens[cursor + 1].text, dialect: dialect)
                    cursor += 2
                }
                var alias: String?
                if cursor < tokens.count, tokens[cursor].kind == .keyword, tokens[cursor].text.uppercased() == "AS" {
                    cursor += 1
                }
                if cursor < tokens.count, tokens[cursor].kind == .identifier,
                    !notAliases.contains(tokens[cursor].text.uppercased())
                {
                    alias = tokens[cursor].text
                    cursor += 1
                }
                found.append(SQLTableMention(schema: schema, name: name, alias: alias))
                // `FROM a, b`: the list goes on after a comma; `INTO t (` does not.
                more = token.text.uppercased() == "FROM" && cursor < tokens.count && tokens[cursor].text == ","
                if more { cursor += 1 }
            }
            index = max(cursor, index + 1)
        }
        return found
    }
}
