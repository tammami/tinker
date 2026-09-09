import DBCore
import DBSQL
import Foundation

/// What a data synchronisation is allowed to do to the target.
public struct DataSyncOptions: Sendable, Hashable {
    public var insert = true
    public var update = true
    public var delete = true
    /// Rows per `INSERT` and keys per `DELETE … IN`.
    public var batchRows = 250
    /// Statements per transaction on the target.
    public var commitEvery = 500
    /// Differences kept as examples per table, for the preview.
    public var sampleLimit = 50

    public init() {}
}

/// One example difference, for the preview.
public struct DataSyncSample: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case insert, update, delete
    }

    public let id = UUID()
    public let kind: Kind
    /// The key, as `a=1, b=x`.
    public let key: String
    /// For an update: the columns that differ, as `name: old → new`.
    public let detail: String
}

/// What comparing one table found, and what was done about it.
public struct DataSyncTableReport: Sendable, Hashable, Identifiable {
    public var id: String { source.id }
    public let source: TableRef
    public let target: TableRef
    public var keyColumns: [String] = []
    public var sourceRows: Int64 = 0
    public var targetRows: Int64 = 0
    public var inserts: Int64 = 0
    public var updates: Int64 = 0
    public var deletes: Int64 = 0
    public var applied: Int64 = 0
    public var samples: [DataSyncSample] = []
    /// Why the table was not compared: no key, missing target, no shared columns.
    public var skippedReason: String?
    public var error: String?

    public var isIdentical: Bool { skippedReason == nil && error == nil && inserts + updates + deletes == 0 }
    public var differences: Int64 { inserts + updates + deletes }

    public init(source: TableRef, target: TableRef) {
        self.source = source
        self.target = target
    }
}

public struct DataSyncProgress: Sendable, Hashable {
    public var currentTable: String?
    public var tablesDone = 0
    public var tableCount = 0
    public var rowsCompared: Int64 = 0
    public var inserts: Int64 = 0
    public var updates: Int64 = 0
    public var deletes: Int64 = 0
    public var applied: Int64 = 0

    public init() {}
}

/// Makes a target table's rows match a source table's, or reports what that would take.
///
/// Both sides are read once, ordered by the key in binary order, and merged as they
/// stream: a key on one side only is an insert or a delete, the same key with different
/// values an update. Neither table is ever held in memory, so tables of any size can be
/// compared with the memory of two row batches. Applying runs on a third connection —
/// the target's rows are still being read on the second — in batched transactions, and
/// every `UPDATE` and `DELETE` is by key and checked to have touched exactly what it meant.
public struct DataSynchronizer: Sendable {
    /// The target's dialect: what the changes are written in.
    public let dialect: SQLDialect
    /// The source's dialect, for reading its rows; the same as `dialect` unless the
    /// synchronisation crosses engines.
    public let sourceDialect: SQLDialect
    public let options: DataSyncOptions

    private static let progressInterval: Duration = .milliseconds(250)

    public init(dialect: SQLDialect, sourceDialect: SQLDialect? = nil, options: DataSyncOptions = DataSyncOptions()) {
        self.dialect = dialect
        self.sourceDialect = sourceDialect ?? dialect
        self.options = options
    }

    /// Compares each pair, applying the differences when `writer` is given.
    public func run(
        _ pairs: [(source: TableRef, target: TableRef)],
        source: any SQLConnection,
        target: any SQLConnection,
        writer: (any SQLConnection)?,
        progress: @escaping @Sendable (DataSyncProgress) -> Void
    ) async throws -> [DataSyncTableReport] {
        var reports: [DataSyncTableReport] = []
        var state = DataSyncProgress()
        state.tableCount = pairs.count
        for pair in pairs {
            try Task.checkCancellation()
            state.currentTable = pair.source.name
            progress(state)
            var report = DataSyncTableReport(source: pair.source, target: pair.target)
            do {
                try await synchronize(
                    &report, source: source, target: target, writer: writer, state: &state, progress: progress)
            } catch is CancellationError {
                if let writer, await writer.isInTransaction { try? await writer.rollback() }
                throw CancellationError()
            } catch {
                // What this table's batch had done is undone; the next table starts clean.
                if let writer, await writer.isInTransaction { try? await writer.rollback() }
                report.error = (error as? DBError)?.errorDescription ?? String(describing: error)
            }
            reports.append(report)
            state.tablesDone += 1
            state.inserts += report.inserts
            state.updates += report.updates
            state.deletes += report.deletes
            state.applied += report.applied
            progress(state)
        }
        return reports
    }

