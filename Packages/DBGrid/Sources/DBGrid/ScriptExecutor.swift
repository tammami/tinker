import DBCore
import DBSQL
import Foundation

/// A bounded hand-off between whoever produces a script's chunks — the file reader, the
/// dumper — and whoever consumes them — the executor, the file writer.
///
/// `send` waits while the consumer is behind, so a reader that can pull a file faster
/// than the server takes statements never piles them up in memory; that is the whole
/// reason a multi-gigabyte import stays flat.
public actor ScriptChannel {
    private var items: [ScriptChunk] = []
    private var head = 0
    private let capacity: Int
    private var isFinished = false
    private var isClosed = false
    private var failure: (any Error)?
    private var waitingConsumer: CheckedContinuation<Void, Never>?
    private var waitingProducers: [CheckedContinuation<Void, Never>] = []

    public init(capacity: Int = 32) {
        self.capacity = max(1, capacity)
    }

    /// Hands a chunk over, waiting while the channel is full. Throws once the consumer
    /// has gone away, so the producer stops too.
    public func send(_ chunk: ScriptChunk) async throws {
        while items.count - head >= capacity, !isClosed {
            await withCheckedContinuation { waitingProducers.append($0) }
        }
        if isClosed { throw CancellationError() }
        items.append(chunk)
        waitingConsumer?.resume()
        waitingConsumer = nil
    }

    /// Marks the end of the script. An error is thrown to the consumer once it has
    /// taken everything sent before.
    public func finish(_ error: (any Error)? = nil) {
        isFinished = true
        if failure == nil { failure = error }
        waitingConsumer?.resume()
        waitingConsumer = nil
    }

    /// Stops the producer: every waiting or later `send` throws.
    public func close() {
        isClosed = true
        isFinished = true
        for producer in waitingProducers { producer.resume() }
        waitingProducers.removeAll()
        waitingConsumer?.resume()
        waitingConsumer = nil
    }

    /// The next chunk, or nil once the script has ended.
    public func next() async throws -> ScriptChunk? {
        while head == items.count {
            if isFinished {
                if let failure { throw failure }
                return nil
            }
            await withCheckedContinuation { waitingConsumer = $0 }
        }
        let item = items[head]
        head += 1
        if head >= 64 {
            items.removeFirst(head)
            head = 0
        }
        if !waitingProducers.isEmpty { waitingProducers.removeFirst().resume() }
        return item
    }
}

/// How an executor wraps a script in transactions and reacts to a failing statement.
public struct ScriptExecutionOptions: Sendable, Hashable {
    public enum Transactions: Sendable, Hashable {
        /// Commit after every `statements` statements: the failure of one loses at most
        /// one batch, and neither server has to hold a multi-gigabyte transaction.
        case perBatch(statements: Int)
        /// All or nothing.
        case single
        /// Each statement on its own, as the server's autocommit does.
        case autocommit
    }

    public var transactions: Transactions = .perBatch(statements: 500)
    /// Off means the rest of the script still runs after a failure, each statement on
    /// its own so a failed one cannot take a batch down with it.
    public var stopOnError = true
    /// MySQL: load without checking foreign keys and unique keys, as `mysqldump` output
    /// expects; the checks are turned back on at the end.
    public var disableForeignKeyChecks = true
    public var maximumErrors = 100

    public init() {}
}

/// Where an execution stands, reported at most a few times a second.
public struct ScriptExecutionProgress: Sendable, Hashable {
    public var statements: Int64 = 0
    /// Rows inserted, updated, deleted or copied.
    public var rows: Int64 = 0
    public var errors = 0
    /// The table the last statement touched, when it named one.
    public var currentObject: String?
    public var elapsed: Duration = .zero

    public init() {}
}

/// One statement the server refused, with its message verbatim.
public struct ScriptExecutionFailure: Sendable, Hashable, Identifiable {
    public let id: Int
    public let statementNumber: Int64
    /// Line in the script, when it came from a file.
    public let line: Int?
    public let excerpt: String
    public let message: String

    public init(id: Int, statementNumber: Int64, line: Int?, excerpt: String, message: String) {
        self.id = id
        self.statementNumber = statementNumber
        self.line = line
        self.excerpt = excerpt
        self.message = message
    }

    public var description: String {
        let place = line.map { "line \($0)" } ?? "statement \(statementNumber)"
        return "\(place): \(message)"
    }
}

/// What an execution did, whether it finished or was stopped.
public struct ScriptExecutionOutcome: Sendable, Hashable {
    public var statements: Int64 = 0
    public var rows: Int64 = 0
    public var failures: [ScriptExecutionFailure] = []
    public var duration: Duration = .zero
    public var wasCancelled = false

    public init() {}
}

/// Why an execution stopped before the end of the script.
public enum ScriptExecutionError: Error, Sendable {
    case stopped(ScriptExecutionFailure, ScriptExecutionOutcome)
    case tooManyErrors(ScriptExecutionOutcome)
    case cancelled(ScriptExecutionOutcome)

