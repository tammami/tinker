import AppKit
import DBCore
import DBGrid
import DBSQL
import Foundation
import Observation

/// Objects picked up from the tree with Copy, waiting for Paste: a whole schema (a
/// MySQL database, a PostgreSQL schema) or some of its tables.
public struct CopiedObjects: Sendable, Hashable {
    public let connectionID: UUID
    public let connectionName: String
    public let dialect: SQLDialect
    public let schema: SchemaRef
    /// nil means everything in the schema: tables, views, routines.
    public let tables: [TableInfo]?

    public var isWholeSchema: Bool { tables == nil }

    /// What the paste menu item says it holds.
    public var label: String {
        if let tables {
            return tables.count == 1 ? "“\(tables[0].name)”" : "\(tables.count) tables"
        }
        return dialect == .mysql ? "database “\(schema.database)”" : "schema “\(schema.schema)”"
    }
}

/// A dump waiting for its sheet.
public struct DumpRequest: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let connectionID: UUID
    public let schema: SchemaRef
    /// nil means the whole schema, with a table picker in the sheet.
    public let tables: [TableInfo]?

    public init(connectionID: UUID, schema: SchemaRef, tables: [TableInfo]? = nil) {
        self.connectionID = connectionID
        self.schema = schema
        self.tables = tables
    }
}

/// A script import waiting for its sheet.
public struct ScriptImportRequest: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let connectionID: UUID
    /// The database the script runs against; nil is the connection's own.
    public let database: String?

    public init(connectionID: UUID, database: String?) {
        self.connectionID = connectionID
        self.database = database
    }
}

/// A paste waiting for its sheet: what was copied and where the tree was clicked.
public struct PasteRequest: Identifiable, Sendable, Hashable {
    public let id = UUID()
    public let source: CopiedObjects
    public let targetConnectionID: UUID
    /// The schema (or MySQL database) clicked, when the paste came from one.
    public let targetSchema: SchemaRef?

    public init(source: CopiedObjects, targetConnectionID: UUID, targetSchema: SchemaRef?) {
        self.source = source
        self.targetConnectionID = targetConnectionID
        self.targetSchema = targetSchema
    }
}

/// Numbers the transfer sheets show, spelled for people.
enum TransferFormat {
    static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    static func count(_ number: Int64) -> String {
        number.formatted(.number.grouping(.automatic))
    }

    static func count(_ number: Int) -> String {
        count(Int64(number))
    }

    static func duration(_ duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        if seconds < 1 { return "\(Int(seconds * 1_000)) ms" }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        let minutes = Int(seconds) / 60
        return String(format: "%d min %02d s", minutes, Int(seconds) % 60)
    }

    static func rate(bytes: Int64, over duration: Duration) -> String {
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard seconds > 0.2 else { return "" }
        return Self.bytes(Int64(Double(bytes) / seconds)) + "/s"
    }
}

/// Runs one dump, import or paste and publishes where it stands.
///
/// The work itself lives in the packages; this owns the task, turns progress into
/// text, keeps the failures the server reported and hands Cancel through.
@MainActor
@Observable
public final class TransferController {
    public enum Phase: Sendable, Hashable {
        case idle
        case running
        case finished
        case failed
        case cancelled
    }

    public private(set) var phase: Phase = .idle
    /// One line saying what is happening right now.
    public private(set) var status = ""
    /// 0…1 when the work has a known size, nil for a spinner.
    public private(set) var fraction: Double?
    public private(set) var failures: [ScriptExecutionFailure] = []
    /// What was done, once finished, in one sentence.
    public private(set) var summary: String?
    /// Why it stopped, verbatim from the server or the file system.
    public private(set) var errorText: String?
    /// The file a dump wrote, for Reveal in Finder.
    public private(set) var writtenURL: URL?
    /// What a data synchronisation found, per table.
    public private(set) var syncReports: [DataSyncTableReport] = []
    /// What a structure synchronisation found.
    public private(set) var schemaResult: SchemaSyncResult?

    private var task: Task<Void, Never>?
    private let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var isRunning: Bool { phase == .running }

    public func cancel() {
        task?.cancel()
    }

