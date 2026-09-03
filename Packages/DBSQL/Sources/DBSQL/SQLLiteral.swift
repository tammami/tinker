import DBCore
import Foundation

extension DBValue {
    /// The value written as a SQL literal in `dialect`.
    ///
    /// Literals are for **display and export only** — the commit preview sheet, copy-as-INSERT,
    /// and SQL export. Statements the app executes bind values as parameters instead, which is
    /// the injection and type-safety boundary (SPEC §7.1).
    public func sqlLiteral(dialect: SQLDialect) -> String {
        switch self {
        case .null:
            return "NULL"
        case let .bool(value):
            return dialect == .postgresql ? (value ? "TRUE" : "FALSE") : (value ? "1" : "0")
        case let .int(value):
            return String(value)
        case let .uint(value):
            return String(value)
        case let .double(value):
            if value.isNaN || value.isInfinite {
                let text = DBValue.canonicalDouble(value)
                return dialect == .postgresql ? "'\(text)'::float8" : SQLLiteral.quoteString(text, dialect: dialect)
            }
            return String(value)
        case let .decimal(value):
            // Unquoted so the server parses it as an exact numeric, not a string.
            return value
        case let .string(value):
            return SQLLiteral.quoteString(value, dialect: dialect)
        case let .bytes(data):
            return SQLLiteral.byteLiteral(data, dialect: dialect)
        case let .date(value):
            let text = SQLLiteral.quoteString(value.description, dialect: dialect)
            return dialect == .postgresql ? "\(text)::date" : "DATE \(text)"
        case let .time(value):
            let text = SQLLiteral.quoteString(value.description, dialect: dialect)
            guard dialect == .postgresql else { return "TIME \(text)" }
            return value.tzOffsetSeconds == nil ? "\(text)::time" : "\(text)::timetz"
        case let .timestamp(value):
            let text = SQLLiteral.quoteString(value.serverText, dialect: dialect)
            guard dialect == .postgresql else { return "TIMESTAMP \(text)" }
            return value.hasTimeZone ? "\(text)::timestamptz" : "\(text)::timestamp"
        case let .uuid(value):
            let text = SQLLiteral.quoteString(value.uuidString.lowercased(), dialect: dialect)
            return dialect == .postgresql ? "\(text)::uuid" : text
        case let .json(value):
            let text = SQLLiteral.quoteString(value, dialect: dialect)
            return dialect == .postgresql ? "\(text)::jsonb" : "CAST(\(text) AS JSON)"
        case let .array(items):
            // Arrays are PostgreSQL-only; in MySQL the closest honest rendering is JSON text.
            guard dialect == .postgresql else {
                return SQLLiteral.quoteString("[\(items.map { $0.text ?? "null" }.joined(separator: ","))]", dialect: dialect)
            }
            return "ARRAY[\(items.map { $0.sqlLiteral(dialect: dialect) }.joined(separator: ", "))]"
        case let .raw(typeName, text, bytes):
            if let text {
                let quoted = SQLLiteral.quoteString(text, dialect: dialect)
                return dialect == .postgresql ? "\(quoted)::\(typeName)" : quoted
            }
            if let bytes { return SQLLiteral.byteLiteral(bytes, dialect: dialect) }
            return "NULL"
        }
    }
}

/// Escaping rules for SQL string and byte literals.
public enum SQLLiteral {
    /// A single-quoted string literal.
    ///
    /// PostgreSQL runs with `standard_conforming_strings = on`, so a backslash is an
    /// ordinary character and only the quote needs doubling. MySQL treats a backslash as
    /// an escape by default, so both are escaped.
    public static func quoteString(_ value: String, dialect: SQLDialect) -> String {
        switch dialect {
        case .postgresql:
            return "'\(value.replacingOccurrences(of: "'", with: "''"))'"
        case .mysql:
            var escaped = ""
            escaped.reserveCapacity(value.count + 2)
            for character in value {
                switch character {
                case "'": escaped += "''"
                case "\\": escaped += "\\\\"
                case "\0": escaped += "\\0"
                default: escaped.append(character)
                }
            }
            return "'\(escaped)'"
        }
    }

    /// A binary literal: PostgreSQL hex `bytea`, MySQL `X'…'`.
    public static func byteLiteral(_ data: Data, dialect: SQLDialect) -> String {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        switch dialect {
        case .postgresql: return "'\\x\(hex)'::bytea"
        case .mysql: return hex.isEmpty ? "X''" : "X'\(hex)'"
        }
    }

    /// The placeholder for parameter `index` (one-based): `$1` in PostgreSQL, `?` in MySQL.
    public static func placeholder(_ index: Int, dialect: SQLDialect) -> String {
        dialect == .postgresql ? "$\(index)" : "?"
    }

    /// Renders `sql` with its parameters substituted as literals, for display only.
    ///
    /// Placeholders inside string literals, quoted identifiers and comments are left alone.
    public static func renderForDisplay(_ sql: String, parameters: [DBValue], dialect: SQLDialect) -> String {
        guard !parameters.isEmpty else { return sql }
        var output = ""
        output.reserveCapacity(sql.count + parameters.count * 8)
        var scanner = SQLScanner(sql)
        var nextParameter = 0
        while let scalar = scanner.peek() {
            if let skipped = scanner.consumeQuotedOrComment(dialect: dialect) {
                output += skipped
                continue
            }
            if dialect == .mysql, scalar == "?" {
                scanner.advance()
                output += nextParameter < parameters.count
                    ? parameters[nextParameter].sqlLiteral(dialect: dialect)
                    : "?"
                nextParameter += 1
                continue
            }
            if dialect == .postgresql, scalar == "$" {
                let start = scanner.index
                scanner.advance()
                var digits = ""
                while let next = scanner.peek(), next.properties.numericType != nil, next.isASCII {
                    digits.unicodeScalars.append(next)
                    scanner.advance()
                }
                if let number = Int(digits), number >= 1, number <= parameters.count {
                    output += parameters[number - 1].sqlLiteral(dialect: dialect)
                } else {
                    output += scanner.text(from: start)
                }
                continue
            }
            output.unicodeScalars.append(scalar)
            scanner.advance()
        }
        return output
    }
}