    public var outcome: ScriptExecutionOutcome {
        switch self {
        case let .stopped(_, outcome), let .tooManyErrors(outcome), let .cancelled(outcome): outcome
        }
    }
}

/// Runs a script's chunks on one connection: statements one at a time, `COPY` blocks
/// through the server's bulk path, in batched transactions, with every failure kept.
///
/// The executor never looks ahead and never keeps a statement it has run, so what it
/// costs in memory is one statement and one `COPY` batch.
public struct ScriptExecutor: Sendable {
    public let dialect: SQLDialect
    public let options: ScriptExecutionOptions

    /// Progress is reported no more often than this.
    private static let progressInterval: Duration = .milliseconds(250)

    public init(dialect: SQLDialect, options: ScriptExecutionOptions = ScriptExecutionOptions()) {
        self.dialect = dialect
        self.options = options
    }

    public func run(
        _ channel: ScriptChannel,
        on connection: any SQLConnection,
        progress: @escaping @Sendable (ScriptExecutionProgress) -> Void
    ) async throws -> ScriptExecutionOutcome {
        let started = ContinuousClock.now
        var outcome = ScriptExecutionOutcome()
        var state = ScriptExecutionProgress()
        var lastReport = started
        var inTransaction = false
        var batchCount = 0
        var failureID = 0
        // A failure while continuing means each statement stands alone.
        let transactions: ScriptExecutionOptions.Transactions = options.stopOnError ? options.transactions : .autocommit

        func report(force: Bool = false) {
            let now = ContinuousClock.now
            guard force || now - lastReport >= Self.progressInterval else { return }
            lastReport = now
            state.elapsed = started.duration(to: now)
            state.statements = outcome.statements
            state.rows = outcome.rows
            state.errors = outcome.failures.count
            progress(state)
        }

        func beginIfNeeded() async throws {
            guard !inTransaction else { return }
            switch transactions {
            case .perBatch, .single:
                try await connection.beginTransaction()
                inTransaction = true
            case .autocommit:
                break
            }
        }

        func commitIfDue(final: Bool) async throws {
            guard inTransaction else { return }
            switch transactions {
            case let .perBatch(size) where final || batchCount >= size:
                try await connection.commit()
                inTransaction = false
                batchCount = 0
            case .single where final:
                try await connection.commit()
                inTransaction = false
            default:
                break
            }
        }

        func rollbackQuietly() async {
            guard inTransaction else { return }
            try? await connection.rollback()
            inTransaction = false
            batchCount = 0
        }

        func finished(cancelled: Bool = false) -> ScriptExecutionOutcome {
            outcome.duration = started.duration(to: .now)
            outcome.wasCancelled = cancelled
            return outcome
        }

        /// A dump sets session state as it goes — `search_path`, timeouts, key checks.
        /// The connection returns to the pool afterwards, so that state is undone here.
        func restoreSession() async {
            switch dialect {
            case .postgresql:
                _ = try? await connection.executeCollecting("RESET ALL")
            case .mysql:
                if options.disableForeignKeyChecks {
                    _ = try? await connection.executeCollecting("SET UNIQUE_CHECKS = 1")
                    _ = try? await connection.executeCollecting("SET FOREIGN_KEY_CHECKS = 1")
                }
            case .sqlite:
                if options.disableForeignKeyChecks {
                    _ = try? await connection.executeCollecting("PRAGMA foreign_keys = ON")
                }
            }
        }

        /// Records a failure and decides whether the run goes on.
        func fail(_ error: any Error, statement: String, line: Int?) async throws {
            failureID += 1
            let failure = ScriptExecutionFailure(
                id: failureID, statementNumber: outcome.statements + 1, line: line,
                excerpt: Self.excerpt(statement),
                message: (error as? DBError)?.errorDescription ?? String(describing: error))
            outcome.failures.append(failure)
            if options.stopOnError {
                await rollbackQuietly()
                await channel.close()
                throw ScriptExecutionError.stopped(failure, finished())
            }
            if outcome.failures.count >= options.maximumErrors {
                await rollbackQuietly()
                await channel.close()
                throw ScriptExecutionError.tooManyErrors(finished())
            }
        }

        do {
            if options.disableForeignKeyChecks {
                switch dialect {
                case .mysql:
                    _ = try await connection.executeCollecting("SET FOREIGN_KEY_CHECKS = 0")
                    _ = try await connection.executeCollecting("SET UNIQUE_CHECKS = 0")
                case .sqlite:
                    // A no-op inside a transaction, so it runs before the batches begin.
                    _ = try await connection.executeCollecting("PRAGMA foreign_keys = OFF")
                case .postgresql:
                    break
                }
            }

            while let chunk = try await channel.next() {
                try Task.checkCancellation()
                switch chunk {
                case let .statement(sql, line):
                    if transactions != .autocommit, Self.isTransactionControl(sql) { continue }
                    try await beginIfNeeded()
                    do {
                        let result = try await connection.executeCollecting(sql)
                        outcome.statements += 1
                        batchCount += 1
                        // A dump's own SELECTs (setval, set_config) return rows too; those
                        // are not rows loaded.
                        if !Self.isQuery(sql) { outcome.rows += max(0, result.completion.affectedRows ?? 0) }
                        if let object = Self.objectName(in: sql) { state.currentObject = object }
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        try await fail(error, statement: sql, line: line)
                    }
                    try await commitIfDue(final: false)

                case let .copyBegin(table, columns, sql):
                    try await beginIfNeeded()
                    state.currentObject = table.name
                    var lines: Int64 = 0
                    var reachedEnd = false
                    let counter = LineCounter()
                    do {
                        try await connection.copyIn(into: table, columns: columns) { writer in
                            while let next = try await channel.next() {
                                switch next {
                                case let .copyLines(data):
                                    try await writer.write(data)
                                    counter.add(data)
                                case .copyEnd:
                                    counter.markEnd()
                                    return
                                default:
                                    throw DBError.protocolError("a COPY block was interrupted by a statement")
                                }
                            }
                            throw DBError.protocolError("the script ended inside a COPY block")
                        }
                        lines = counter.lines
                        reachedEnd = counter.reachedEnd
                        outcome.statements += 1
                        batchCount += 1
                        outcome.rows += lines
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        reachedEnd = counter.reachedEnd
                        // The rows of a failed block still have to be taken off the channel.
                        if !reachedEnd {
                            while let next = try await channel.next() {
                                if case .copyEnd = next { break }
                            }
                        }
                        try await fail(error, statement: sql, line: nil)
                    }
                    try await commitIfDue(final: false)

                case .copyLines, .copyEnd:
                    // Stray pieces of a block that already ended; nothing to run.
                    break
                }
                report()
            }
            try await commitIfDue(final: true)
            await restoreSession()
            report(force: true)
            return finished()
        } catch is CancellationError {
            await rollbackQuietly()
            await channel.close()
            await restoreSession()
            report(force: true)
            throw ScriptExecutionError.cancelled(finished(cancelled: true))
        } catch let error as ScriptExecutionError {
            await restoreSession()
            report(force: true)
            throw error
        } catch {
            // The channel's producer failed — a bad file, a read error.
            await rollbackQuietly()
            await channel.close()
            await restoreSession()
            report(force: true)
            throw error
        }
    }

