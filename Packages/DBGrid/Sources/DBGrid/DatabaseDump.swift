import DBCore
import DBSQL
import Foundation

/// What a dump carries and how its data is spelled.
public struct DumpOptions: Sendable, Hashable {
    public enum Content: String, Sendable, Hashable, CaseIterable, Identifiable {
        case structureOnly
        case structureAndData
        case dataOnly

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .structureOnly: "Structure only"
            case .structureAndData: "Structure and data"
            case .dataOnly: "Data only"
            }
        }
        public var includesStructure: Bool { self != .dataOnly }
        public var includesData: Bool { self != .structureOnly }
    }

    public enum DataStyle: String, Sendable, Hashable, CaseIterable, Identifiable {
        /// Multi-row `INSERT` statements: portable, and what MySQL has.
        case insert
        /// `COPY … FROM stdin` blocks: PostgreSQL's fastest path, as `pg_dump` writes them.
        case copy

        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .insert: "INSERT statements"
            case .copy: "COPY blocks (fastest, PostgreSQL only)"
            }
        }
    }

    public var content: Content = .structureAndData
    public var dataStyle: DataStyle = .insert
    public var rowsPerInsert = 250
    /// `DROP … IF EXISTS` before each object, so the dump replaces what is there.
    public var includeDrop = false
    public var includeViews = true
    public var includeRoutines = true
    public var includeTriggers = true
    /// MySQL: leave `DEFINER=` out of views, routines and triggers so they restore under
    /// any account.
    public var stripDefiners = true

    public init() {}

    /// The style that fits the dialect: COPY where the server has it.
    public static func preferred(for dialect: SQLDialect) -> DumpOptions {
        var options = DumpOptions()
        options.dataStyle = dialect == .postgresql ? .copy : .insert
        return options
    }
}

/// Where the dumped objects land: the same names, or another schema, or one table
/// under another name — which is what pasting a table into another database needs.
public struct DumpRenaming: Sendable, Hashable {
    /// The schema (PostgreSQL) or database (MySQL) the objects are created in.
    public var schema: SchemaRef?
    /// Source table name → target table name.
    public var tableNames: [String: String] = [:]

    public init(schema: SchemaRef? = nil, tableNames: [String: String] = [:]) {
        self.schema = schema
        self.tableNames = tableNames
    }

    public static let none = DumpRenaming()
}

/// The objects one dump covers.
public struct DumpSelection: Sendable, Hashable {
    public var schema: SchemaRef
    /// Tables and views, in any order; the dumper orders them.
    public var tables: [TableInfo]
    public var routines: [RoutineInfo]

    public init(schema: SchemaRef, tables: [TableInfo], routines: [RoutineInfo] = []) {
        self.schema = schema
        self.tables = tables
        self.routines = routines
    }

    /// Everything the schema holds.
    public static func all(in schema: SchemaRef, introspector: any SchemaIntrospector) async throws -> DumpSelection {
        let tables = try await introspector.tables(in: schema).filter { $0.kind != .systemTable }
        let routines = (try? await introspector.routines(in: schema)) ?? []
        return DumpSelection(schema: schema, tables: tables, routines: routines)
    }
}

/// Where a dump stands.
public struct DumpProgress: Sendable, Hashable {
    public var stage = ""
    public var tablesDone = 0
    public var tableCount = 0
    public var currentTable: String?
    public var rows: Int64 = 0
    public var elapsed: Duration = .zero

    public init() {}
}

public struct DumpOutcome: Sendable, Hashable {
    public var tables = 0
    public var rows: Int64 = 0
    public var statements = 0
    public var duration: Duration = .zero
    /// What a cross-engine dump left behind, one line each: a view whose SQL is the
    /// source's, a check constraint, a default the target cannot read.
    public var notes: [String] = []

    public init() {}
}

