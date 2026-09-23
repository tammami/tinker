import DBCore
import DBSQL
import Foundation

/// The statements that would put back what one commit wrote (SPEC §12.3, ADR-0060).
///
/// A commit with auto-commit on is irreversible the moment it lands: the edit buffer is
/// cleared and the undo history with it, because the grid must not offer to undo a state
/// the server no longer has. What the server *does* have can still be put back, though,
/// as long as the values it replaced are known — and they are, because the grid holds the
/// row as it was loaded and the identity it was addressed by.
///
/// The plan is therefore built from the same snapshot the commit writes, **before** it
/// runs: afterwards the page is re-read and the loaded values are the new ones.
public struct RevertPlan: Sendable {
    /// What to run, in an order that mirrors a commit: the inserts' deletes first, then
    /// the deletes' inserts, then the updates' updates.
    public let statements: [GeneratedStatement]
    /// Why this write cannot be put back, in the user's words, when it cannot. One entry
    /// per statement that has no inverse; a write is offered as revertible only when this
    /// is empty, because putting half of it back is worse than putting none.
    public let blocked: [String]

    public init(statements: [GeneratedStatement], blocked: [String] = []) {
        self.statements = statements
        self.blocked = blocked
    }

    public static let nothing = RevertPlan(statements: [], blocked: [])

    public var isRevertible: Bool { blocked.isEmpty && !statements.isEmpty }

    /// The reason to show when the write cannot be put back.
    public var blockedReason: String? { blocked.first }
}

/// Builds a ``RevertPlan`` for what a commit is about to write.
///
/// Every inverse addresses its row by primary key with the values the row will have
/// *after* the write, so it runs through the same one-row check a commit does. An edit's
/// inverse also asks for the values the edit wrote, where they can be compared: a row that
/// changed again since — by a later write from this tab or by anyone else — then matches
/// nothing and fails loudly rather than being overwritten.
public struct RevertPlanner: Sendable {
    public let generator: DMLGenerator
    /// The columns that name a row, in key order.
    public let identityColumns: [String]
    /// Every column of the table, so a deleted row can be put back whole.
    public let columns: [ColumnMeta]

    public init(generator: DMLGenerator, identityColumns: [String], columns: [ColumnMeta]) {
        self.generator = generator
        self.identityColumns = identityColumns
        self.columns = columns
    }

    /// The identity a row will have once `changes` have been written: the values it was
    /// loaded with, with any change to a key column applied. An edit to a primary key
    /// moves the row, and the inverse has to look for it where it now is.
    public static func identityAfter(
        _ originalIdentity: [String: DBValue], changes: [String: DBValue], identityColumns: [String]
    ) -> [String: DBValue] {
        var identity = originalIdentity
        for name in identityColumns {
            if let changed = changes[name] { identity[name] = changed }
        }
        return identity
    }

    /// The inverse of one edited row: the loaded values of exactly the columns the edit
    /// changed, written back to the row wherever the edit left it, and only while the row
    /// still holds what the edit wrote.
    public func inverseOfUpdate(
        changes: [String: DBValue],
        loaded: [String: DBValue],
        originalIdentity: [String: DBValue]
    ) throws -> GeneratedStatement {
        var restored: [String: DBValue] = [:]
        for column in changes.keys {
            // A column the grid never loaded — one hidden from the result — has no known
            // previous value, and guessing NULL would destroy data.
            guard let previous = loaded[column] else { throw RevertError.valueNotLoaded(column) }
            restored[column] = previous
        }
        return try generator.update(
            changes: restored,
            originalIdentity: Self.identityAfter(originalIdentity, changes: changes, identityColumns: identityColumns),
            expecting: changes.filter { canBeMatched(column: $0.key, value: $0.value) }
        )
    }