    /// Counts the rows of a COPY block as they go past; the writer closure cannot
    /// mutate the executor's own locals.
    private final class LineCounter: @unchecked Sendable {
        private(set) var lines: Int64 = 0
        private(set) var reachedEnd = false
        func add(_ data: Data) {
            lines += Int64(data.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) })
        }
        func markEnd() { reachedEnd = true }
    }

    static func isQuery(_ sql: String) -> Bool {
        let statement = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil)
        return ["SELECT", "SHOW", "WITH", "VALUES", "TABLE"].contains(statement.leadingKeyword)
    }

    /// `BEGIN`, `COMMIT` and friends inside a dump are the dump's own transaction plan;
    /// the executor has one already.
    static func isTransactionControl(_ sql: String) -> Bool {
        let statement = SQLStatement(text: sql, utf16Range: 0 ..< 0, startLine: 1, terminator: nil)
        switch statement.leadingKeyword {
        case "BEGIN", "COMMIT", "ROLLBACK", "START":
            return true
        case "SET":
            return sql.range(of: "autocommit", options: .caseInsensitive) != nil
        default:
            return false
        }
    }

    /// The table a data or DDL statement names, for the progress line.
    static func objectName(in sql: String) -> String? {
        let head = sql.prefix(200)
        let words = head.split(whereSeparator: { $0.isWhitespace || $0 == "(" }).map(String.init)
        guard words.count >= 2 else { return nil }
        let first = words[0].uppercased()
        var index: Int?
        switch first {
        case "INSERT", "REPLACE":
            index = words.firstIndex { $0.uppercased() == "INTO" }.map { $0 + 1 }
        case "COPY", "TRUNCATE", "UPDATE":
            index = 1
        case "CREATE", "ALTER", "DROP":
            if let kind = words.dropFirst().first(where: {
                ["TABLE", "VIEW", "INDEX", "FUNCTION", "PROCEDURE", "TRIGGER", "TYPE", "SEQUENCE"].contains(
                    $0.uppercased())
            }),
                let kindIndex = words.firstIndex(of: kind)
            {
                var next = kindIndex + 1
                while next < words.count, ["IF", "NOT", "EXISTS", "OR", "REPLACE"].contains(words[next].uppercased()) {
                    next += 1
                }
                index = next
            }
        case "DELETE":
            index = words.firstIndex { $0.uppercased() == "FROM" }.map { $0 + 1 }
        default:
            return nil
        }
        guard let index, index < words.count else { return nil }
        let raw = words[index].trimmingCharacters(in: CharacterSet(charactersIn: "\"`;,"))
        return raw.isEmpty ? nil : raw
    }

    static func excerpt(_ sql: String) -> String {
        let collapsed = sql.split(whereSeparator: \.isNewline).joined(separator: " ")
        return collapsed.count <= 160 ? collapsed : String(collapsed.prefix(159)) + "…"
    }
}
