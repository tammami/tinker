import DBCore
import Foundation

/// The fixed values a column takes — a MySQL `ENUM` or `SET`, a PostgreSQL enum type — so
/// an editor offers them to pick from rather than a field to type into, where a typo is a
/// server error at best and, on a MySQL without strict mode, an empty value stored silently.
public struct ColumnChoices: Sendable, Hashable {
    /// The permitted labels, in the order the type declares them.
    public let labels: [String]
    /// True for a MySQL `SET`: any combination of the labels, written comma-separated.
    public let allowsMany: Bool
    public let isNullable: Bool

    public init(labels: [String], allowsMany: Bool, isNullable: Bool) {
        self.labels = labels
        self.allowsMany = allowsMany
        self.isNullable = isNullable
    }

    /// The choices a column declares, or nil when it takes free values.
    public init?(column: ColumnInfo) {
        guard let labels = column.enumLabels, !labels.isEmpty else { return nil }
        self.init(
            labels: labels,
            allowsMany: column.nativeType.lowercased().hasPrefix("set("),
            isNullable: column.isNullable)
    }

    /// The choices of every column that has them, by column name.
    public static func byName(_ columns: [ColumnInfo]) -> [String: ColumnChoices] {
        var result: [String: ColumnChoices] = [:]
        for column in columns {
            if let choices = ColumnChoices(column: column) { result[column.name] = choices }
        }
        return result
    }

    /// Whether typed or pasted text is a value the column takes. Empty text means NULL
    /// to the grid, which only a nullable column takes.
    public func accepts(_ text: String) -> Bool {
        if text.isEmpty { return isNullable }
        return allowsMany ? members(of: text) != nil : labels.contains(text)
    }

    /// The labels a `SET` value holds, or nil when a part of it is not a label.
    public func members(of text: String) -> Set<String>? {
        guard !text.isEmpty else { return [] }
        let parts = text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy(labels.contains) else { return nil }
        return Set(parts)
    }

    /// A `SET` value holding `members`, in declaration order, as the server stores it.
    public func text(for members: Set<String>) -> String {
        labels.filter(members.contains).joined(separator: ",")
    }

    /// Why `text` was not written, naming the values that would have been.
    public func refusal(of text: String) -> String {
        if text.isEmpty { return "This column does not take NULL; pick one of its values." }
        let list = labels.map { "“\($0)”" }.joined(separator: ", ")
        return allowsMany
            ? "“\(text)” is not a combination of \(list)."
            : "“\(text)” is not one of \(list)."
    }
}
