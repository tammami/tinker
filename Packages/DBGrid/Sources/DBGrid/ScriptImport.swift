import DBCore
import Foundation

/// Where a file import stands: how much of the file is behind, and what the server
/// has taken.
public struct ScriptImportProgress: Sendable, Hashable {
    public var bytesRead: Int64 = 0
    public var totalBytes: Int64 = 0
    public var execution = ScriptExecutionProgress()

    public var fraction: Double {
        totalBytes > 0 ? min(1, Double(bytesRead) / Double(totalBytes)) : 0
    }

    public init() {}
}

/// The producer's side of an import: bytes read, shared with the consumer's reports.
private actor ImportState {
    var bytesRead: Int64 = 0
    let totalBytes: Int64

    init(totalBytes: Int64) {
        self.totalBytes = totalBytes
    }

    func note(bytesRead: Int64) {
        self.bytesRead = bytesRead
    }
}

/// Runs a `.sql` or `.sql.gz` file against one connection, streaming end to end.
///
/// One task reads and splits the file, one runs statements, and a bounded channel
/// between them holds a few statements at most — which is what lets a file larger
/// than memory, with hundreds of millions of rows, import without the app growing.
public enum ScriptImportRunner {
    public static func run(
        url: URL,
        dialect: SQLDialect,
        options: ScriptExecutionOptions,
        on connection: any SQLConnection,
        progress: @escaping @Sendable (ScriptImportProgress) -> Void
    ) async throws -> ScriptExecutionOutcome {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let state = ImportState(totalBytes: (attributes[.size] as? NSNumber)?.int64Value ?? 0)
        let channel = ScriptChannel()
        let executor = ScriptExecutor(dialect: dialect, options: options)

        return try await withThrowingTaskGroup(of: ScriptExecutionOutcome?.self) { group in
            group.addTask {
                do {
                    let source = try ScriptByteSource(url: url)
                    var splitter = IncrementalStatementSplitter(dialect: dialect)
                    while let piece = try source.next() {
                        try Task.checkCancellation()
                        for chunk in splitter.feed(piece) { try await channel.send(chunk) }
                        await state.note(bytesRead: source.bytesRead)
                    }
                    for chunk in splitter.finish() { try await channel.send(chunk) }
                    await channel.finish()
                } catch is CancellationError {
                    // The executor closed the channel: it stopped, and so does the reader.
                    await channel.finish()
                } catch {
                    await channel.finish(error)
                }
                return nil
            }
            group.addTask {
                try await executor.run(channel, on: connection) { execution in
                    Task {
                        var report = ScriptImportProgress()
                        report.bytesRead = await state.bytesRead
                        report.totalBytes = state.totalBytes
                        report.execution = execution
                        progress(report)
                    }
                }
            }
            var outcome: ScriptExecutionOutcome?
            do {
                while let result = try await group.next() {
                    if let result { outcome = result }
                }
            } catch {
                await channel.close()
                group.cancelAll()
                throw error
            }
            guard let outcome else { throw DBError.protocolError("the import finished without a result") }
            var final = ScriptImportProgress()
            final.bytesRead = await state.bytesRead
            final.totalBytes = state.totalBytes
            final.execution.statements = outcome.statements
            final.execution.rows = outcome.rows
            final.execution.errors = outcome.failures.count
            final.execution.elapsed = outcome.duration
            progress(final)
            return outcome
        }
    }
}

/// Where a copy between connections stands: the dump side and the load side.
public struct TransferProgress: Sendable, Hashable {
    public var dump = DumpProgress()
    public var execution = ScriptExecutionProgress()

    public init() {}
}

public struct TransferOutcome: Sendable, Hashable {
    public var dump = DumpOutcome()
    public var execution = ScriptExecutionOutcome()

    public init() {}
}

/// Copies objects from one connection straight into another — Navicat's copy and
/// paste — by piping the dumper into the executor with nothing on disk in between.
///
/// The two connections may be on different servers and speak different dialects: the
/// dumper reads in the source's and writes in the target's (`SchemaTranslator` carries the
/// structure across). Rows go through the bounded channel a batch at a time, so a table of
/// any size crosses with the memory of one batch.
public enum TransferRunner {
    public static func run(
        _ selection: DumpSelection,
        from source: any SQLConnection,
        to target: any SQLConnection,
        dialect: SQLDialect,
        targetDialect: SQLDialect? = nil,
        options: DumpOptions,
        renaming: DumpRenaming,
        execution: ScriptExecutionOptions = ScriptExecutionOptions(),
        progress: @escaping @Sendable (TransferProgress) -> Void
    ) async throws -> TransferOutcome {
        let channel = ScriptChannel()
        let dumper = DatabaseDumper(dialect: dialect, targetDialect: targetDialect, options: options, renaming: renaming)
        let executor = ScriptExecutor(dialect: targetDialect ?? dialect, options: execution)
        let shared = TransferState()

        return try await withThrowingTaskGroup(of: Either.self) { group in
            group.addTask {
                do {
                    let outcome = try await dumper.run(selection, on: source, into: channel) { dump in
                        Task {
                            await shared.note(dump: dump)
                            progress(await shared.snapshot)
                        }
                    }
                    return .dump(outcome)
                } catch is CancellationError {
                    await channel.finish()
                    return .dump(DumpOutcome())
                }
            }
            group.addTask {
                let outcome = try await executor.run(channel, on: target) { execution in
                    Task {
                        await shared.note(execution: execution)
                        progress(await shared.snapshot)
                    }
                }
                return .execution(outcome)
            }
            var result = TransferOutcome()
            do {
                while let next = try await group.next() {
                    switch next {
                    case let .dump(outcome): result.dump = outcome
                    case let .execution(outcome): result.execution = outcome
                    }
                }
            } catch {
                await channel.close()
                group.cancelAll()
                throw error
            }
            return result
        }
    }

    private enum Either: Sendable {
        case dump(DumpOutcome)
        case execution(ScriptExecutionOutcome)
    }

    private actor TransferState {
        private var current = TransferProgress()
        var snapshot: TransferProgress { current }
        func note(dump: DumpProgress) { current.dump = dump }
        func note(execution: ScriptExecutionProgress) { current.execution = execution }
    }
}
