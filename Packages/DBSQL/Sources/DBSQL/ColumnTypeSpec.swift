import DBCore
import Foundation

/// A column type taken apart the way a designer shows it: the base type, its length and
/// decimals, the members of an `enum`/`set`, whatever trails the parentheses
/// (`unsigned`, `without time zone`), and PostgreSQL's array brackets.
///
/// `render()` puts it back together exactly as the server spells it, so a definition that
/// went through the designer without being touched comes out character for character as
/// it went in — a round trip that loses a modifier is a `MODIFY COLUMN` nobody asked for.
public struct ColumnTypeSpec: Sendable, Hashable {
    /// The type without its parenthesised part: `varchar`, `decimal`, `enum`, `timestamp`.
    public var base: String
    /// The first number in the parentheses, when the type takes one: `varchar(255)`,
    /// `decimal(10,2)`, `timestamp(6)`.
    public var length: Int?
    /// The second number: the scale of a `decimal`/`numeric`.
    public var decimals: Int?
    /// The members of an `enum` or `set`, unquoted.
    public var values: [String]
    /// Words after the parentheses, kept as typed: `unsigned zerofill`, `with time zone`.
    public var suffix: String
    /// PostgreSQL array brackets, `[]` or `[][]`, written tight against the rest.
    public var array: String

    public init(
        base: String, length: Int? = nil, decimals: Int? = nil, values: [String] = [], suffix: String = "",
        array: String = ""
    ) {
        self.base = base
        self.length = length
        self.decimals = decimals
        self.values = values
        self.suffix = suffix
        self.array = array
    }

    /// The trailing words a server writes after a type, longest first so `unsigned
    /// zerofill` is taken whole rather than as `zerofill` alone.
    static let modifierPhrases = ["without time zone", "with time zone", "unsigned zerofill", "unsigned", "zerofill"]

    /// True for a type whose parentheses hold members rather than sizes.
    public var isEnumeration: Bool { Self.isEnumeration(base) }

    public static func isEnumeration(_ base: String) -> Bool {
        let lower = base.lowercased()
        return lower == "enum" || lower == "set"
    }

    // MARK: - What a type may be spelled with

    /// True when every character is one a type can be spelled with: letters, digits,
    /// `_`, space, the parentheses and comma of a length, the brackets of an array, the
    /// `"` of a quoted type name and the `.` of a schema-qualified one. A `;`, a `'`, a
    /// `-` or `/` cannot be part of a type — they are what would smuggle SQL in through
    /// a type read from a hostile catalogue — and `render` drops them.
    public static func isSafeTypeText(_ text: String) -> Bool {
        text.unicodeScalars.allSatisfy(isTypeScalar)
    }

    /// `text` with every character that is not type spelling removed.
    public static func sanitizedTypeText(_ text: String) -> String {
        guard !isSafeTypeText(text) else { return text }
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars where isTypeScalar(scalar) { scalars.append(scalar) }
        return String(scalars)
    }

