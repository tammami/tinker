import DBCore
import DBSQL
import Foundation

/// A pending change to one loaded row.
public struct RowEdit: Sendable, Hashable {
    /// Absolute row index in the result set.
    public let rowIndex: Int
    /// New values by column name. Only columns the user actually changed.
    public var changes: [String: DBValue]
    /// Identity-column values as the row was loaded, which is what the WHERE clause uses.
    public let originalIdentity: [String: DBValue]

    public init(rowIndex: Int, changes: [String: DBValue] = [:], originalIdentity: [String: DBValue]) {
        self.rowIndex = rowIndex
        self.changes = changes
        self.originalIdentity = originalIdentity
    }
}

/// A row the user added but has not committed.
public struct PendingInsert: Sendable, Hashable, Identifiable {
    public let id: UUID
    /// Values by column name; unset columns take their server-side default.
    public var values: [String: DBValue]

    public init(id: UUID = UUID(), values: [String: DBValue] = [:]) {
        self.id = id
        self.values = values
    }
}

/// How a cell should be drawn while changes are pending (SPEC §12.3).
public enum CellChangeState: Sendable, Hashable {
    case unchanged
    case edited
    case inserted
    case deleted
}

/// Which pending changes a commit takes.
public enum CommitScope: Sendable, Hashable {
    /// Every pending change: updates, deletes and new rows.
    case everything
    /// Only changes to rows the server already has. New rows stay pending, so a row the
    /// user is still filling in is not written half done.
    case loadedRowsOnly
}

/// Everything the user has changed in a grid but not yet committed.
///
/// Nothing reaches the server until the commit runs: the buffer is an overlay the grid
/// reads through, and discarding it restores the loaded values exactly (SPEC §12.3).
public struct EditBuffer: Sendable {
    private var edits: [Int: RowEdit] = [:]
    private var deletions: Set<Int> = []
    private var deletionIdentities: [Int: [String: DBValue]] = [:]
    private var insertions: [PendingInsert] = []

    public init() {}

    public var isEmpty: Bool { edits.isEmpty && deletions.isEmpty && insertions.isEmpty }

    /// How many statements a commit would run.
    public var pendingStatementCount: Int {
        edits.count { !$0.value.changes.isEmpty } + deletions.count + insertions.count
    }

    public var editedRowIndices: Set<Int> { Set(edits.keys.filter { !(edits[$0]?.changes.isEmpty ?? true) }) }
    public var deletedRowIndices: Set<Int> { deletions }
    public var pendingInserts: [PendingInsert] { insertions }

    // MARK: - Reading through the overlay

    /// The value the grid should show: the pending change if there is one, else `loaded`.
    public func value(row: Int, column: String, loaded: DBValue) -> DBValue {
        edits[row]?.changes[column] ?? loaded
    }

    public func state(row: Int, column: String) -> CellChangeState {
        if deletions.contains(row) { return .deleted }
        if edits[row]?.changes[column] != nil { return .edited }
        return .unchanged
    }

    public func rowState(_ row: Int) -> CellChangeState {
        if deletions.contains(row) { return .deleted }
        if !(edits[row]?.changes.isEmpty ?? true) { return .edited }
        return .unchanged
    }

    // MARK: - Recording changes

    /// Records a cell edit. Setting a cell back to its loaded value clears the edit, so a
    /// user who changes their mind leaves nothing pending.
    public mutating func setValue(
        _ value: DBValue,
        row: Int,
        column: String,
        loaded: DBValue,
        identity: [String: DBValue]
    ) {
        var edit = edits[row] ?? RowEdit(rowIndex: row, originalIdentity: identity)
        if value == loaded {
            edit.changes.removeValue(forKey: column)
        } else {
            edit.changes[column] = value
        }
        if edit.changes.isEmpty {
            edits.removeValue(forKey: row)
        } else {
            edits[row] = edit
        }
    }

    /// Marks a loaded row for deletion, remembering how to find it.
    public mutating func markDeleted(row: Int, identity: [String: DBValue]) {
        deletions.insert(row)
        deletionIdentities[row] = identity
        // A row being deleted has no use for pending cell edits.
        edits.removeValue(forKey: row)
    }

    public mutating func unmarkDeleted(row: Int) {
        deletions.remove(row)
        deletionIdentities.removeValue(forKey: row)
    }

    @discardableResult
    public mutating func addInsert(_ insert: PendingInsert = PendingInsert()) -> PendingInsert {
        insertions.append(insert)
        return insert
    }

    public mutating func setInsertValue(_ value: DBValue, id: UUID, column: String) {
        guard let index = insertions.firstIndex(where: { $0.id == id }) else { return }
        insertions[index].values[column] = value
    }

    public mutating func removeInsert(id: UUID) {
        insertions.removeAll { $0.id == id }
    }

    public mutating func discardAll() {
        edits.removeAll()
        deletions.removeAll()
        deletionIdentities.removeAll()
        insertions.removeAll()
    }

    /// Drops the changes a commit of `scope` would have written, keeping the rest.
    public mutating func discard(_ scope: CommitScope) {
        switch scope {
        case .everything:
            discardAll()
        case .loadedRowsOnly:
            edits.removeAll()
            deletions.removeAll()
            deletionIdentities.removeAll()
        }
    }

    /// How many statements a commit of `scope` would run.
    public func pendingStatementCount(_ scope: CommitScope) -> Int {
        switch scope {
        case .everything: pendingStatementCount
        case .loadedRowsOnly: pendingStatementCount - insertions.count
        }
    }

    // MARK: - Statement generation

    /// Builds the statements a commit would run, in the order the preview shows them:
    /// updates, then deletes, then inserts.
    ///
    /// Deletes run before inserts so that replacing a row under a unique key works in one
    /// commit, and updates run first because they identify rows by values a later delete
    /// might remove.
    public func statements(
        using generator: DMLGenerator, scope: CommitScope = .everything
    ) throws -> [GeneratedStatement] {
        var statements: [GeneratedStatement] = []
        for row in edits.keys.sorted() {
            guard let edit = edits[row], !edit.changes.isEmpty else { continue }
            statements.append(
                try generator.update(
                    changes: edit.changes, originalIdentity: edit.originalIdentity
                ))
        }
        for row in deletions.sorted() {
            guard let identity = deletionIdentities[row] else {
                throw DMLGeneratorError.noRowIdentity(generator.table)
            }
            statements.append(try generator.delete(originalIdentity: identity))
        }
        guard scope == .everything else { return statements }
        for insert in insertions {
            statements.append(try generator.insert(values: insert.values))
        }
        return statements
    }
}