    // MARK: - One table

    private func synchronize(
        _ report: inout DataSyncTableReport,
        source: any SQLConnection,
        target: any SQLConnection,
        writer: (any SQLConnection)?,
        state: inout DataSyncProgress,
        progress: @escaping @Sendable (DataSyncProgress) -> Void
    ) async throws {
        let sourceColumns = try await source.introspector.columns(of: report.source)
        let targetColumns = try await target.introspector.columns(of: report.target)
        guard !targetColumns.isEmpty else {
            report.skippedReason = "The target has no table \(report.target.name)."
            return
        }
        guard let key = try await target.introspector.rowIdentity(of: report.target), !key.isEmpty else {
            report.skippedReason = "The target table has no primary key or unique index to match rows by."
            return
        }
        let targetNames = Set(targetColumns.map(\.name))
        let shared = sourceColumns.filter { targetNames.contains($0.name) && !$0.isGenerated }
        guard key.allSatisfy({ name in shared.contains { $0.name == name } }) else {
            report.skippedReason = "The key columns \(key.joined(separator: ", ")) are not all in the source table."
            return
        }
        guard !shared.isEmpty else {
            report.skippedReason = "The tables share no columns."
            return
        }
        report.keyColumns = key
        let keyIndexes = key.compactMap { name in shared.firstIndex { $0.name == name } }
        let valueIndexes = shared.indices.filter { !keyIndexes.contains($0) }
        let columnList = shared.map { Identifier.quote($0.name, dialect: dialect) }.joined(separator: ", ")
        func keyOrder(_ side: SQLDialect) -> String {
            key.map { name -> String in
                let column = shared.first { $0.name == name }
                return Self.binaryOrder(
                    Identifier.quote(name, dialect: side), isText: column?.kind == .string, dialect: side)
            }.joined(separator: ", ")
        }
        let order = keyOrder(dialect)
        let sourceColumnList = shared.map { Identifier.quote($0.name, dialect: sourceDialect) }.joined(separator: ", ")

        var sourceRows = RowCursor(
            source.execute(
                "SELECT \(sourceColumnList) FROM \(Identifier.qualified(report.source, dialect: sourceDialect)) ORDER BY \(keyOrder(sourceDialect))",
                parameters: []))
        var targetRows = RowCursor(
            target.execute(
                "SELECT \(columnList) FROM \(Identifier.qualified(report.target, dialect: dialect)) ORDER BY \(order)",
                parameters: []))
        var applier = writer.map {
            ChangeApplier(
                connection: $0, table: report.target, columns: shared, keyIndexes: keyIndexes, dialect: dialect,
                options: options)
        }

        var left = try await sourceRows.next()
        var right = try await targetRows.next()
        var lastLeftKey: [DBValue]?
        var lastRightKey: [DBValue]?
        var lastReport = ContinuousClock.now
        var compared: Int64 = 0

        func note(_ kind: DataSyncSample.Kind, key: [DBValue], detail: String) {
            guard report.samples.count < options.sampleLimit else { return }
            let keyText = zip(keyIndexes, key).map {
                "\(shared[$0].name)=\(ClipboardFormatter.cellText($1, nullText: "NULL"))"
            }
            .joined(separator: ", ")
            report.samples.append(DataSyncSample(kind: kind, key: keyText, detail: detail))
        }
        func tick() {
            compared += 1
            let now = ContinuousClock.now
            guard now - lastReport >= Self.progressInterval else { return }
            lastReport = now
            var snapshot = state
            snapshot.rowsCompared += compared
            snapshot.inserts += report.inserts
            snapshot.updates += report.updates
            snapshot.deletes += report.deletes
            snapshot.applied += report.applied + (applier?.applied ?? 0)
            progress(snapshot)
        }
        func checkOrder(_ key: [DBValue], previous: inout [DBValue]?, side: String) throws {
            if let previous, Self.compare(key, previous) == .orderedAscending {
                throw DBError.protocolError(
                    "The \(side) rows did not arrive in key order; the key column's collation cannot be compared. Choose a table with a numeric or binary key."
                )
            }
            previous = key
        }

        while left != nil || right != nil {
            try Task.checkCancellation()
            if let leftRow = left, let rightRow = right {
                let leftKey = keyIndexes.map { leftRow[$0] }
                let rightKey = keyIndexes.map { rightRow[$0] }
                try checkOrder(leftKey, previous: &lastLeftKey, side: "source")
                try checkOrder(rightKey, previous: &lastRightKey, side: "target")
                switch Self.compare(leftKey, rightKey) {
                case .orderedSame:
                    // Compared by value rather than by case: across engines the same number
                    // arrives as `.decimal("1.50")` on one side and `.double(1.5)` on the other.
                    let changed = valueIndexes.filter { Self.compareValue(leftRow[$0], rightRow[$0]) != .orderedSame }
                    if !changed.isEmpty {
                        report.updates += 1
                        note(
                            .update, key: leftKey,
                            detail: changed.map {
                                "\(shared[$0].name): \(ClipboardFormatter.cellText(rightRow[$0], nullText: "NULL")) → \(ClipboardFormatter.cellText(leftRow[$0], nullText: "NULL"))"
                            }.joined(separator: "; "))
                        if options.update { try await applier?.update(leftRow) }
                    }
                    report.sourceRows += 1
                    report.targetRows += 1
                    left = try await sourceRows.next()
                    right = try await targetRows.next()
                case .orderedAscending:
                    report.inserts += 1
                    note(.insert, key: leftKey, detail: "")
                    if options.insert { try await applier?.insert(leftRow) }
                    report.sourceRows += 1
                    left = try await sourceRows.next()
                case .orderedDescending:
                    report.deletes += 1
                    note(.delete, key: rightKey, detail: "")
                    if options.delete { try await applier?.delete(rightRow) }
                    report.targetRows += 1
                    right = try await targetRows.next()
                }
            } else if let leftRow = left {
                let leftKey = keyIndexes.map { leftRow[$0] }
                try checkOrder(leftKey, previous: &lastLeftKey, side: "source")
                report.inserts += 1
                note(.insert, key: leftKey, detail: "")
                if options.insert { try await applier?.insert(leftRow) }
                report.sourceRows += 1
                left = try await sourceRows.next()
            } else if let rightRow = right {
                let rightKey = keyIndexes.map { rightRow[$0] }
                try checkOrder(rightKey, previous: &lastRightKey, side: "target")
                report.deletes += 1
                note(.delete, key: rightKey, detail: "")
                if options.delete { try await applier?.delete(rightRow) }
                report.targetRows += 1
                right = try await targetRows.next()
            }
            tick()
        }
        try await applier?.finish()
        report.applied = applier?.applied ?? 0
        state.rowsCompared += compared
    }

