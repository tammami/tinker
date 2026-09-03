import Foundation

/// Expands snippet placeholders: `${1:table}` becomes `table` and is where the caret
/// should land, `$1` becomes nothing, `$0` marks the final caret position.
///
/// The syntax is the one editors share, so a snippet copied from elsewhere works unchanged.
public enum SnippetTemplate {
    public struct Expansion: Sendable, Hashable {
        public let text: String
        /// UTF-16 range of the first placeholder's default text, to select after insertion.
        public let selection: Range<Int>?
    }

    public static func expand(_ template: String) -> Expansion {
        var output = ""
        output.reserveCapacity(template.utf16.count)
        var firstRange: Range<Int>?
        var finalCaret: Int?
        var index = template.startIndex

        while index < template.endIndex {
            let character = template[index]
            guard character == "$" else {
                output.append(character)
                index = template.index(after: index)
                continue
            }
            let next = template.index(after: index)
            guard next < template.endIndex else {
                output.append(character)
                break
            }
            if template[next] == "{" {
                // `${n:default}` or `${n}`.
                guard let close = template[next...].firstIndex(of: "}") else {
                    output.append(character)
                    index = next
                    continue
                }
                let inner = template[template.index(after: next) ..< close]
                let parts = inner.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                let number = Int(parts.first ?? "")
                let fallback = parts.count > 1 ? String(parts[1]) : ""
                let start = output.utf16.count
                output += fallback
                if number == 0 {
                    finalCaret = start
                } else if firstRange == nil, !fallback.isEmpty {
                    firstRange = start ..< output.utf16.count
                } else if firstRange == nil, number != nil {
                    firstRange = start ..< start
                }
                index = template.index(after: close)
            } else if template[next].isNumber {
                // `$n`: a bare tab stop.
                var end = next
                while end < template.endIndex, template[end].isNumber { end = template.index(after: end) }
                let number = Int(template[next ..< end])
                let position = output.utf16.count
                if number == 0 {
                    finalCaret = position
                } else if firstRange == nil {
                    firstRange = position ..< position
                }
                index = end
            } else {
                output.append(character)
                index = next
            }
        }
        let selection = firstRange ?? finalCaret.map { $0 ..< $0 }
        return Expansion(text: output, selection: selection)
    }
}
