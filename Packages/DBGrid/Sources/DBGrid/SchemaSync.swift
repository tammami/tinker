import DBCore
import DBSQL
import Foundation

/// Reads everything a table's definition is made of, through an introspector.
public enum TableDefinitionLoader {
    /// nil when the schema has no such table.
    public static func load(_ table: TableRef, introspector: any SchemaIntrospector) async throws -> TableDefinition? {
        let tables = try await introspector.tables(in: table.schemaRef)
        guard let info = tables.first(where: { $0.ref.name == table.name }) else { return nil }
        return try await load(info, introspector: introspector)
    }

    public static func load(_ info: TableInfo, introspector: any SchemaIntrospector) async throws -> TableDefinition {
        let ref = info.ref
        let columns = try await introspector.columns(of: ref)
        let primaryKey = try await introspector.primaryKey(of: ref) ?? []
        let indexes = try await introspector.indexes(of: ref)
        let foreignKeys = try await introspector.foreignKeys(of: ref)
        let checks = (try? await introspector.checkConstraints(of: ref)) ?? []
        return TableDefinition(
            table: ref, info: info, columns: columns, primaryKey: primaryKey, indexes: indexes,
            foreignKeys: foreignKeys, checks: checks)
    }
}

/// One table's part in a structure synchronisation.
public struct SchemaSyncItem: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        /// In the source only: the target gets a `CREATE TABLE`.
        case create
        /// In both, differing: the target gets `ALTER`s.
        case alter
        case identical
        /// In the target only: the statement is a drop, destructive, off by default.
        case extra
    }

    public var id: String { name }
    public let name: String
    public let kind: Kind
    public let statements: [GeneratedDDL]

    public var destructiveCount: Int { statements.filter(\.isDestructive).count }
}

/// What comparing two schemas found, and the script that would make the target match.
public struct SchemaSyncResult: Sendable, Hashable {
    public var items: [SchemaSyncItem] = []

    public var differing: [SchemaSyncItem] { items.filter { $0.kind != .identical } }

    /// The script, with destructive statements left out unless asked for, and extra
    /// tables dropped only when asked for as well.
    public func script(includingDestructive: Bool, droppingExtraTables: Bool) -> String {
        var lines: [String] = []
        var leftOut: [String] = []
        for item in items where item.kind != .identical {
            if item.kind == .extra, !droppingExtraTables {
                leftOut.append(contentsOf: item.statements.map(\.sql))
                continue
            }
            lines.append("-- \(item.name): \(item.kind.rawValue)")
            for statement in item.statements {
                if statement.isDestructive, !includingDestructive {
                    leftOut.append(statement.sql)
                } else {
                    lines.append("\(statement.sql);")
                }
            }
            lines.append("")
        }
        if lines.isEmpty, leftOut.isEmpty { return "-- The target already matches the source.\n" }
        if !leftOut.isEmpty {
            lines.append("-- Left out (destructive):")
            lines.append(contentsOf: leftOut.map { "-- \($0);" })
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The statements to run, in order, under the same rules as ``script``.
    public func statements(includingDestructive: Bool, droppingExtraTables: Bool) -> [GeneratedDDL] {
        items.filter { $0.kind != .identical }.flatMap { item -> [GeneratedDDL] in
            if item.kind == .extra, !droppingExtraTables { return [] }
            return item.statements.filter { includingDestructive || !$0.isDestructive }
        }
    }
}

/// Compares every table of one schema against another schema's and writes the DDL
/// that would make the second match the first — Navicat's structure synchronisation.
///
/// Views, routines and triggers are not compared: the data transfer carries those whole.
public struct SchemaSynchronizer: Sendable {
    public let dialect: SQLDialect

    public init(dialect: SQLDialect) {
        self.dialect = dialect
    }

    /// - Parameter tables: source table names to compare, or nil for all of them.
    public func compare(
        sourceSchema: SchemaRef,
        targetSchema: SchemaRef,
        tables: Set<String>? = nil,
        source: any SchemaIntrospector,
        target: any SchemaIntrospector,
        progress: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> SchemaSyncResult {
        let sourceTables = try await source.tables(in: sourceSchema)
            .filter { $0.kind.isEditable && (tables?.contains($0.name) ?? true) }
        let targetTables = try await target.tables(in: targetSchema).filter { $0.kind.isEditable }
        let targetByName = Dictionary(targetTables.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let sync = StructureSync(dialect: dialect)
        var result = SchemaSyncResult()

        for info in sourceTables {
            try Task.checkCancellation()
            progress(info.name)
            let definition = try await TableDefinitionLoader.load(info, introspector: source)
            if let match = targetByName[info.name] {
                let targetDefinition = try await TableDefinitionLoader.load(match, introspector: target)
                let compared = sync.compare(source: definition, target: targetDefinition)
                result.items.append(
                    SchemaSyncItem(
                        name: info.name, kind: compared.isIdentical ? .identical : .alter,
                        statements: compared.statements))
            } else {
                let created = sync.create(source: definition, in: targetSchema)
                result.items.append(SchemaSyncItem(name: info.name, kind: .create, statements: created.statements))
            }
        }
        if tables == nil {
            let sourceNames = Set(sourceTables.map(\.name))
            for extra in targetTables where !sourceNames.contains(extra.name) {
                let drop = GeneratedDDL(
                    kind: .dropTable,
                    sql: "DROP TABLE \(Identifier.qualified(extra.ref, dialect: dialect))"
                        + (dialect == .postgresql ? " CASCADE" : ""),
                    table: extra.ref, isDestructive: true)
                result.items.append(SchemaSyncItem(name: extra.name, kind: .extra, statements: [drop]))
            }
        }
        return result
    }
}