/// Turns a schema, or some of its tables, into a stream of script chunks.
///
/// Structure comes from the server's own catalogue through the introspector; data is
/// read with one streaming `SELECT` per table and written as it arrives, so a table of
/// any size costs one batch of rows. The same chunks go to a file or straight to
/// another connection, which is how copy and paste between servers works.
public struct DatabaseDumper: Sendable {
    /// The engine the objects are read from.
    public let dialect: SQLDialect
    /// The engine the script is written for. When it differs from `dialect` the structure
    /// is rebuilt in the target's terms through `SchemaTranslator`, the rows are spelled in
    /// the target's literals, and views, routines and triggers — which are the source's own
    /// SQL — are left out and named in the outcome's notes.
    public let targetDialect: SQLDialect
    public let options: DumpOptions
    public let renaming: DumpRenaming

    private static let progressInterval: Duration = .milliseconds(250)
    /// An `INSERT` or a COPY batch is flushed at this many bytes whatever the row count.
    private static let batchBytes = 512 * 1_024

    public init(
        dialect: SQLDialect, targetDialect: SQLDialect? = nil, options: DumpOptions, renaming: DumpRenaming = .none
    ) {
        self.dialect = dialect
        self.targetDialect = targetDialect ?? dialect
        self.options = options
        self.renaming = renaming
    }

    /// True when the dump crosses engines.
    public var isCrossEngine: Bool { dialect != targetDialect }

