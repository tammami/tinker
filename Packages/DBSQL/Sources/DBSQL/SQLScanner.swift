import DBCore
import Foundation

/// A cursor over SQL text that knows how to step over the constructs in which a
/// semicolon, a placeholder or a keyword must **not** be recognised: string literals,
/// quoted identifiers, comments and PostgreSQL dollar-quoted bodies.
///
/// Positions are UTF-16 offsets so they map straight onto `NSRange` for the editor.
struct SQLScanner {
    let scalars: [Unicode.Scalar]
    /// Index into ``scalars``.
    var index: Int = 0
    /// UTF-16 offset of ``index`` in the original string.
    var utf16Offset: Int = 0
    /// One-based line number of ``index``.
    var line: Int = 1

    init(_ text: String) {
        scalars = Array(text.unicodeScalars)
    }

    var isAtEnd: Bool { index >= scalars.count }

    func peek(_ lookahead: Int = 0) -> Unicode.Scalar? {
        let position = index + lookahead
        return position < scalars.count ? scalars[position] : nil
    }

    mutating func advance() {
        guard index < scalars.count else { return }
        let scalar = scalars[index]
        if scalar == "\n" { line += 1 }
        utf16Offset += scalar.value > 0xFFFF ? 2 : 1
        index += 1
    }

    mutating func advance(_ count: Int) {
        for _ in 0 ..< count { advance() }
    }

    /// The text between a previously captured scalar index and the current position.
    func text(from start: Int) -> String {
        text(from: start, to: index)
    }

    func text(from start: Int, to end: Int) -> String {
        guard start < end, start >= 0, end <= scalars.count else { return "" }
        var view = String.UnicodeScalarView()
        view.append(contentsOf: scalars[start ..< end])
        return String(view)
    }

    /// True when the scalars at `index` spell `word`, case-insensitively, and the
    /// character after it does not continue an identifier.
    func matchesKeyword(_ word: String, at position: Int) -> Bool {
        let letters = Array(word.unicodeScalars)
        guard position + letters.count <= scalars.count else { return false }
        for (offset, expected) in letters.enumerated() {
            let actual = scalars[position + offset]
            if !Self.equalIgnoringCase(actual, expected) { return false }
        }
        let after = position + letters.count
        if after < scalars.count, Self.isIdentifierScalar(scalars[after]) { return false }
        return true
    }

    static func equalIgnoringCase(_ a: Unicode.Scalar, _ b: Unicode.Scalar) -> Bool {
        if a == b { return true }
        guard a.isASCII, b.isASCII else { return false }
        return a.value | 0x20 == b.value | 0x20 && (a.properties.isAlphabetic && b.properties.isAlphabetic)
    }

    static func isIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "_" || scalar == "$" || scalar.properties.isAlphabetic
            || (scalar.value >= 0x30 && scalar.value <= 0x39)
    }

    /// If the cursor sits on a quoted string, quoted identifier, comment or dollar-quoted
    /// body, consumes the whole construct and returns its text. Otherwise returns nil and
    /// leaves the cursor where it was.
    ///
    /// An unterminated construct consumes to end of input, which is what a half-typed
    /// statement in the editor looks like.
    mutating func consumeQuotedOrComment(dialect: SQLDialect) -> String? {
        guard let scalar = peek() else { return nil }
        let start = index
        switch scalar {
        case "'":
            consumeQuoted(terminator: "'", backslashEscapes: dialect == .mysql)
            return text(from: start)
        case "\"":
            // PostgreSQL: quoted identifier. MySQL: a string literal unless ANSI_QUOTES is
            // set; either way the closing quote is what ends it, so one rule serves both.
            consumeQuoted(terminator: "\"", backslashEscapes: dialect == .mysql)
            return text(from: start)
        case "`" where dialect == .mysql:
            consumeQuoted(terminator: "`", backslashEscapes: false)
            return text(from: start)
        case "-" where peek(1) == "-":
            consumeLineComment()
            return text(from: start)
        case "#" where dialect == .mysql:
            consumeLineComment()
            return text(from: start)
        case "/" where peek(1) == "*":
            consumeBlockComment(nested: dialect == .postgresql)
            return text(from: start)
        case "$" where dialect == .postgresql:
            guard consumeDollarQuoted() else { return nil }
            return text(from: start)
        default:
            return nil
        }
    }

    /// Consumes `'…'`-style text. A doubled terminator is an escaped terminator.
    private mutating func consumeQuoted(terminator: Unicode.Scalar, backslashEscapes: Bool) {
        advance() // opening quote
        while let scalar = peek() {
            if backslashEscapes, scalar == "\\" {
                advance()
                if !isAtEnd { advance() }
                continue
            }
            if scalar == terminator {
                if peek(1) == terminator {
                    advance(2)
                    continue
                }
                advance() // closing quote
                return
            }
            advance()
        }
    }

    private mutating func consumeLineComment() {
        while let scalar = peek(), scalar != "\n" { advance() }
        if peek() == "\n" { advance() }
    }

    private mutating func consumeBlockComment(nested: Bool) {
        advance(2) // `/*`
        var depth = 1
        while depth > 0, let scalar = peek() {
            if nested, scalar == "/", peek(1) == "*" {
                depth += 1
                advance(2)
                continue
            }
            if scalar == "*", peek(1) == "/" {
                depth -= 1
                advance(2)
                continue
            }
            advance()
        }
    }

    /// Consumes `$tag$ … $tag$`. Returns false, without moving, when the `$` starts a
    /// parameter placeholder or an identifier rather than a dollar-quoted body.
    private mutating func consumeDollarQuoted() -> Bool {
        var probe = index + 1
        var tag = String.UnicodeScalarView()
        while probe < scalars.count {
            let scalar = scalars[probe]
            if scalar == "$" { break }
            let isTagScalar = scalar == "_" || scalar.properties.isAlphabetic
                || (!tag.isEmpty && scalar.value >= 0x30 && scalar.value <= 0x39)
            guard isTagScalar else { return false }
            tag.append(scalar)
            probe += 1
        }
        guard probe < scalars.count, scalars[probe] == "$" else { return false }

        let opener = Array("$\(String(tag))$".unicodeScalars)
        advance(opener.count)
        while !isAtEnd {
            if scalars[index] == "$", matchesLiteral(opener, at: index) {
                advance(opener.count)
                return true
            }
            advance()
        }
        return true // unterminated: the rest of the input is inside the body
    }

    private func matchesLiteral(_ literal: [Unicode.Scalar], at position: Int) -> Bool {
        guard position + literal.count <= scalars.count else { return false }
        for (offset, expected) in literal.enumerated() where scalars[position + offset] != expected {
            return false
        }
        return true
    }
}