    /// Whether a column's written value can be asked for again with `=`, and reliably found.
    ///
    /// Not a float, which the server may store rounded; not JSON, an array, `xml` or a type
    /// the app does not model, for which PostgreSQL may have no `=` at all (`json`, `xml`,
    /// `point`). Such a column is written back on the key alone, as a commit writes it.
    func canBeMatched(column: String, value: DBValue) -> Bool {
        let meta = columns.first { $0.name == column }
        if meta?.nativeTypeName.lowercased() == "xml" { return false }
        switch meta?.kind ?? value.kind {
        case .null, .bool, .int, .uint, .decimal, .string, .bytes, .date, .time, .timestamp, .uuid: return true
        case .double, .json, .array, .raw: return false
        }
    }

    /// The inverse of a deleted row: the whole row, back in, exactly as it was loaded.
    ///
    /// - Parameter tableColumns: every column of the table that takes a value, when the
    ///   grid shows a projection of it. The row is put back only when all of them were
    ///   loaded — an `INSERT` of the columns a `SELECT` happened to name would bring the
    ///   row back with the rest as defaults and call that restored — and only they are
    ///   written, so neither a generated column nor an expression goes into the insert.
    public func inverseOfDelete(
        loadedRow: [String: DBValue], tableColumns: Set<String>? = nil
    ) throws -> GeneratedStatement {
        guard !loadedRow.isEmpty else { throw RevertError.rowNotLoaded }
        for name in identityColumns where loadedRow[name] == nil {
            throw RevertError.valueNotLoaded(name)
        }
        guard let tableColumns else { return try generator.insert(values: loadedRow) }
        if let missing = tableColumns.sorted().first(where: { loadedRow[$0] == nil }) {
            throw RevertError.valueNotLoaded(missing)
        }
        return try generator.insert(values: loadedRow.filter { tableColumns.contains($0.key) })
    }

    /// The inverse of a new row: a delete addressed by the key the server gave it.
    public func inverseOfInsert(identity: [String: DBValue]) throws -> GeneratedStatement {
        for name in identityColumns where identity[name] == nil {
            throw RevertError.keyNotReported(name)
        }
        return try generator.delete(originalIdentity: identity)
    }

    /// The identity of a row the server has just inserted, read from what the statement
    /// returned (`INSERT … RETURNING`) or, where the server returns nothing, from the
    /// generated key it reported and the values the user supplied.
    ///
    /// MySQL reports one number, which names the row only when a single auto-increment
    /// column is the key; the rest of a composite key has to come from the row itself.
    public static func insertedIdentity(
        identityColumns: [String],
        supplied: [String: DBValue],
        returnedRow: [DBValue]?,
        returnedColumns: [ColumnMeta],
        lastInsertID: Int64?
    ) -> [String: DBValue]? {
        var identity: [String: DBValue] = [:]
        for name in identityColumns {
            if let returnedRow, let index = returnedColumns.firstIndex(where: { $0.name == name }),
                index < returnedRow.count
            {
                identity[name] = returnedRow[index]
            } else if let supplied = supplied[name], !supplied.isNull {
                identity[name] = supplied
            } else if identityColumns.count == 1, let lastInsertID, lastInsertID > 0 {
                identity[name] = .int(lastInsertID)
            } else {
                return nil
            }
        }
        return identity.isEmpty ? nil : identity
    }
}

/// Why one statement of a write has no inverse.
public enum RevertError: Error, Hashable, CustomStringConvertible {
    /// A column the write changed was not among the ones the grid loaded.
    case valueNotLoaded(String)
    /// The row a delete removed was not loaded, so its values are not known.
    case rowNotLoaded
    /// The server did not say which key the new row got.
    case keyNotReported(String)

    public var description: String {
        switch self {
        case let .valueNotLoaded(column):
            "“\(column)” was not loaded, so its previous value is not known"
        case .rowNotLoaded:
            "the deleted row's values are not in the grid any more"
        case let .keyNotReported(column):
            "the server did not report the new row's “\(column)”"
        }
    }
}