    /// The comment lines at the top of a dump file.
    public static func header(server: String, database: String, dialect: SQLDialect, options: DumpOptions) -> [String] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        var lines = [
            "Tinker dump",
            "Server: \(server) (\(dialect.displayName))",
            "Database: \(database)",
            "Written: \(formatter.string(from: Date()))",
            "Content: \(options.content.title)",
        ]
        if dialect == .mysql {
            // Literals are escaped for the server's default sql_mode; a session running
            // with NO_BACKSLASH_ESCAPES would read `\\\\` as two characters (ADR-0033).
            lines.append(
                "Literals assume the default sql_mode (backslash escapes); restore with NO_BACKSLASH_ESCAPES off.")
        }
        return lines
    }

    /// Writes the dump into `channel`, finishing it at the end or on failure.
    @discardableResult
    public func run(
        _ selection: DumpSelection,
        on connection: any SQLConnection,
        into channel: ScriptChannel,
        progress: @escaping @Sendable (DumpProgress) -> Void
    ) async throws -> DumpOutcome {
        do {
            let outcome = try await dump(selection, on: connection, into: channel, progress: progress)
            await channel.finish()
            return outcome
        } catch {
            await channel.finish(error)
            throw error
        }
    }

    private func dump(
        _ selection: DumpSelection,
        on connection: any SQLConnection,
        into channel: ScriptChannel,
        progress: @escaping @Sendable (DumpProgress) -> Void
    ) async throws -> DumpOutcome {
        let started = ContinuousClock.now
        let introspector = connection.introspector
        var outcome = DumpOutcome()
        var state = DumpProgress()
        var lastReport = started

        func report(force: Bool = false) {
            let now = ContinuousClock.now
            guard force || now - lastReport >= Self.progressInterval else { return }
            lastReport = now
            state.elapsed = started.duration(to: now)
            state.rows = outcome.rows
            progress(state)
        }
        func emit(_ sql: String) async throws {
            let trimmed = Self.stripTerminator(sql)
            guard !trimmed.isEmpty else { return }
            try await channel.send(.statement(trimmed, line: 0))
            outcome.statements += 1
        }

        let baseTables = selection.tables.filter {
            $0.kind == .table || $0.kind == .partitionedTable || $0.kind == .foreignTable
        }
        let views = selection.tables.filter { $0.kind == .view || $0.kind == .materializedView }
        state.tableCount = baseTables.count

        // MARK: Prelude
        switch targetDialect {
        case .postgresql:
            try await emit("SET client_encoding = 'UTF8'")
            try await emit("SET standard_conforming_strings = on")
            if let target = renaming.schema, options.content.includesStructure {
                try await emit("CREATE SCHEMA IF NOT EXISTS \(Identifier.quote(target.schema, dialect: .postgresql))")
            }
        case .mysql:
            try await emit("SET NAMES utf8mb4")
            try await emit("SET FOREIGN_KEY_CHECKS = 0")
            try await emit("SET UNIQUE_CHECKS = 0")
            try await emit("SET sql_mode = 'NO_AUTO_VALUE_ON_ZERO'")
        case .sqlite:
            // Tables arrive in dependency order, but a cycle or a self-reference would
            // still trip the checks; the importer turns them back on at the end.
            try await emit("PRAGMA foreign_keys = OFF")
        }

        // MARK: Order
        state.stage = "Reading structure"
        report(force: true)
        let ordered = try await Self.orderByDependencies(baseTables, introspector: introspector)
        var columnsByTable: [TableRef: [ColumnInfo]] = [:]
        for table in ordered {
            try Task.checkCancellation()
            columnsByTable[table.ref] = try await introspector.columns(of: table.ref)
        }

        // MARK: Structure
        if options.content.includesStructure {
            state.stage = "Structure"
            if dialect == .postgresql, !isCrossEngine {
                var seenTypes: Set<String> = []
                for table in ordered {
                    for column in columnsByTable[table.ref] ?? [] where column.enumLabels != nil {
                        let typeName = Self.bareTypeName(column.nativeType)
                        guard seenTypes.insert(typeName).inserted, let labels = column.enumLabels else { continue }
                        let qualified = Identifier.qualify(
                            [targetSchema(selection).schema, typeName], dialect: .postgresql)
                        if options.includeDrop { try await emit("DROP TYPE IF EXISTS \(qualified) CASCADE") }
                        let list = labels.map { SQLLiteral.quoteString($0, dialect: .postgresql) }.joined(
                            separator: ", ")
                        try await emit("CREATE TYPE \(qualified) AS ENUM (\(list))")
                    }
                }
            }
            for table in ordered {
                try Task.checkCancellation()
                state.currentTable = table.name
                let target = targetName(table.ref, selection)
                if options.includeDrop {
                    try await emit("DROP TABLE IF EXISTS \(target)" + (targetDialect == .postgresql ? " CASCADE" : ""))
                }
                if isCrossEngine {
                    // The server's own DDL is the source's SQL; the target gets the
                    // definition rebuilt in its terms.
                    let definition = try await TableDefinitionLoader.load(table, introspector: introspector)
                    var translation = SchemaTranslator.translate(
                        definition, from: dialect, to: targetDialect, into: targetSchema(selection))
                    translation.definition.ref = targetRef(table.ref, selection)
                    outcome.notes.append(contentsOf: translation.notes)
                    for statement in DDLGenerator(dialect: targetDialect).create(translation.definition) {
                        try await emit(statement.sql)
                    }
                } else {
                    let ddl = try await introspector.tableDDL(table.ref)
                    for statement in StatementSplitter.split(rewrite(ddl, selection), dialect: dialect) {
                        try await emit(statement.text)
                    }
                }
                report()
            }
        }

        // MARK: Data
        if options.content.includesData {
            state.stage = "Data"
            // One snapshot for every table, the way `pg_dump` and `mysqldump
            // --single-transaction` read: a row written while the dump runs is either in
            // every table it touches or in none, never in the child but not the parent.
            // The snapshot is this dump's: a dump that stops — cancelled, refused at the
            // transfer's review, failed — ends it, so the connection is usable for the
            // next dump without a trip through the pool (SQLite refuses a BEGIN inside
            // an open transaction).
            _ = try await connection.executeCollecting(Self.snapshotBegin(dialect))
            do {
                for table in ordered where table.kind != .foreignTable {
                    try Task.checkCancellation()
                    state.currentTable = table.name
                    report(force: true)
                    let columns = (columnsByTable[table.ref] ?? []).filter { !$0.isGenerated }
                    guard !columns.isEmpty else { continue }
                    let rows = try await copyRows(
                        of: table, columns: columns, selection: selection, on: connection, into: channel
                    ) { batchRows in
                        outcome.rows += batchRows
                        report()
                    }
                    outcome.statements += rows.statements
                    if targetDialect == .postgresql {
                        for column in columns where column.isAutoIncrement {
                            let target = targetName(table.ref, selection)
                            let name = Identifier.quote(column.name, dialect: .postgresql)
                            try await emit(
                                "SELECT setval(pg_get_serial_sequence(\(SQLLiteral.quoteString(target, dialect: .postgresql)), \(SQLLiteral.quoteString(column.name, dialect: .postgresql))), COALESCE(max(\(name)), 1), max(\(name)) IS NOT NULL) FROM \(target)"
                            )
                        }
                    }
                    state.tablesDone += 1
                    outcome.tables += 1
                }
            } catch {
                // Through the driver's own `rollback`, not the event stream: a cancelled
                // task cannot read a stream, and this must still run.
                try? await connection.rollback()
                throw error
            }
            _ = try await connection.executeCollecting("COMMIT")
        } else {
            outcome.tables = ordered.count
            state.tablesDone = ordered.count
        }

        // MARK: Views, routines, triggers — after the data so nothing fires while it loads.
        if options.content.includesStructure, isCrossEngine {
            if options.includeViews, !views.isEmpty {
                outcome.notes.append(
                    "\(views.count) view\(views.count == 1 ? "" : "s") not carried: a view is written in \(dialect.displayName)'s SQL")
            }
            if options.includeRoutines, !selection.routines.isEmpty {
                outcome.notes.append("\(selection.routines.count) routine\(selection.routines.count == 1 ? "" : "s") not carried across engines")
            }
        } else if options.content.includesStructure {
            if options.includeViews, !views.isEmpty, let server = introspector.server {
                state.stage = "Views"
                for view in views {
                    try Task.checkCancellation()
                    let target = targetName(view.ref, selection)
                    if options.includeDrop {
                        let verb = view.kind == .materializedView ? "DROP MATERIALIZED VIEW" : "DROP VIEW"
                        try await emit("\(verb) IF EXISTS \(target)" + (dialect == .postgresql ? " CASCADE" : ""))
                    }
                    let definition = try await server.viewDefinition(view.ref)
                    try await emit(portable(rewrite(definition, selection)))
                }
            }
            if options.includeRoutines, !selection.routines.isEmpty, let server = introspector.server {
                state.stage = "Routines"
                for routine in selection.routines where routine.kind == .function || routine.kind == .procedure {
                    try Task.checkCancellation()
                    guard
                        let definition = try? await server.routineDefinition(
                            in: selection.schema, name: routine.name, signature: routine.signature, kind: routine.kind)
                    else { continue }
                    let target = targetSchema(selection)
                    let verb = routine.kind == .procedure ? "PROCEDURE" : "FUNCTION"
                    switch dialect {
                    case .postgresql:
                        if options.includeDrop {
                            let qualified = Identifier.qualify([target.schema, routine.name], dialect: .postgresql)
                            try await emit("DROP \(verb) IF EXISTS \(qualified)(\(routine.signature)) CASCADE")
                        }
                    case .mysql:
                        // MySQL has no CREATE OR REPLACE for routines.
                        let qualified = Identifier.qualify([target.database, routine.name], dialect: .mysql)
                        try await emit("DROP \(verb) IF EXISTS \(qualified)")
                    case .sqlite:
                        // SQLite has no stored routines; nothing is ever listed here.
                        continue
                    }
                    try await emit(portable(rewrite(definition, selection)))
                }
            }
            if options.includeTriggers {
                state.stage = "Triggers"
                for table in ordered {
                    try Task.checkCancellation()
                    let triggers = (try? await introspector.triggers(of: table.ref)) ?? []
                    for trigger in triggers {
                        for statement in triggerStatements(trigger, table: table.ref, selection: selection) {
                            try await emit(statement)
                        }
                    }
                }
            }
        }

        // MARK: Epilogue
        switch targetDialect {
        case .mysql:
            try await emit("SET UNIQUE_CHECKS = 1")
            try await emit("SET FOREIGN_KEY_CHECKS = 1")
        case .sqlite:
            try await emit("PRAGMA foreign_keys = ON")
        case .postgresql:
            break
        }
        state.stage = "Done"
        state.currentTable = nil
        report(force: true)
        outcome.duration = started.duration(to: .now)
        return outcome
    }

    // MARK: - Data

    /// Streams one table's rows into the channel as COPY lines or INSERT batches.
    private func copyRows(
        of table: TableInfo,
        columns: [ColumnInfo],
        selection: DumpSelection,
        on connection: any SQLConnection,
        into channel: ScriptChannel,
        onBatch: (Int64) -> Void
    ) async throws -> (statements: Int, rows: Int64) {
        let sourceName = Identifier.qualified(table.ref, dialect: dialect)
        let target = targetName(table.ref, selection)
        let sourceColumnList = columns.map { Identifier.quote($0.name, dialect: dialect) }.joined(separator: ", ")
        let columnList = columns.map { Identifier.quote($0.name, dialect: targetDialect) }.joined(separator: ", ")
        let sql = "SELECT \(sourceColumnList) FROM \(sourceName)"
        let useCopy = targetDialect == .postgresql && options.dataStyle == .copy
        var statements = 0
        var rows: Int64 = 0

        if useCopy {
            let targetRef = targetRef(table.ref, selection)
            try await channel.send(
                .copyBegin(
                    table: targetRef, columns: columns.map(\.name), sql: "COPY \(target) (\(columnList)) FROM stdin"))
            statements += 1
        }

        var batch = Data()
        var batchRows = 0
        let insertPrefix = "INSERT INTO \(target) (\(columnList)) VALUES\n"

        func flush() async throws {
            guard batchRows > 0 else { return }
            if useCopy {
                try await channel.send(.copyLines(batch))
            } else {
                batch.append(contentsOf: ";".utf8)
                var text = insertPrefix
                text.append(String(decoding: batch, as: UTF8.self))
                try await channel.send(.statement(Self.stripTerminator(text), line: 0))
                statements += 1
            }
            rows += Int64(batchRows)
            onBatch(Int64(batchRows))
            batch.removeAll(keepingCapacity: true)
            batchRows = 0
        }

        for try await event in connection.execute(sql, parameters: []) {
            guard case let .rows(rowBatch) = event else { continue }
            for row in rowBatch.rows {
                try Task.checkCancellation()
                if useCopy {
                    batch.append(contentsOf: row.map(Self.copyText).joined(separator: "\t").utf8)
                    batch.append(UInt8(ascii: "\n"))
                } else {
                    if batchRows > 0 { batch.append(contentsOf: ",\n".utf8) }
                    batch.append(contentsOf: "(".utf8)
                    batch.append(contentsOf: row.map { $0.sqlLiteral(dialect: targetDialect) }.joined(separator: ", ").utf8)
                    batch.append(contentsOf: ")".utf8)
                }
                batchRows += 1
                let full =
                    useCopy
                    ? batch.count >= Self.batchBytes
                    : (batchRows >= max(1, options.rowsPerInsert) || batch.count >= Self.batchBytes)
                if full { try await flush() }
            }
        }
        try await flush()
        if useCopy { try await channel.send(.copyEnd) }
        return (statements, rows)
    }

    /// One value in PostgreSQL's COPY text format.
    static func copyText(_ value: DBValue) -> String {
        switch value {
        case .null:
            return "\\N"
        case let .bool(flag):
            return flag ? "t" : "f"
        case let .bytes(data):
            return "\\\\x" + data.map { String(format: "%02x", $0) }.joined()
        case let .raw(_, text, bytes):
            if let text { return escapeCopy(text) }
            if let bytes { return "\\\\x" + bytes.map { String(format: "%02x", $0) }.joined() }
            return "\\N"
        default:
            return escapeCopy(ClipboardFormatter.cellText(value))
        }
    }

    private static func escapeCopy(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.utf8.count)
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    // MARK: - Naming

    private func targetSchema(_ selection: DumpSelection) -> SchemaRef {
        renaming.schema ?? selection.schema
    }

    private func targetRef(_ table: TableRef, _ selection: DumpSelection) -> TableRef {
        TableRef(schema: targetSchema(selection), name: renaming.tableNames[table.name] ?? table.name)
    }

    private func targetName(_ table: TableRef, _ selection: DumpSelection) -> String {
        Identifier.qualified(targetRef(table, selection), dialect: targetDialect)
    }

    /// Server DDL with the source schema and renamed tables replaced by their targets.
    func rewrite(_ sql: String, _ selection: DumpSelection) -> String {
        let sourceQualifier = dialect == .mysql ? selection.schema.database : selection.schema.schema
        let target = targetSchema(selection)
        let targetQualifier = dialect == .mysql ? target.database : target.schema
        guard sourceQualifier != targetQualifier || !renaming.tableNames.isEmpty else { return sql }

        let tokens = SQLTokenizer.tokenize(sql, dialect: dialect)
        var replacements: [(Range<Int>, String)] = []
        let renameKeywords: Set<String> = [
            "TABLE", "INTO", "ON", "FROM", "JOIN", "EXISTS", "UPDATE", "REFERENCES", "VIEW",
        ]
        let dependentKeywords: Set<String> = ["CONSTRAINT", "INDEX", "SEQUENCE", "TRIGGER"]
        for (index, token) in tokens.enumerated() where token.kind == .identifier || token.kind == .quotedIdentifier {
            let name = Identifier.unquote(token.text, dialect: dialect)
            let next = tokens[(index + 1)...].first { $0.kind != .whitespace }
            let previous = tokens[..<index].last { $0.kind != .whitespace }
            if name == sourceQualifier, sourceQualifier != targetQualifier, next?.text == "." {
                replacements.append((token.utf16Range, Identifier.quote(targetQualifier, dialect: dialect)))
                continue
            }
            if let renamed = renaming.tableNames[name] {
                let afterDot = previous?.text == "."
                let afterKeyword = previous.map { renameKeywords.contains($0.text.uppercased()) } ?? false
                if afterDot || afterKeyword {
                    replacements.append((token.utf16Range, Identifier.quote(renamed, dialect: dialect)))
                }
                continue
            }
            // Constraints, indexes and sequences named after the table — PostgreSQL's
            // own convention — would collide with the original's in the same schema.
            if let previous, dependentKeywords.contains(previous.text.uppercased()),
                let (source, renamed) = renaming.tableNames.first(where: { name.hasPrefix($0.key + "_") })
            {
                let suffix = name.dropFirst(source.count)
                replacements.append((token.utf16Range, Identifier.quote(renamed + suffix, dialect: dialect)))
            }
        }
        guard !replacements.isEmpty else { return sql }
        let mutable = NSMutableString(string: sql)
        for (range, text) in replacements.sorted(by: { $0.0.lowerBound > $1.0.lowerBound }) {
            mutable.replaceCharacters(in: NSRange(location: range.lowerBound, length: range.count), with: text)
        }
        return mutable as String
    }

    /// A definition that restores anywhere: MySQL's `DEFINER=` clause is dropped.
    func portable(_ sql: String) -> String {
        guard dialect == .mysql, options.stripDefiners, let pattern = Self.definerPattern else { return sql }
        return pattern.stringByReplacingMatches(
            in: sql, range: NSRange(location: 0, length: (sql as NSString).length), withTemplate: "")
    }

    private static let definerPattern = try? NSRegularExpression(
        pattern: #"DEFINER\s*=\s*(?:`[^`]*`|'[^']*'|[^\s@]+)@(?:`[^`]*`|'[^']*'|\S+)\s*"#)

    /// The type name without a schema prefix or array brackets.
    static func bareTypeName(_ nativeType: String) -> String {
        var name = nativeType
        if name.hasSuffix("[]") { name.removeLast(2) }
        if let dot = name.lastIndex(of: ".") { name = String(name[name.index(after: dot)...]) }
        return Identifier.unquote(name, dialect: .postgresql)
    }

    static func stripTerminator(_ sql: String) -> String {
        var text = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(";") {
            text.removeLast()
            text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text
    }

    // MARK: - Triggers

    func triggerStatements(_ trigger: TriggerInfo, table: TableRef, selection: DumpSelection) -> [String] {
        let target = targetName(table, selection)
        let timing: String =
            switch trigger.timing {
            case .before: "BEFORE"
            case .after: "AFTER"
            case .insteadOf: "INSTEAD OF"
            }
        let events = trigger.events.map { $0.rawValue.uppercased() }.joined(separator: " OR ")
        switch dialect {
        case .postgresql:
            guard let call = trigger.functionCall else { return [] }
            var statement =
                "CREATE TRIGGER \(Identifier.quote(trigger.name, dialect: .postgresql)) \(timing) \(events) ON \(target) FOR EACH \(trigger.isRowLevel ? "ROW" : "STATEMENT")"
            if let condition = trigger.condition, !condition.isEmpty { statement += " WHEN (\(condition))" }
            statement += " EXECUTE FUNCTION \(rewrite(call, selection))"
            return [statement]
        case .mysql:
            guard let body = trigger.body else { return [] }
            let database = targetSchema(selection).database
            let name = Identifier.qualify([database, trigger.name], dialect: .mysql)
            return [
                "DROP TRIGGER IF EXISTS \(name)",
                "CREATE TRIGGER \(name) \(timing) \(events) ON \(target) FOR EACH ROW \(portable(rewrite(body, selection)))",
            ]
        case .sqlite:
            // The body is the trigger's own `BEGIN … END` block, kept verbatim.
            guard let body = trigger.body else { return [] }
            let name = Identifier.quote(trigger.name, dialect: .sqlite)
            var statement = "CREATE TRIGGER \(name) \(timing) \(events) ON \(target) FOR EACH ROW"
            if let condition = trigger.condition, !condition.isEmpty { statement += " WHEN (\(condition))" }
            return ["DROP TRIGGER IF EXISTS \(name)", "\(statement)\n\(rewrite(body, selection))"]
        }
    }

    // MARK: - Ordering

    /// Opens the read-only snapshot the data phase reads under. Each engine's own form:
    /// PostgreSQL and MySQL take a consistent snapshot at the first read, SQLite's
    /// deferred transaction takes one at its first read too.
    static func snapshotBegin(_ dialect: SQLDialect) -> String {
        switch dialect {
        case .postgresql: "BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY"
        case .mysql: "START TRANSACTION READ ONLY, WITH CONSISTENT SNAPSHOT"
        case .sqlite: "BEGIN"
        }
    }

    /// Tables sorted so every referenced table comes before the tables that reference
    /// it; a cycle falls back to name order for the tables in it.
    static func orderByDependencies(
        _ tables: [TableInfo], introspector: any SchemaIntrospector
    ) async throws -> [TableInfo] {
        guard tables.count > 1 else { return tables }
        let byRef = Dictionary(uniqueKeysWithValues: tables.map { ($0.ref, $0) })
        var dependencies: [TableRef: Set<TableRef>] = [:]
        for table in tables {
            // A failed read is a failed dump, not a table quietly placed before the one
            // it references — that restore would fail on the first foreign key.
            let keys = try await introspector.foreignKeys(of: table.ref)
            let referenced = keys.map(\.referencedTable).filter { $0 != table.ref && byRef[$0] != nil }
            dependencies[table.ref] = Set(referenced)
        }
        var remaining = tables.sorted { $0.name < $1.name }
        var ordered: [TableInfo] = []
        var placed: Set<TableRef> = []
        while !remaining.isEmpty {
            let readyIndex = remaining.firstIndex { table in
                (dependencies[table.ref] ?? []).isSubset(of: placed)
            }
            // A cycle: take the first by name and move on.
            let index = readyIndex ?? 0
            let table = remaining.remove(at: index)
            ordered.append(table)
            placed.insert(table.ref)
        }
        return ordered
    }
}
