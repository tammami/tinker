import Foundation

/// Blanks the secrets a statement can carry before it is kept anywhere.
///
/// Query history is written to the store file, so `CREATE USER … PASSWORD 'x'` must not
/// land there with the password in it; the same goes for the server's error text, which
/// often echoes the statement. Only the quoted literal after the secret-bearing keyword
/// is replaced, so the rest of the statement stays readable in the history list.
public enum SQLRedactor {
    /// What a redacted literal is shown as.
    public static let mask = "'•••'"

    /// Keywords after which a quoted literal is a secret, as regular expressions over the
    /// upper-cased statement: PostgreSQL `PASSWORD '…'`/`ENCRYPTED PASSWORD '…'`, MySQL
    /// `IDENTIFIED BY '…'`/`IDENTIFIED WITH plugin BY '…'`/`IDENTIFIED WITH plugin AS '…'`,
    /// and `SECRET '…'` (foreign servers, OAuth options).
    private static let patterns: [NSRegularExpression] = {
        let sources = [
            #"(?i)\bPASSWORD\s*(=\s*)?'((?:[^']|'')*)'"#,
            #"(?i)\bIDENTIFIED\s+(?:WITH\s+\S+\s+)?(?:BY|AS)\s+'((?:[^']|'')*)'"#,
            #"(?i)\bSECRET\s*(=\s*)?'((?:[^']|'')*)'"#,
        ]
        return sources.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    /// `sql` with every secret literal replaced by ``mask``.
    public static func redactSecrets(_ sql: String) -> String {
        var text = sql
        for pattern in patterns {
            let whole = NSRange(text.startIndex ..< text.endIndex, in: text)
            // Matches are replaced from the end so earlier ranges stay valid.
            for match in pattern.matches(in: text, range: whole).reversed() {
                let literalIndex = match.numberOfRanges - 1
                guard let range = Range(match.range(at: literalIndex), in: text) else { continue }
                // The captured group excludes the quotes; widen by one on each side.
                let start = text.index(before: range.lowerBound)
                let end = text.index(after: range.upperBound)
                text.replaceSubrange(start ..< end, with: mask)
            }
        }
        return text
    }
}