    private static func isTypeScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "a" ... "z", "A" ... "Z", "0" ... "9", "_", " ", ",", "(", ")", "[", "]", "\"", ".": true
        default: false
        }
    }

    // MARK: - Reading

    /// Reads a type as the server spells it. Anything it cannot read is kept whole in
    /// `base`, so an unusual type still renders as itself.
    public static func parse(_ text: String) -> ColumnTypeSpec {
        var trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Array brackets come last and belong to no word: `numeric(10,2)[]`.
        var array = ""
        while trimmed.hasSuffix("[]") {
            array += "[]"
            trimmed = String(trimmed.dropLast(2)).trimmingCharacters(in: .whitespaces)
        }
        guard let open = trimmed.firstIndex(of: "("), let close = Self.matchingParen(in: trimmed, from: open) else {
            // No parentheses: `int unsigned`, `timestamp without time zone` still carry a
            // modifier the designer offers apart from the base.
            let (base, suffix) = splitModifiers(trimmed)
            return ColumnTypeSpec(base: base, suffix: suffix, array: array)
        }
        let base = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let inside = String(trimmed[trimmed.index(after: open) ..< close])
        let suffix = trimmed[trimmed.index(after: close)...].trimmingCharacters(in: .whitespaces)
        if isEnumeration(base) {
            return ColumnTypeSpec(base: base, values: parseMembers(inside), suffix: suffix, array: array)
        }
        let numbers = inside.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let length = numbers.first.flatMap { Int($0) }
        let decimals = numbers.count > 1 ? Int(numbers[1]) : nil
        // Something other than numbers in the parentheses — `interval day(2)`, a type
        // the designer has no row for — stays whole rather than being mangled.
        guard length != nil, numbers.count <= 2, numbers.allSatisfy({ Int($0) != nil }) else {
            return ColumnTypeSpec(base: trimmed, array: array)
        }
        return ColumnTypeSpec(base: base, length: length, decimals: decimals, suffix: suffix, array: array)
    }

    /// Takes the trailing modifier phrases off a type: `bigint unsigned zerofill` →
    /// (`bigint`, `unsigned zerofill`), `time with time zone` → (`time`, `with time zone`).
    static func splitModifiers(_ text: String) -> (base: String, suffix: String) {
        var base = text
        var suffix = ""
        var found = true
        while found {
            found = false
            let lower = base.lowercased()
            for phrase in modifierPhrases where lower.hasSuffix(" " + phrase) {
                let cut = base.index(base.endIndex, offsetBy: -phrase.count)
                let original = String(base[cut...])
                suffix = suffix.isEmpty ? original : "\(original) \(suffix)"
                base = String(base[..<cut]).trimmingCharacters(in: .whitespaces)
                found = true
                break
            }
        }
        return (base, suffix)
    }

    // MARK: - Writing

    /// The type as it is written in a column clause.
    ///
    /// Base, modifiers and brackets are type spelling and nothing else; a character that
    /// could not be part of a type is dropped (see `isSafeTypeText`). Members are quoted.
    public func render(dialect: SQLDialect) -> String {
        var text = Self.sanitizedTypeText(base)
        if isEnumeration {
            if !values.isEmpty {
                text += "(" + values.map { SQLLiteral.quoteString($0, dialect: dialect) }.joined(separator: ",") + ")"
            }
        } else if let length {
            text += decimals.map { "(\(length),\($0))" } ?? "(\(length))"
        }
        let modifiers = Self.sanitizedTypeText(suffix)
        if !modifiers.isEmpty { text += " " + modifiers }
        text += Self.sanitizedTypeText(array)
        return text
    }

    /// The type as the server would write it, from any spelling. The generator puts
    /// this in its statements, so no type reaches SQL without going through `render`.
    public static func normalized(_ type: String, dialect: SQLDialect) -> String {
        parse(type).render(dialect: dialect)
    }

    /// The members written the way the designer's field shows them: `'User','Admin'`.
    public func membersText(dialect: SQLDialect) -> String {
        values.map { SQLLiteral.quoteString($0, dialect: dialect) }.joined(separator: ",")
    }

    /// Reads members typed as `'a','b'` or as bare words `a, b` back into a list.
    public static func parseMembers(_ text: String) -> [String] {
        var members: [String] = []
        var current = ""
        var inQuote = false
        var hasQuoted = false
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            if inQuote {
                if character == "'" {
                    if next < text.endIndex, text[next] == "'" {
                        current.append("'")
                        index = text.index(after: next)
                        continue
                    }
                    inQuote = false
                } else if character == "\\", next < text.endIndex {
                    current.append(text[next])
                    index = text.index(after: next)
                    continue
                } else {
                    current.append(character)
                }
            } else if character == "'" {
                inQuote = true
                hasQuoted = true
                // Whitespace before an opening quote is separation, not content.
                current = ""
            } else if character == "," {
                members.append(hasQuoted ? current : current.trimmingCharacters(in: .whitespaces))
                current = ""
                hasQuoted = false
            } else if hasQuoted {
                // Text outside the quotes of a quoted member is noise: `'a' x` is `a`.
            } else {
                current.append(character)
            }
            index = next
        }
        if hasQuoted || !current.trimmingCharacters(in: .whitespaces).isEmpty {
            members.append(hasQuoted ? current : current.trimmingCharacters(in: .whitespaces))
        }
        return members
    }

    private static func matchingParen(in text: String, from open: String.Index) -> String.Index? {
        var depth = 0
        var inQuote = false
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if inQuote {
                if character == "'" { inQuote = false }
            } else if character == "'" {
                inQuote = true
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }
}

/// One entry in the designer's type pop-up.
public struct ColumnTypeChoice: Sendable, Hashable, Identifiable {
    public let name: String
    /// Whether the type takes a length: `varchar(255)`, `decimal(10,2)`.
    public let takesLength: Bool
    /// Whether the type takes decimals after its length.
    public let takesDecimals: Bool
    /// The modifiers the type can carry after its length — `unsigned`, `with time zone`
    /// — with the empty string standing for "none". Empty when the type takes no modifier.
    public let suffixes: [String]

    public var id: String { name }

    public init(_ name: String, takesLength: Bool = false, takesDecimals: Bool = false, suffixes: [String] = []) {
        self.name = name
        self.takesLength = takesLength
        self.takesDecimals = takesDecimals
        self.suffixes = suffixes
    }
}

/// The types each server's designer offers, in the order people look for them.
public enum ColumnTypeCatalog {
    public static func choices(for dialect: SQLDialect) -> [ColumnTypeChoice] {
        switch dialect {
        case .mysql: mysql
        case .postgresql: postgresql
        case .sqlite: sqlite
        }
    }

