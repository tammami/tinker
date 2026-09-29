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