    /// `ORDER BY` in an order the merge can reproduce locally: bytewise for text.
    static func binaryOrder(_ column: String, isText: Bool, dialect: SQLDialect) -> String {
        guard isText else { return column }
        switch dialect {
        case .postgresql: return "\(column) COLLATE \"C\""
        case .mysql: return "CAST(\(column) AS BINARY)"
        case .sqlite: return "\(column) COLLATE BINARY"
        }
    }

    // MARK: - Key order

    /// The order the servers put keys in, reproduced locally: numbers by value, text
    /// bytewise, everything else by its server text.
    static func compare(_ a: [DBValue], _ b: [DBValue]) -> ComparisonResult {
        for (x, y) in zip(a, b) {
            let result = compareValue(x, y)
            if result != .orderedSame { return result }
        }
        return a.count == b.count ? .orderedSame : (a.count < b.count ? .orderedAscending : .orderedDescending)
    }

    static func compareValue(_ a: DBValue, _ b: DBValue) -> ComparisonResult {
        switch (a, b) {
        case (.null, .null): return .orderedSame
        case (.null, _): return .orderedDescending
        case (_, .null): return .orderedAscending
        case let (.int(x), .int(y)): return order(x, y)
        case let (.uint(x), .uint(y)): return order(x, y)
        case let (.int(x), .uint(y)): return x < 0 ? .orderedAscending : order(UInt64(x), y)
        case let (.uint(x), .int(y)): return y < 0 ? .orderedDescending : order(x, UInt64(y))
        case let (.double(x), .double(y)): return order(x, y)
        case let (.string(x), .string(y)): return order(Array(x.utf8), Array(y.utf8))
        case let (.bytes(x), .bytes(y)): return order(Array(x), Array(y))
        case let (.bool(x), .bool(y)): return order(x ? 1 : 0, y ? 1 : 0)
        case let (.bool(x), .int(y)): return order(x ? 1 : 0, y)
        case let (.int(x), .bool(y)): return order(x, y ? 1 : 0)
        case let (.uuid(x), .uuid(y)): return order(x.uuidString, y.uuidString)
        default:
            if let x = Decimal(string: a.text ?? ""), let y = Decimal(string: b.text ?? ""),
                a.text?.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) == true,
                b.text?.allSatisfy({ $0.isNumber || $0 == "." || $0 == "-" || $0 == "+" }) == true
            {
                return order(x, y)
            }
            return order(Array((a.text ?? "").utf8), Array((b.text ?? "").utf8))
        }
    }

    private static func order<T: Comparable>(_ x: T, _ y: T) -> ComparisonResult {
        x < y ? .orderedAscending : (x > y ? .orderedDescending : .orderedSame)
    }

    private static func order(_ x: [UInt8], _ y: [UInt8]) -> ComparisonResult {
        for (p, q) in zip(x, y) where p != q { return p < q ? .orderedAscending : .orderedDescending }
        return order(x.count, y.count)
    }
}

