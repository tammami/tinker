import DBCore
import DBGrid
import DBSQL
import Foundation
import Observation
import SwiftUI

/// Drives the visual query builder: the tables it knows, the columns of the ones on the
/// canvas, the model the canvas edits, and a preview run of what it generates.
@MainActor
@Observable
public final class QueryBuilderController {
    /// The schema whose tables the list offers. Changing it keeps what is on the canvas.
    public var schema: SchemaRef
    /// Every schema the connection offers, for the picker.
    public private(set) var availableSchemas: [SchemaRef] = []
    public let connectionID: UUID
    public let dialect: SQLDialect

    public var model = QueryBuilderModel()
    public private(set) var availableTables: [TableInfo] = []
    /// Columns per placed table, read once per table reference through the session cache.
    public private(set) var columns: [UUID: [ColumnInfo]] = [:]
    public private(set) var errorText: String?
    public private(set) var isLoading = false
    public var search = ""
    public var pane: Pane = .select
    /// The card whose columns the clause editors default to.
    public var selectedTable: UUID?
    /// A column being dragged towards another, to draw the join line while it happens.
    public var pendingConnection: PendingConnection?

    /// The preview is an ordinary query tab: same streaming, same cancel, same errors.
    public let preview: QueryTabController

    public enum Pane: String, CaseIterable, Identifiable {
        case select = "Select"
        case from = "From"
        case whereClause = "Where"
        case groupBy = "Group"
        case having = "Having"
        case orderBy = "Order"
        case limit = "Limit"
        public var id: String { rawValue }
    }

    public struct PendingConnection: Sendable {
        public var table: UUID
        public var column: String
        public var point: CGPoint
    }

    private let environment: AppEnvironment
    private var foreignKeys: [TableRef: [ForeignKeyInfo]] = [:]

    public init(schema: SchemaRef, connectionID: UUID, dialect: SQLDialect, environment: AppEnvironment) {
        self.schema = schema
        self.connectionID = connectionID
        self.dialect = dialect
        self.environment = environment
        preview = QueryTabController(connectionID: connectionID, dialect: dialect, environment: environment)
    }

    private var session: ConnectionSession? { environment.session(for: connectionID) }

    /// The statement the canvas describes right now.
    public var sql: String? { model.sql(dialect: dialect) }

