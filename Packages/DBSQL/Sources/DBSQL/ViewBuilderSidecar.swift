import DBCore
import Foundation

/// Remembers the query-builder canvas a view was designed with, so the view can be reopened
/// in the builder and edited visually rather than as text.
///
/// A server rewrites a view's definition when it stores it (PostgreSQL reformats it,
/// expands `*`, qualifies names), so the text cannot be parsed back into the canvas
/// reliably. Instead the canvas model is kept here beside a fingerprint of the definition
/// the server held right after it was created. On reopening, the fingerprint is compared
/// against the view's current definition: equal means nothing has changed the view behind
/// the builder's back and the canvas is a faithful picture; different means the view was
/// altered elsewhere and the builder must not pretend to represent it, and the caller falls back to the text editor.
public struct ViewBuilderSidecar: Sendable, Hashable, Codable {
    /// The canvas the view was built from.
    public var model: QueryBuilderModel
    /// A fingerprint of the server's own view definition when this was saved.
    public var definitionFingerprint: String

    public init(model: QueryBuilderModel, serverDefinition: String) {
        self.model = model
        self.definitionFingerprint = Self.fingerprint(serverDefinition)
    }

    /// Whether the server's current definition still matches the one this was saved against.
    public func matches(serverDefinition: String) -> Bool {
        definitionFingerprint == Self.fingerprint(serverDefinition)
    }

    /// A deterministic fingerprint of a view definition, insensitive to the whitespace and
    /// letter-case a server may vary. FNV-1a over the normalised text — deterministic across
    /// runs (unlike `Hasher`) and dependency-free.
    public static func fingerprint(_ definition: String) -> String {
        let normalized = normalize(definition)
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in normalized.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(hash, radix: 16)
    }

    /// Lower-cased, whitespace-collapsed, trailing semicolons and surrounding blanks removed.
    static func normalize(_ definition: String) -> String {
        let lowered = definition.lowercased()
        let collapsed = lowered.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ;"))
    }
}
