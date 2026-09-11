import DBCore
import DBSQL
import Foundation

/// What names a loaded row: the values of its identity columns as the row was loaded.
///
/// Edits are keyed by this, not by the row's position in the grid, so a sort, a filter,
/// another page or a refresh moves the rows and the edits move with them; an edit to
/// the row with id 42 is an edit to that row wherever it is drawn, or not drawn, next.
public struct RowIdentity: Sendable, Hashable {
    public let values: [String: DBValue]

    public init(_ values: [String: DBValue]) {
        self.values = values
    }

    /// A stable order for statement generation, so a commit lists rows the same way
    /// each time: by identity column name, then by value text.
    var sortKey: String {
        values.keys.sorted().map { "\($0)=\(values[$0]?.text ?? "NULL")" }.joined(separator: "|")
    }
}

/// A pending change to one loaded row.
public struct RowEdit: Sendable, Hashable {
    /// New values by column name. Only columns the user actually changed.
    public var changes: [String: DBValue]
    /// Identity-column values as the row was loaded, which is what the WHERE clause uses.
    public let originalIdentity: [String: DBValue]

    public init(changes: [String: DBValue] = [:], originalIdentity: [String: DBValue]) {
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
/// Rows are named by ``RowIdentity``, never by position (ADR-0047).
public struct EditBuffer: Sendable, Equatable {
    private var edits: [RowIdentity: RowEdit] = [:]
    private var deletions: Set<RowIdentity> = []
    private var insertions: [PendingInsert] = []

    public init() {}

    public var isEmpty: Bool { edits.isEmpty && deletions.isEmpty && insertions.isEmpty }

    /// How many statements a commit would run.
    public var pendingStatementCount: Int {
        edits.count { !$0.value.changes.isEmpty } + deletions.count + insertions.count
    }

    public var editedIdentities: Set<RowIdentity> { Set(edits.keys.filter { !(edits[$0]?.changes.isEmpty ?? true) }) }
    public var deletedIdentities: Set<RowIdentity> { deletions }
    public var pendingInserts: [PendingInsert] { insertions }

    // MARK: - Reading through the overlay

    /// The value the grid should show: the pending change if there is one, else `loaded`.
    public func value(identity: RowIdentity, column: String, loaded: DBValue) -> DBValue {
        edits[identity]?.changes[column] ?? loaded
    }

    public func state(identity: RowIdentity, column: String) -> CellChangeState {
        if deletions.contains(identity) { return .deleted }
        if edits[identity]?.changes[column] != nil { return .edited }
        return .unchanged
    }

    public func rowState(identity: RowIdentity) -> CellChangeState {
        if deletions.contains(identity) { return .deleted }
        if !(edits[identity]?.changes.isEmpty ?? true) { return .edited }
        return .unchanged
    }

    // MARK: - Recording changes

    /// Records a cell edit. Setting a cell back to its loaded value clears the edit, so a
    /// user who changes their mind leaves nothing pending.
    public mutating func setValue(
        _ value: DBValue,
        identity: RowIdentity,
        column: String,
        loaded: DBValue
    ) {
        var edit = edits[identity] ?? RowEdit(originalIdentity: identity.values)
        if value == loaded {
            edit.changes.removeValue(forKey: column)
        } else {
            edit.changes[column] = value
        }
        if edit.changes.isEmpty {
            edits.removeValue(forKey: identity)
        } else {
            edits[identity] = edit
        }
    }

    /// Marks a loaded row for deletion.
    public mutating func markDeleted(identity: RowIdentity) {
        deletions.insert(identity)
        // A row being deleted has no use for pending cell edits.
        edits.removeValue(forKey: identity)
    }

    public mutating func unmarkDeleted(identity: RowIdentity) {
        deletions.remove(identity)
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

    /// Drops new rows the user added and never typed into: they hold nothing to write.
    public mutating func removeEmptyInserts() {
        insertions.removeAll { $0.values.isEmpty }
    }

    public mutating func discardAll() {
        edits.removeAll()
        deletions.removeAll()
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
        }
    }

    /// What a commit is about to write, taken before it runs so that only these changes
    /// are cleared afterwards and an edit made while the write was on the wire survives.
    public struct Snapshot: Sendable {
        let edits: [RowIdentity: RowEdit]
        let deletions: Set<RowIdentity>
        let insertions: [PendingInsert]

        public var isEmpty: Bool { edits.isEmpty && deletions.isEmpty && insertions.isEmpty }
    }

    /// The changes a commit of `scope` would write right now.
    public func snapshot(_ scope: CommitScope) -> Snapshot {
        Snapshot(
            edits: edits.filter { !$0.value.changes.isEmpty },
            deletions: deletions,
            insertions: scope == .everything ? insertions : [])
    }

    /// Clears exactly what `snapshot` wrote. A cell changed again since the snapshot was
    /// taken keeps its newer value pending; a new row filled in since stays pending.
    public mutating func remove(committed snapshot: Snapshot) {
        for (identity, written) in snapshot.edits {
            guard var current = edits[identity] else { continue }
            for (column, value) in written.changes where current.changes[column] == value {
                current.changes.removeValue(forKey: column)
            }
            if current.changes.isEmpty {
                edits.removeValue(forKey: identity)
            } else {
                edits[identity] = current
            }
        }
        for identity in snapshot.deletions { deletions.remove(identity) }
        let writtenIDs = Set(snapshot.insertions.map(\.id))
        insertions.removeAll { writtenIDs.contains($0.id) }
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
        try statements(using: generator, snapshot: snapshot(scope))
    }

    /// The statements that write exactly `snapshot`.
    public func statements(using generator: DMLGenerator, snapshot: Snapshot) throws -> [GeneratedStatement] {
        var statements: [GeneratedStatement] = []
        for identity in snapshot.edits.keys.sorted(by: { $0.sortKey < $1.sortKey }) {
            guard let edit = snapshot.edits[identity], !edit.changes.isEmpty else { continue }
            statements.append(
                try generator.update(
                    changes: edit.changes, originalIdentity: edit.originalIdentity
                ))
        }
        for identity in snapshot.deletions.sorted(by: { $0.sortKey < $1.sortKey }) {
            statements.append(try generator.delete(originalIdentity: identity.values))
        }
        for insert in snapshot.insertions {
            statements.append(try generator.insert(values: insert.values))
        }
        return statements
    }
}
