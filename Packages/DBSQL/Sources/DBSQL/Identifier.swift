import DBCore
import Foundation

/// Quoting and unquoting of schema object names.
///
/// Generated SQL always quotes, so a name can contain anything the server allows.
/// ``display(_:dialect:)`` quotes only when necessary, for names shown to the user.
public enum Identifier {
    /// Wraps `name` in the dialect's quotes, escaping any embedded quote character.
    public static func quote(_ name: String, dialect: SQLDialect) -> String {
        switch dialect {
        case .postgresql:
            "\"\(name.replacingOccurrences(of: "\"", with: "\"\""))\""
        case .mysql:
            // A backtick is escaped by doubling it. MySQL forbids U+0000 in identifiers,
            // so no other character needs handling.
            "`\(name.replacingOccurrences(of: "`", with: "``"))`"
        }
    }

    /// Quotes each part and joins with dots: `"public"."users"`.
    public static func qualify(_ parts: [String], dialect: SQLDialect) -> String {
        parts.map { quote($0, dialect: dialect) }.joined(separator: ".")
    }

    /// The qualified name a driver should use for a table.
    ///
    /// PostgreSQL qualifies with the schema; MySQL, whose schema layer is the database
    /// itself, qualifies with the database.
    public static func qualified(_ table: TableRef, dialect: SQLDialect) -> String {
        switch dialect {
        case .postgresql: qualify([table.schema, table.name], dialect: dialect)
        case .mysql: qualify([table.database, table.name], dialect: dialect)
        }
    }

    /// The name as a user should read it: bare when it needs no quotes, quoted otherwise.
    public static func display(_ name: String, dialect: SQLDialect) -> String {
        needsQuoting(name, dialect: dialect) ? quote(name, dialect: dialect) : name
    }

    /// True when `name` would not survive being written unquoted.
    public static func needsQuoting(_ name: String, dialect: SQLDialect) -> Bool {
        if name.isEmpty { return true }
        switch dialect {
        case .postgresql:
            // PostgreSQL folds unquoted identifiers to lower case, so anything with an
            // upper-case letter must be quoted to survive.
            guard let first = name.first, first == "_" || (first.isLetter && first.isLowercase) else { return true }
            let allowed = name.allSatisfy { $0 == "_" || $0 == "$" || ($0.isLetter && $0.isLowercase) || $0.isNumber }
            return !allowed || reservedPostgres.contains(name)
        case .mysql:
            // MySQL allows [0-9a-zA-Z$_] unquoted, but not an all-digit name.
            let allowed = name.allSatisfy { $0 == "_" || $0 == "$" || $0.isLetter || $0.isNumber }
            if !allowed { return true }
            if name.allSatisfy(\.isNumber) { return true }
            return reservedMySQL.contains(name.uppercased())
        }
    }

    /// Removes one layer of quoting, undoubling any escaped quote character.
    public static func unquote(_ text: String, dialect: SQLDialect) -> String {
        let quoteCharacter: Character = dialect == .postgresql ? "\"" : "`"
        guard text.count >= 2, text.first == quoteCharacter, text.last == quoteCharacter else { return text }
        let inner = String(text.dropFirst().dropLast())
        return inner.replacingOccurrences(of: "\(quoteCharacter)\(quoteCharacter)", with: String(quoteCharacter))
    }

    /// Reserved words that must be quoted even though they look like plain identifiers.
    /// Only the words that actually collide in the SQL this app generates and displays.
    static let reservedPostgres: Set<String> = [
        "all", "analyse", "analyze", "and", "any", "array", "as", "asc", "asymmetric", "authorization",
        "between", "binary", "both", "case", "cast", "check", "collate", "collation", "column",
        "concurrently", "constraint", "create", "cross", "current_catalog", "current_date", "current_role",
        "current_schema", "current_time", "current_timestamp", "current_user", "default", "deferrable",
        "desc", "distinct", "do", "else", "end", "except", "false", "fetch", "for", "foreign", "freeze",
        "from", "full", "grant", "group", "having", "ilike", "in", "initially", "inner", "intersect",
        "into", "is", "isnull", "join", "lateral", "leading", "left", "like", "limit", "localtime",
        "localtimestamp", "natural", "not", "notnull", "null", "offset", "on", "only", "or", "order",
        "outer", "overlaps", "placing", "primary", "references", "returning", "right", "select",
        "session_user", "similar", "some", "symmetric", "table", "tablesample", "then", "to", "trailing",
        "true", "union", "unique", "user", "using", "variadic", "verbose", "when", "where", "window", "with",
    ]

    static let reservedMySQL: Set<String> = [
        "ADD", "ALL", "ALTER", "AND", "AS", "ASC", "BEFORE", "BETWEEN", "BIGINT", "BINARY", "BLOB", "BOTH",
        "BY", "CALL", "CASCADE", "CASE", "CHANGE", "CHAR", "CHARACTER", "CHECK", "COLLATE", "COLUMN",
        "CONDITION", "CONSTRAINT", "CONTINUE", "CONVERT", "CREATE", "CROSS", "CURRENT_DATE", "CURRENT_TIME",
        "CURRENT_TIMESTAMP", "CURRENT_USER", "CURSOR", "DATABASE", "DATABASES", "DEC", "DECIMAL", "DECLARE",
        "DEFAULT", "DELETE", "DESC", "DESCRIBE", "DISTINCT", "DIV", "DOUBLE", "DROP", "DUAL", "EACH", "ELSE",
        "ELSEIF", "ENCLOSED", "ESCAPED", "EXISTS", "EXIT", "EXPLAIN", "FALSE", "FETCH", "FLOAT", "FOR",
        "FORCE", "FOREIGN", "FROM", "FULLTEXT", "GENERATED", "GRANT", "GROUP", "HAVING", "IF", "IGNORE",
        "IN", "INDEX", "INFILE", "INNER", "INOUT", "INSENSITIVE", "INSERT", "INT", "INTEGER", "INTERVAL",
        "INTO", "IS", "ITERATE", "JOIN", "KEY", "KEYS", "KILL", "LEADING", "LEAVE", "LEFT", "LIKE", "LIMIT",
        "LINES", "LOAD", "LOCALTIME", "LOCALTIMESTAMP", "LOCK", "LONG", "LONGBLOB", "LONGTEXT", "LOOP",
        "MATCH", "MEDIUMBLOB", "MEDIUMINT", "MEDIUMTEXT", "MOD", "MODIFIES", "NATURAL", "NOT", "NULL",
        "NUMERIC", "ON", "OPTIMIZE", "OPTION", "OR", "ORDER", "OUT", "OUTER", "PARTITION", "PRECISION",
        "PRIMARY", "PROCEDURE", "RANGE", "READ", "READS", "REAL", "RECURSIVE", "REFERENCES", "RENAME",
        "REPEAT", "REPLACE", "REQUIRE", "RESTRICT", "RETURN", "REVOKE", "RIGHT", "RLIKE", "SCHEMA",
        "SELECT", "SENSITIVE", "SEPARATOR", "SET", "SHOW", "SMALLINT", "SPATIAL", "SQL", "SSL", "STARTING",
        "STORED", "TABLE", "TERMINATED", "THEN", "TINYBLOB", "TINYINT", "TINYTEXT", "TO", "TRAILING",
        "TRIGGER", "TRUE", "UNION", "UNIQUE", "UNLOCK", "UNSIGNED", "UPDATE", "USAGE", "USE", "USING",
        "VALUES", "VARBINARY", "VARCHAR", "VARYING", "VIRTUAL", "WHEN", "WHERE", "WHILE", "WITH", "WRITE",
        "XOR", "ZEROFILL",
    ]
}