/// Pulls rows one at a time out of a streaming result.
struct RowCursor {
    private var iterator: AsyncThrowingStream<QueryEvent, any Error>.AsyncIterator
    private var buffer: [[DBValue]] = []
    private var index = 0
    private var finished = false

    init(_ stream: AsyncThrowingStream<QueryEvent, any Error>) {
        iterator = stream.makeAsyncIterator()
    }

    mutating func next() async throws -> [DBValue]? {
        while index >= buffer.count {
            guard !finished else { return nil }
            guard let event = try await iterator.next() else {
                finished = true
                return nil
            }
            if case let .rows(batch) = event {
                buffer = batch.rows
                index = 0
            }
        }
        defer { index += 1 }
        return buffer[index]
    }
}

/// Writes the differences to the target as they are found, in batched transactions.
struct ChangeApplier {
    let connection: any SQLConnection
    let table: TableRef
    let columns: [ColumnInfo]
    let keyIndexes: [Int]
    let dialect: SQLDialect
    let options: DataSyncOptions
    private(set) var applied: Int64 = 0
    private var pendingInserts: [[DBValue]] = []
    private var pendingDeletes: [[DBValue]] = []
    private var statementsInTransaction = 0
    private var inTransaction = false

    init(
        connection: any SQLConnection, table: TableRef, columns: [ColumnInfo], keyIndexes: [Int], dialect: SQLDialect,
        options: DataSyncOptions
    ) {
        self.connection = connection
        self.table = table
        self.columns = columns
        self.keyIndexes = keyIndexes
        self.dialect = dialect
        self.options = options
    }

    private var qualified: String { Identifier.qualified(table, dialect: dialect) }
    private var keyNames: [String] { keyIndexes.map { Identifier.quote(columns[$0].name, dialect: dialect) } }

    mutating func insert(_ row: [DBValue]) async throws {
        pendingInserts.append(row)
        if pendingInserts.count >= options.batchRows { try await flushInserts() }
    }

    mutating func delete(_ row: [DBValue]) async throws {
        pendingDeletes.append(keyIndexes.map { row[$0] })
        if pendingDeletes.count >= options.batchRows { try await flushDeletes() }
    }