    private func begin() {
        phase = .running
        status = "Connecting…"
        fraction = nil
        failures = []
        summary = nil
        errorText = nil
        writtenURL = nil
        syncReports = []
        schemaResult = nil
    }

    /// The session for a schema on a connection: the connection's own, or one on the
    /// schema's database when that is another PostgreSQL database.
    private func session(_ connectionID: UUID, database: String?) throws -> ConnectionSession {
        guard let session = environment.session(for: connectionID, database: database) else {
            throw DBError.notConnected
        }
        return session
    }

    private func requireWritable(_ session: ConnectionSession) async throws {
        if await session.isReadOnly {
            throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L first.")
        }
        _ = try await session.connect()
    }

    // MARK: - Dump

    public func dump(_ request: DumpRequest, tables: [TableInfo], options: DumpOptions, compress: Bool, to url: URL) {
        begin()
        let dialect = environment.connections.first { $0.id == request.connectionID }?.dialect ?? .postgresql
        let serverName = environment.connections.first { $0.id == request.connectionID }?.name ?? ""
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try session(request.connectionID, database: request.schema.database)
                _ = try await session.connect()
                let (lease, connection) = try await session.lease()
                defer { Task { await session.release(lease) } }
                let routines =
                    options.includeRoutines && request.tables == nil
                    ? (try? await connection.introspector.routines(in: request.schema)) ?? [] : []
                let selection = DumpSelection(schema: request.schema, tables: tables, routines: routines)
                let writer = try ScriptFileWriter(url: url, dialect: dialect, compress: compress)
                for line in DatabaseDumper.header(
                    server: serverName, database: request.schema.database, dialect: dialect, options: options)
                {
                    try writer.writeComment(line)
                }
                try writer.writeComment("")
                let channel = ScriptChannel()
                let dumper = DatabaseDumper(dialect: dialect, options: options)
                async let dumped = dumper.run(selection, on: connection, into: channel) { progress in
                    Task { @MainActor [weak self] in self?.show(progress, bytes: nil) }
                }
                do {
                    while let chunk = try await channel.next() {
                        try writer.write(chunk)
                        if Task.isCancelled { throw CancellationError() }
                    }
                } catch {
                    await channel.close()
                    throw error
                }
                let outcome = try await dumped
                try writer.finish()
                writtenURL = url
                summary =
                    "Wrote \(TransferFormat.count(outcome.tables)) table\(outcome.tables == 1 ? "" : "s"), \(TransferFormat.count(outcome.rows)) rows and \(TransferFormat.count(outcome.statements)) statements — \(TransferFormat.bytes(writer.bytesWritten)) in \(TransferFormat.duration(outcome.duration))."
                fraction = 1
                phase = .finished
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: url)
                phase = .cancelled
                status = "Cancelled; the partial file was removed."
            } catch {
                try? FileManager.default.removeItem(at: url)
                fail(error)
            }
        }
    }

    private func show(_ progress: DumpProgress, bytes: Int64?) {
        var parts = [progress.stage]
        if let table = progress.currentTable { parts.append(table) }
        if progress.rows > 0 { parts.append("\(TransferFormat.count(progress.rows)) rows") }
        if progress.tableCount > 0 {
            parts.append("table \(min(progress.tablesDone + 1, progress.tableCount)) of \(progress.tableCount)")
        }
        status = parts.joined(separator: " · ")
        fraction = progress.tableCount > 0 ? Double(progress.tablesDone) / Double(progress.tableCount) : nil
    }

    // MARK: - Import

    public func importScript(_ request: ScriptImportRequest, from url: URL, options: ScriptExecutionOptions) {
        begin()
        let dialect = environment.connections.first { $0.id == request.connectionID }?.dialect ?? .postgresql
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let session = try session(request.connectionID, database: request.database)
                try await requireWritable(session)
                let (lease, connection) = try await session.lease()
                defer {
                    Task {
                        await session.release(lease)
                        await session.invalidateIntrospection()
                    }
                }
                let started = ContinuousClock.now
                let outcome = try await ScriptImportRunner.run(
                    url: url, dialect: dialect, options: options, on: connection
                ) { progress in
                    Task { @MainActor [weak self] in self?.show(progress, since: started) }
                }
                failures = outcome.failures
                summary = Self.summary(of: outcome, prefix: "Imported")
                fraction = 1
                phase = outcome.failures.isEmpty ? .finished : .failed
                if !outcome.failures.isEmpty { errorText = nil }
            } catch let error as ScriptExecutionError {
                finish(with: error)
            } catch is CancellationError {
                phase = .cancelled
                status = "Cancelled; the last batch was rolled back."
            } catch {
                fail(error)
            }
        }
    }

    private func show(_ progress: ScriptImportProgress, since started: ContinuousClock.Instant) {
        var parts: [String] = []
        if progress.totalBytes > 0 {
            parts.append("\(TransferFormat.bytes(progress.bytesRead)) of \(TransferFormat.bytes(progress.totalBytes))")
            let rate = TransferFormat.rate(bytes: progress.bytesRead, over: started.duration(to: .now))
            if !rate.isEmpty { parts.append(rate) }
        }
        parts.append("\(TransferFormat.count(progress.execution.statements)) statements")
        parts.append("\(TransferFormat.count(progress.execution.rows)) rows")
        if let object = progress.execution.currentObject { parts.append(object) }
        if progress.execution.errors > 0 { parts.append("\(progress.execution.errors) errors") }
        status = parts.joined(separator: " · ")
        fraction = progress.totalBytes > 0 ? progress.fraction : nil
    }

    // MARK: - Paste

    public func paste(
        _ request: PasteRequest,
        tables: [TableInfo],
        target: SchemaRef,
        createDatabase: Bool,
        renaming: DumpRenaming,
        options: DumpOptions
    ) {
        begin()
        let dialect = request.source.dialect
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let sourceSession = try session(request.source.connectionID, database: request.source.schema.database)
                _ = try await sourceSession.connect()
                // A new database is made on the connection's own session first; the load
                // then runs on a session opened onto it.
                if createDatabase {
                    let main = try session(request.targetConnectionID, database: nil)
                    try await requireWritable(main)
                    let (lease, connection) = try await main.lease()
                    let name = Identifier.quote(target.database, dialect: dialect)
                    let statement =
                        dialect == .mysql ? "CREATE DATABASE IF NOT EXISTS \(name)" : "CREATE DATABASE \(name)"
                    do {
                        _ = try await connection.executeCollecting(statement)
                    } catch {
                        await main.release(lease)
                        throw error
                    }
                    await main.release(lease)
                    await main.invalidateIntrospection()
                }
                let targetSession = try session(
                    request.targetConnectionID, database: dialect == .postgresql ? target.database : nil)
                try await requireWritable(targetSession)
                let (sourceLease, source) = try await sourceSession.lease()
                let (targetLease, destination) = try await targetSession.lease()
                defer {
                    Task {
                        await sourceSession.release(sourceLease)
                        await targetSession.release(targetLease)
                        await targetSession.invalidateIntrospection()
                        if let main = environment.session(for: request.targetConnectionID) {
                            await main.invalidateIntrospection()
                        }
                    }
                }
                let routines =
                    request.source.isWholeSchema && options.includeRoutines
                    ? (try? await source.introspector.routines(in: request.source.schema)) ?? [] : []
                let selection = DumpSelection(schema: request.source.schema, tables: tables, routines: routines)
                let outcome = try await TransferRunner.run(
                    selection, from: source, to: destination, dialect: dialect, options: options, renaming: renaming
                ) { progress in
                    Task { @MainActor [weak self] in self?.show(progress) }
                }
                failures = outcome.execution.failures
                summary = Self.summary(of: outcome.execution, prefix: "Pasted")
                fraction = 1
                phase = outcome.execution.failures.isEmpty ? .finished : .failed
            } catch let error as ScriptExecutionError {
                finish(with: error)
            } catch is CancellationError {
                phase = .cancelled
                status = "Cancelled; the last batch was rolled back."
            } catch {
                fail(error)
            }
        }
    }

    private func show(_ progress: TransferProgress) {
        var parts = [progress.dump.stage]
        if let table = progress.dump.currentTable { parts.append(table) }
        if progress.execution.rows > 0 { parts.append("\(TransferFormat.count(progress.execution.rows)) rows over") }
        if progress.dump.tableCount > 0 {
            parts.append(
                "table \(min(progress.dump.tablesDone + 1, progress.dump.tableCount)) of \(progress.dump.tableCount)")
        }
        status = parts.joined(separator: " · ")
        fraction =
            progress.dump.tableCount > 0 ? Double(progress.dump.tablesDone) / Double(progress.dump.tableCount) : nil
    }

    // MARK: - Outcomes

    private static func summary(of outcome: ScriptExecutionOutcome, prefix: String) -> String {
        var text =
            "\(prefix) \(TransferFormat.count(outcome.rows)) rows in \(TransferFormat.count(outcome.statements)) statements, \(TransferFormat.duration(outcome.duration))."
        if !outcome.failures.isEmpty {
            text += " \(outcome.failures.count) statement\(outcome.failures.count == 1 ? "" : "s") failed."
        }
        return text
    }

    private func finish(with error: ScriptExecutionError) {
        let outcome = error.outcome
        failures = outcome.failures
        switch error {
        case let .stopped(failure, _):
            errorText = failure.message
            status =
                "Stopped at \(failure.line.map { "line \($0)" } ?? "statement \(failure.statementNumber)") after \(TransferFormat.count(outcome.statements)) statements."
            phase = .failed
        case .tooManyErrors:
            errorText = "Stopped after \(outcome.failures.count) errors."
            phase = .failed
        case .cancelled:
            status =
                "Cancelled after \(TransferFormat.count(outcome.statements)) statements; the last batch was rolled back."
            phase = .cancelled
        }
    }

    private func fail(_ error: any Error) {
        errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        phase = .failed
    }

    // MARK: - Data synchronisation

    /// Compares the pairs and, when `apply` is set, makes the target rows match.
    public func synchronizeData(
        pairs: [(source: TableRef, target: TableRef)],
        sourceConnectionID: UUID,
        targetConnectionID: UUID,
        dialect: SQLDialect,
        options: DataSyncOptions,
        apply: Bool
    ) {
        begin()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let sourceSession = try session(sourceConnectionID, database: pairs.first?.source.database)
                let targetSession = try session(
                    targetConnectionID, database: dialect == .postgresql ? pairs.first?.target.database : nil)
                _ = try await sourceSession.connect()
                if apply { try await requireWritable(targetSession) } else { _ = try await targetSession.connect() }
                let (sourceLease, source) = try await sourceSession.lease()
                let (targetLease, target) = try await targetSession.lease()
                // Applying needs a third connection: the target's rows are being read on the second.
                let writerLease: (ConnectionSession.Lease, any SQLConnection)? =
                    apply ? try await targetSession.lease() : nil
                defer {
                    Task {
                        await sourceSession.release(sourceLease)
                        await targetSession.release(targetLease)
                        if let writerLease { await targetSession.release(writerLease.0) }
                        if apply { await targetSession.invalidateIntrospection() }
                    }
                }
                let synchronizer = DataSynchronizer(dialect: dialect, options: options)
                let reports = try await synchronizer.run(
                    pairs, source: source, target: target, writer: writerLease?.1
                ) { progress in
                    Task { @MainActor [weak self] in self?.show(progress) }
                }
                syncReports = reports
                let differences = reports.reduce(0) { $0 + $1.differences }
                let applied = reports.reduce(0) { $0 + $1.applied }
                let errors = reports.filter { $0.error != nil }.count
                summary =
                    apply
                    ? "Applied \(TransferFormat.count(applied)) change\(applied == 1 ? "" : "s") across \(reports.count) table\(reports.count == 1 ? "" : "s")."
                    : "\(TransferFormat.count(differences)) difference\(differences == 1 ? "" : "s") across \(reports.count) table\(reports.count == 1 ? "" : "s")."
                if errors > 0 { summary = (summary ?? "") + " \(errors) table\(errors == 1 ? "" : "s") failed." }
                fraction = 1
                phase = errors == 0 ? .finished : .failed
            } catch is CancellationError {
                phase = .cancelled
                status = "Cancelled; the last batch was rolled back."
            } catch {
                fail(error)
            }
        }
    }

    private func show(_ progress: DataSyncProgress) {
        var parts: [String] = []
        if let table = progress.currentTable { parts.append(table) }
        parts.append("\(TransferFormat.count(progress.rowsCompared)) rows compared")
        parts.append(
            "+\(TransferFormat.count(progress.inserts)) ~\(TransferFormat.count(progress.updates)) −\(TransferFormat.count(progress.deletes))"
        )
        if progress.applied > 0 { parts.append("\(TransferFormat.count(progress.applied)) applied") }
        if progress.tableCount > 0 {
            parts.append("table \(min(progress.tablesDone + 1, progress.tableCount)) of \(progress.tableCount)")
        }
        status = parts.joined(separator: " · ")
        fraction = progress.tableCount > 0 ? Double(progress.tablesDone) / Double(progress.tableCount) : nil
    }

    // MARK: - Structure synchronisation

    public func compareStructure(
        sourceSchema: SchemaRef, sourceConnectionID: UUID, targetSchema: SchemaRef, targetConnectionID: UUID,
        dialect: SQLDialect, tables: Set<String>?
    ) {
        begin()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let sourceSession = try session(sourceConnectionID, database: sourceSchema.database)
                let targetSession = try session(
                    targetConnectionID, database: dialect == .postgresql ? targetSchema.database : nil)
                _ = try await sourceSession.connect()
                _ = try await targetSession.connect()
                let (sourceLease, source) = try await sourceSession.lease()
                let (targetLease, target) = try await targetSession.lease()
                defer {
                    Task {
                        await sourceSession.release(sourceLease)
                        await targetSession.release(targetLease)
                    }
                }
                let result = try await SchemaSynchronizer(dialect: dialect).compare(
                    sourceSchema: sourceSchema, targetSchema: targetSchema, tables: tables,
                    source: source.introspector, target: target.introspector
                ) { table in
                    Task { @MainActor [weak self] in self?.status = "Comparing \(table)…" }
                }
                schemaResult = result
                let differing = result.differing.count
                let destructive = result.items.reduce(0) { $0 + $1.destructiveCount }
                summary =
                    differing == 0
                    ? "The target already matches the source."
                    : "\(differing) table\(differing == 1 ? "" : "s") differ"
                        + (destructive > 0
                            ? ", \(destructive) statement\(destructive == 1 ? "" : "s") destructive." : ".")
                fraction = 1
                phase = .finished
            } catch is CancellationError {
                phase = .cancelled
                status = "Cancelled."
            } catch {
                fail(error)
            }
        }
    }

    /// Runs generated DDL on the target, one statement at a time, stopping at the first refusal.
    public func runStatements(_ statements: [GeneratedDDL], connectionID: UUID, database: String?, dialect: SQLDialect)
    {
        begin()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let targetSession = try session(connectionID, database: dialect == .postgresql ? database : nil)
                try await requireWritable(targetSession)
                let (lease, connection) = try await targetSession.lease()
                defer {
                    Task {
                        await targetSession.release(lease)
                        await targetSession.invalidateIntrospection()
                    }
                }
                var done = 0
                for statement in statements {
                    try Task.checkCancellation()
                    status = "Running \(done + 1) of \(statements.count): \(statement.table.name)"
                    fraction = Double(done) / Double(max(1, statements.count))
                    do {
                        _ = try await connection.executeCollecting(statement.sql)
                    } catch {
                        failures = [
                            ScriptExecutionFailure(
                                id: 1, statementNumber: Int64(done + 1), line: nil, excerpt: statement.sql,
                                message: (error as? DBError)?.errorDescription ?? String(describing: error))
                        ]
                        errorText = failures[0].message
                        status = "Stopped after \(done) statement\(done == 1 ? "" : "s")."
                        phase = .failed
                        return
                    }
                    done += 1
                }
                summary = "Ran \(done) statement\(done == 1 ? "" : "s") on the target."
                fraction = 1
                phase = .finished
            } catch is CancellationError {
                phase = .cancelled
                status = "Cancelled."
            } catch {
                fail(error)
            }
        }
    }
}
