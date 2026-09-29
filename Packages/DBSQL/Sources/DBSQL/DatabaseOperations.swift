import DBCore
import Foundation

/// Creating and dropping whole databases on a server.
///
/// SQLite has none of this: a SQLite database is a file, made from the connection
/// editor's New… button and removed in the Finder, so both functions return nil for it.
public enum DatabaseOperations {
    /// What a new database is created with. Empty fields are left to the server's defaults.
    public struct CreateOptions: Sendable, Hashable {
        /// PostgreSQL `ENCODING`, e.g. `UTF8`.
        public var encoding: String
        /// PostgreSQL `OWNER`.
        public var owner: String
        /// PostgreSQL `TEMPLATE`. An encoding other than the template's needs `template0`,
        /// so that is what is used whenever an encoding is given and this is empty.
        public var template: String
        /// MySQL/MariaDB `CHARACTER SET`, e.g. `utf8mb4`.
        public var characterSet: String
        /// MySQL/MariaDB `COLLATE`, e.g. `utf8mb4_0900_ai_ci`.
        public var collation: String

        public init(
            encoding: String = "", owner: String = "", template: String = "", characterSet: String = "",
            collation: String = ""
        ) {
            self.encoding = encoding
            self.owner = owner
            self.template = template
            self.characterSet = characterSet
            self.collation = collation
        }
    }

    /// `CREATE DATABASE`, or nil for SQLite.
    public static func create(_ name: String, dialect: SQLDialect, options: CreateOptions = CreateOptions()) -> String? {
        let quoted = Identifier.quote(name.trimmingCharacters(in: .whitespaces), dialect: dialect)
        func clean(_ text: String) -> String { text.trimmingCharacters(in: .whitespaces) }
        switch dialect {
        case .postgresql:
            var sql = "CREATE DATABASE \(quoted)"
            if !clean(options.owner).isEmpty { sql += " OWNER \(Identifier.quote(clean(options.owner), dialect: dialect))" }
            let template = clean(options.template).isEmpty && !clean(options.encoding).isEmpty
                ? "template0" : clean(options.template)
            if !template.isEmpty { sql += " TEMPLATE \(Identifier.quote(template, dialect: dialect))" }
            if !clean(options.encoding).isEmpty { sql += " ENCODING \(SQLLiteralText.quote(clean(options.encoding)))" }
            return sql
        case .mysql:
            var sql = "CREATE DATABASE \(quoted)"
            // Names of character sets and collations are plain words; anything else is refused
            // (nil) rather than spliced into the statement or silently left out.
            for (keyword, value) in [("CHARACTER SET", clean(options.characterSet)), ("COLLATE", clean(options.collation))]
            where !value.isEmpty {
                guard Self.isWord(value) else { return nil }
                sql += " \(keyword) \(value)"
            }
            return sql
        case .sqlite:
            return nil
        }
    }

    /// `DROP DATABASE`, or nil for SQLite. `force` ends other sessions first
    /// (PostgreSQL 13+ `WITH (FORCE)`); MySQL never waits for them.
    public static func drop(_ name: String, dialect: SQLDialect, force: Bool = false) -> String? {
        let quoted = Identifier.quote(name, dialect: dialect)
        switch dialect {
        case .postgresql: return "DROP DATABASE \(quoted)" + (force ? " WITH (FORCE)" : "")
        case .mysql: return "DROP DATABASE \(quoted)"
        case .sqlite: return nil
        }
    }

    /// The databases a server keeps for itself; dropping one breaks the server or the
    /// cluster, so the app does not offer it.
    public static func isSystemDatabase(_ name: String, dialect: SQLDialect) -> Bool {
        switch dialect {
        case .postgresql: ["postgres", "template0", "template1"].contains(name)
        case .mysql: ["mysql", "information_schema", "performance_schema", "sys"].contains(name.lowercased())
        case .sqlite: true
        }
    }

    static func isWord(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

/// A single-quoted SQL string literal, with quotes doubled.
enum SQLLiteralText {
    static func quote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "''") + "'" }
}