    public var visibleTables: [TableInfo] {
        guard !search.isEmpty else { return availableTables }
        return availableTables.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    // MARK: - Loading

    public func loadTables() async {
        guard let session else {
            errorText = "No session for this connection"
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            _ = try await session.connect()
            if availableSchemas.isEmpty { await loadSchemas(session) }
            // A connection with no default database opens on nothing; take the first schema.
            if schema.schema.isEmpty || !availableSchemas.contains(schema),
               let first = availableSchemas.first {
                schema = first
            }
            let schema = schema
            availableTables = try await session.introspection(.tables(schema)) {
                try await $0.tables(in: schema)
            }
            errorText = nil
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
        }
    }

    /// The schemas the picker offers: MySQL's databases, PostgreSQL's schemas.
    private func loadSchemas(_ session: ConnectionSession) async {
        switch dialect {
        case .mysql:
            let databases = (try? await session.introspection(.databases) { try await $0.databases() }) ?? []
            let system: Set<String> = ["information_schema", "performance_schema", "mysql", "sys"]
            availableSchemas = databases.map { SchemaRef.mysql($0.name) }
                .filter { !system.contains($0.database) }
        case .postgresql:
            let database = schema.database.isEmpty ? (session.config.database ?? "") : schema.database
            let schemas = (try? await session.introspection(.schemas(database: database)) {
                try await $0.schemas(in: database)
            }) ?? []
            availableSchemas = schemas.filter { !$0.isSystem }.map(\.ref)
        }
        if let current = availableSchemas.first(where: { $0 == schema }) {
            schema = current
        }
    }

    public func select(schema new: SchemaRef) async {
        guard new != schema else { return }
        schema = new
        await loadTables()
    }

    private func loadColumns(of ref: TableRef) async -> [ColumnInfo] {
        guard let session else { return [] }
        return (try? await session.introspection(.columns(ref)) { try await $0.columns(of: ref) }) ?? []
    }

    private func loadForeignKeys(of ref: TableRef) async -> [ForeignKeyInfo] {
        if let cached = foreignKeys[ref] { return cached }
        guard let session else { return [] }
        let keys = (try? await session.introspection(.foreignKeys(ref)) { try await $0.foreignKeys(of: ref) }) ?? []
        foreignKeys[ref] = keys
        return keys
    }

    // MARK: - Canvas edits

    /// Places a table, reads its columns, and joins it to whatever it is related to.
    public func add(_ ref: TableRef, at point: CGPoint) async {
        let id = model.add(ref, at: (Double(point.x), Double(point.y)))
        selectedTable = id
        let loaded = await loadColumns(of: ref)
        columns[id] = loaded
        model.columns[id] = loaded.map(\.name)
        // Keys from the new table to placed ones, and from placed ones to the new table.
        let own = await loadForeignKeys(of: ref)
        model.addJoins(fromForeignKeys: own, of: id)
        var incoming: [(table: UUID, key: ForeignKeyInfo)] = []
        for table in model.tables where table.id != id {
            for key in await loadForeignKeys(of: table.ref) { incoming.append((table.id, key)) }
        }
        model.addJoins(toNewTable: id, fromPlacedForeignKeys: incoming)
    }

    public func remove(table id: UUID) {
        model.remove(table: id)
        model.columns[id] = nil
        columns[id] = nil
        if selectedTable == id { selectedTable = model.tables.first?.id }
    }

    public func move(table id: UUID, to point: CGPoint) {
        guard let index = model.tables.firstIndex(where: { $0.id == id }) else { return }
        model.tables[index].x = max(0, Double(point.x))
        model.tables[index].y = max(0, Double(point.y))
    }

    public func isSelected(table id: UUID, column: String) -> Bool {
        model.fields.contains { $0.table == id && $0.column == column && $0.aggregate == .none }
    }

    /// Ticks or unticks a column in the SELECT list.
    public func toggleField(table id: UUID, column: String) {
        if let index = model.fields.firstIndex(where: { $0.table == id && $0.column == column && $0.aggregate == .none }) {
            model.fields.remove(at: index)
        } else {
            model.fields.append(.init(table: id, column: column))
        }
    }

    public func selectStar(ofTableNamed name: String) {
        guard let table = model.tables.first(where: { $0.ref.name == name }) else { return }
        if !isSelected(table: table.id, column: "*") { model.fields.append(.init(table: table.id, column: "*")) }
    }

    /// Joins two columns, the way dragging one onto the other does.
    public func connect(_ a: UUID, _ aColumn: String, to b: UUID, _ bColumn: String) {
        guard a != b || aColumn != bColumn, !model.hasJoin(a, aColumn, b, bColumn) else { return }
        model.joins.append(.init(leftTable: a, leftColumn: aColumn, rightTable: b, rightColumn: bColumn))
    }

    /// The names of a placed table's columns, for the pickers.
    public func columnNames(of id: UUID) -> [String] {
        columns[id]?.map(\.name) ?? []
    }

    // MARK: - Running

    public func runPreview() {
        guard let sql else { return }
        preview.sql = sql
        preview.caretOffset = 0
        preview.run(all: true)
    }

    /// Creates the view on the server and returns its reference, or reports the error.
    public func createView(named name: String) async -> TableRef? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let session else { return nil }
        let ref = TableRef(schema: schema, name: trimmed)
        guard let statement = model.createViewSQL(name: ref, dialect: dialect) else { return nil }
        do {
            if await session.isReadOnly {
                throw DBError.protocolError("This connection is read-only. Unlock it with ⌘⇧L first.")
            }
            let (lease, connection) = try await session.lease()
            defer { Task { await session.release(lease) } }
            _ = try await connection.executeCollecting(statement)
            await session.invalidateIntrospection()
            errorText = nil
            return ref
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
            return nil
        }
    }

    public func clearError() { errorText = nil }
}