    /// The pop-up entry for a base type, or nil for a type the list does not carry.
    public static func choice(named base: String, dialect: SQLDialect) -> ColumnTypeChoice? {
        let lower = base.lowercased()
        return choices(for: dialect).first { $0.name == lower }
    }

    static let unsignedChoices = ["", "unsigned", "unsigned zerofill"]
    static let zoneChoices = ["without time zone", "with time zone"]

    /// SQLite stores by affinity, so the names are conventions rather than types; these
    /// are the ones its documentation lists, plus the aliases the app reads specially.
    static let sqlite: [ColumnTypeChoice] = [
        ColumnTypeChoice("integer"),
        ColumnTypeChoice("real"),
        ColumnTypeChoice("text"),
        ColumnTypeChoice("blob"),
        ColumnTypeChoice("numeric", takesLength: true, takesDecimals: true),
        ColumnTypeChoice("boolean"),
        ColumnTypeChoice("varchar", takesLength: true),
        ColumnTypeChoice("date"),
        ColumnTypeChoice("time"),
        ColumnTypeChoice("datetime"),
        ColumnTypeChoice("timestamp"),
        ColumnTypeChoice("json"),
        ColumnTypeChoice("uuid"),
        ColumnTypeChoice("any"),
    ]

    static let mysql: [ColumnTypeChoice] = [
        ColumnTypeChoice("tinyint", takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice("smallint", takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice("mediumint", takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice("int", takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice("bigint", takesLength: true, suffixes: unsignedChoices),
        ColumnTypeChoice("decimal", takesLength: true, takesDecimals: true, suffixes: unsignedChoices),
        ColumnTypeChoice("float", takesLength: true, takesDecimals: true, suffixes: unsignedChoices),
        ColumnTypeChoice("double", takesLength: true, takesDecimals: true, suffixes: unsignedChoices),
        ColumnTypeChoice("bit", takesLength: true),
        ColumnTypeChoice("boolean"),
        ColumnTypeChoice("char", takesLength: true),
        ColumnTypeChoice("varchar", takesLength: true),
        ColumnTypeChoice("tinytext"),
        ColumnTypeChoice("text"),
        ColumnTypeChoice("mediumtext"),
        ColumnTypeChoice("longtext"),
        ColumnTypeChoice("binary", takesLength: true),
        ColumnTypeChoice("varbinary", takesLength: true),
        ColumnTypeChoice("tinyblob"),
        ColumnTypeChoice("blob"),
        ColumnTypeChoice("mediumblob"),
        ColumnTypeChoice("longblob"),
        ColumnTypeChoice("enum"),
        ColumnTypeChoice("set"),
        ColumnTypeChoice("json"),
        ColumnTypeChoice("date"),
        ColumnTypeChoice("time", takesLength: true),
        ColumnTypeChoice("datetime", takesLength: true),
        ColumnTypeChoice("timestamp", takesLength: true),
        ColumnTypeChoice("year"),
        ColumnTypeChoice("geometry"),
        ColumnTypeChoice("point"),
    ]

    static let postgresql: [ColumnTypeChoice] = [
        ColumnTypeChoice("smallint"),
        ColumnTypeChoice("integer"),
        ColumnTypeChoice("bigint"),
        ColumnTypeChoice("numeric", takesLength: true, takesDecimals: true),
        ColumnTypeChoice("real"),
        ColumnTypeChoice("double precision"),
        ColumnTypeChoice("smallserial"),
        ColumnTypeChoice("serial"),
        ColumnTypeChoice("bigserial"),
        ColumnTypeChoice("boolean"),
        ColumnTypeChoice("character", takesLength: true),
        ColumnTypeChoice("character varying", takesLength: true),
        ColumnTypeChoice("text"),
        ColumnTypeChoice("uuid"),
        ColumnTypeChoice("json"),
        ColumnTypeChoice("jsonb"),
        ColumnTypeChoice("bytea"),
        ColumnTypeChoice("date"),
        // PostgreSQL writes the precision before the zone words — `timestamp(6) with
        // time zone` — so the zone is a modifier of `time`/`timestamp`, not part of the base.
        ColumnTypeChoice("time", takesLength: true, suffixes: zoneChoices),
        ColumnTypeChoice("timestamp", takesLength: true, suffixes: zoneChoices),
        ColumnTypeChoice("interval"),
        ColumnTypeChoice("inet"),
        ColumnTypeChoice("cidr"),
        ColumnTypeChoice("macaddr"),
        ColumnTypeChoice("point"),
        ColumnTypeChoice("geometry"),
        ColumnTypeChoice("tsvector"),
        ColumnTypeChoice("xml"),
        ColumnTypeChoice("money"),
        ColumnTypeChoice("bit", takesLength: true),
        ColumnTypeChoice("bit varying", takesLength: true),
    ]
}