    mutating func update(_ row: [DBValue]) async throws {
        try await flushInserts()
        try await flushDeletes()
        try await beginIfNeeded()
        var parameters: [DBValue] = []
        var assignments: [String] = []
        for (index, column) in columns.enumerated() where !keyIndexes.contains(index) {
            parameters.append(row[index])
            assignments.append(
                "\(Identifier.quote(column.name, dialect: dialect)) = \(SQLLiteral.placeholder(parameters.count, dialect: dialect))"
            )
        }
        guard !assignments.isEmpty else { return }
        var conditions: [String] = []
        for index in keyIndexes {
            parameters.append(row[index])
            conditions.append(
                "\(Identifier.quote(columns[index].name, dialect: dialect)) = \(SQLLiteral.placeholder(parameters.count, dialect: dialect))"
            )
        }
        let sql =
            "UPDATE \(qualified) SET \(assignments.joined(separator: ", ")) WHERE \(conditions.joined(separator: " AND "))"
        let result = try await connection.executeCollecting(sql, parameters: parameters)
        // MySQL reports 0 for a row whose new values equal its old ones; that cannot
        // happen here, since only rows that differ are updated.
        if let affected = result.completion.affectedRows, affected != 1 {
            throw DBError.protocolError(
                "an UPDATE by key touched \(affected) rows instead of 1; the target was rolled back")
        }
        applied += 1
        try await noteStatement()
    }

    mutating func finish() async throws {
        try await flushInserts()
        try await flushDeletes()
        if inTransaction {
            try await connection.commit()
            inTransaction = false
        }
    }

    private mutating func beginIfNeeded() async throws {
        guard !inTransaction else { return }
        try await connection.beginTransaction()
        inTransaction = true
        statementsInTransaction = 0
    }

    private mutating func noteStatement() async throws {
        statementsInTransaction += 1
        if statementsInTransaction >= options.commitEvery {
            try await connection.commit()
            inTransaction = false
        }
    }

    private mutating func flushInserts() async throws {
        guard !pendingInserts.isEmpty else { return }
        try await beginIfNeeded()
        let names = columns.map { Identifier.quote($0.name, dialect: dialect) }.joined(separator: ", ")
        var parameters: [DBValue] = []
        var tuples: [String] = []
        for row in pendingInserts {
            var placeholders: [String] = []
            for value in row {
                parameters.append(value)
                placeholders.append(SQLLiteral.placeholder(parameters.count, dialect: dialect))
            }
            tuples.append("(" + placeholders.joined(separator: ", ") + ")")
        }
        let sql = "INSERT INTO \(qualified) (\(names)) VALUES \(tuples.joined(separator: ", "))"
        _ = try await connection.executeCollecting(sql, parameters: parameters)
        applied += Int64(pendingInserts.count)
        pendingInserts.removeAll(keepingCapacity: true)
        try await noteStatement()
    }

    private mutating func flushDeletes() async throws {
        guard !pendingDeletes.isEmpty else { return }
        try await beginIfNeeded()
        let expected = Int64(pendingDeletes.count)
        var parameters: [DBValue] = []
        let sql: String
        if keyIndexes.count == 1, let name = keyNames.first {
            let placeholders = pendingDeletes.map { key -> String in
                parameters.append(key[0])
                return SQLLiteral.placeholder(parameters.count, dialect: dialect)
            }
            sql = "DELETE FROM \(qualified) WHERE \(name) IN (\(placeholders.joined(separator: ", ")))"
        } else {
            let tuples = pendingDeletes.map { key -> String in
                let conditions = zip(keyNames, key).map { name, value -> String in
                    parameters.append(value)
                    return "\(name) = \(SQLLiteral.placeholder(parameters.count, dialect: dialect))"
                }
                return "(" + conditions.joined(separator: " AND ") + ")"
            }
            sql = "DELETE FROM \(qualified) WHERE \(tuples.joined(separator: " OR "))"
        }
        let result = try await connection.executeCollecting(sql, parameters: parameters)
        if let affected = result.completion.affectedRows, affected != expected {
            throw DBError.protocolError(
                "a DELETE by key removed \(affected) rows instead of \(expected); the target was rolled back")
        }
        applied += expected
        pendingDeletes.removeAll(keepingCapacity: true)
        try await noteStatement()
    }
}
