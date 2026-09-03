import DBCore
import Foundation
import Observation
import SwiftUI

/// Builds the sidebar tree, reading each level only when it is first expanded.
///
/// Every read goes through the session's introspection cache, so expanding a node twice
/// costs one query and Refresh is the only thing that re-reads (SPEC §8).
@MainActor
@Observable
public final class SidebarModel {
    public private(set) var roots: [SidebarItem] = []
    public private(set) var expanded: Set<SidebarItem.ID> = []
    public private(set) var states: [UUID: ConnectionState] = [:]
    /// Every table seen so far, for the quick-open filter (SPEC §11.1).
    public private(set) var knownTables: [(connection: UUID, table: TableInfo)] = []

    private let environment: AppEnvironment
    private var childCache: [SidebarItem.ID: [SidebarItem]] = [:]
    private var loading: Set<SidebarItem.ID> = []
    private var stateWatchers: [UUID: Task<Void, Never>] = [:]

    public init(environment: AppEnvironment) {
        self.environment = environment
        rebuildRoots()
    }

    /// Rebuilds the top level from the stored connections, honouring their group paths.
    public func rebuildRoots() {
        var groups: [[String]: [SidebarItem]] = [:]
        var ungrouped: [SidebarItem] = []

        for config in environment.connections {
            let item = SidebarItem(
                id: config.id.uuidString,
                kind: .connection(config.id),
                title: config.name,
                subtitle: "\(config.user)@\(config.host)",
                symbolName: "cylinder",
                children: childCache[config.id.uuidString] ?? []
            )
            if config.groupPath.isEmpty {
                ungrouped.append(item)
            } else {
                groups[config.groupPath, default: []].append(item)
            }
        }

        var items: [SidebarItem] = groups.keys.sorted { $0.joined() < $1.joined() }.map { path in
            SidebarItem(
                id: "group/\(path.joined(separator: "/"))",
                kind: .group(path: path),
                title: path.joined(separator: " › "),
                symbolName: "folder",
                children: groups[path] ?? []
            )
        }
        items.append(contentsOf: ungrouped)
        roots = items
    }

    public func state(of connectionID: UUID) -> ConnectionState {
        states[connectionID] ?? .disconnected
    }

    /// Follows a session's state so the status dot stays honest.
    public func watchState(of connectionID: UUID) {
        guard stateWatchers[connectionID] == nil, let session = environment.session(for: connectionID) else {
            return
        }
        stateWatchers[connectionID] = Task { [weak self] in
            for await state in await session.states() {
                guard let self else { return }
                states[connectionID] = state
            }
        }
    }

    public func isExpanded(_ id: SidebarItem.ID) -> Bool { expanded.contains(id) }

    /// Records that a node is open, without waiting for its children.
    ///
    /// The disclosure control reads this back on the very next layout pass, so it has to
    /// change synchronously; doing it inside the loading task made the triangle snap shut
    /// again before the query returned.
    public func markExpanded(_ id: SidebarItem.ID) {
        expanded.insert(id)
    }

    /// Loads a node's children if they have not been read yet.
    public func loadChildrenIfNeeded(_ item: SidebarItem) async {
        guard childCache[item.id] == nil, !loading.contains(item.id) else { return }
        await loadChildren(of: item)
    }

    /// Expands a node, loading its children the first time.
    public func expand(_ item: SidebarItem) async {
        markExpanded(item.id)
        await loadChildrenIfNeeded(item)
    }

    public func collapse(_ id: SidebarItem.ID) {
        expanded.remove(id)
    }

    /// Closes a node and every node beneath it, and forgets what they had loaded, so
    /// reopening reads the server again and nothing stays resident for a closed branch.
    public func collapseSubtree(_ id: SidebarItem.ID) {
        let prefix = id + "/"
        expanded = expanded.filter { $0 != id && !$0.hasPrefix(prefix) }
        childCache = childCache.filter { $0.key != id && !$0.key.hasPrefix(prefix) }
        rebuildRoots()
        applyCachedChildren()
    }

    /// What Disconnect does to the tree: every node of the connection closes and empties.
    public func collapseConnection(_ connectionID: UUID) {
        let marker = connectionID.uuidString
        expanded = expanded.filter { !$0.contains(marker) }
        childCache = childCache.filter { !$0.key.contains(marker) }
        knownTables.removeAll { $0.connection == connectionID }
        rebuildRoots()
        applyCachedChildren()
    }

    public func toggle(_ item: SidebarItem) async {
        if expanded.contains(item.id) {
            collapse(item.id)
        } else {
            await expand(item)
        }
    }

    /// Drops every cached level for a connection and reloads what is expanded.
    public func refresh(connectionID: UUID) async {
        await environment.session(for: connectionID)?.invalidateIntrospection()
        childCache = childCache.filter { !$0.key.contains(connectionID.uuidString) }
        knownTables.removeAll { $0.connection == connectionID }
        rebuildRoots()
        for id in expanded where id.contains(connectionID.uuidString) {
            if let item = find(id: id) { await loadChildren(of: item) }
        }
        rebuildRoots()
    }

    public func find(id: SidebarItem.ID) -> SidebarItem? {
        func search(_ items: [SidebarItem]) -> SidebarItem? {
            for item in items {
                if item.id == id { return item }
                if let children = item.children ?? childCache[item.id], let found = search(children) {
                    return found
                }
            }
            return nil
        }
        return search(roots)
    }

    // MARK: - Loading

    private func loadChildren(of item: SidebarItem) async {
        loading.insert(item.id)
        defer { loading.remove(item.id) }
        do {
            let children = try await children(of: item)
            childCache[item.id] = children
        } catch {
            let message = (error as? DBError)?.errorDescription ?? String(describing: error)
            childCache[item.id] = [SidebarItem(
                id: "\(item.id)/error",
                kind: .failure(parent: item.id, message: message),
                title: message,
                symbolName: "exclamationmark.triangle"
            )]
        }
        rebuildRoots()
        applyCachedChildren()
    }

    /// Walks the tree replacing placeholder children with what has been loaded.
    private func applyCachedChildren() {
        func rebuild(_ items: [SidebarItem]) -> [SidebarItem] {
            items.map { item in
                var copy = item
                if item.children != nil {
                    copy.children = rebuild(childCache[item.id] ?? item.children ?? [])
                }
                return copy
            }
        }
        roots = rebuild(roots)
    }

    private func children(of item: SidebarItem) async throws -> [SidebarItem] {
        switch item.kind {
        case let .group(path):
            return environment.connections
                .filter { $0.groupPath == path }
                .map { config in
                    SidebarItem(
                        id: config.id.uuidString,
                        kind: .connection(config.id),
                        title: config.name,
                        subtitle: "\(config.user)@\(config.host)",
                        symbolName: "cylinder",
                        children: childCache[config.id.uuidString] ?? []
                    )
                }

        case let .connection(id):
            guard let session = environment.session(for: id) else { return [] }
            watchState(of: id)
            _ = try await session.connect()
            let databases = try await session.introspection(.databases) { try await $0.databases() }
            return databases.map { database in
                SidebarItem(
                    id: "\(id.uuidString)/db/\(database.name)",
                    kind: .database(connection: id, name: database.name),
                    title: database.name,
                    subtitle: database.isCurrent ? "current" : nil,
                    symbolName: "internaldrive",
                    children: []
                )
            }

        case let .database(id, name):
            guard let session = environment.session(for: id) else { return [] }
            // MySQL has no schema layer: a database holds its tables directly, so the
            // folders hang off the database row rather than off a schema of the same name.
            if session.config.dialect == .mysql {
                let ref = SchemaRef.mysql(name)
                return try await children(of: SidebarItem(
                    id: "\(item.id)/schema/\(name)",
                    kind: .schema(connection: id, ref: ref),
                    title: name,
                    symbolName: Icon.schema,
                    children: []
                ))
            }
            let schemas = try await session.introspection(.schemas(database: name)) {
                try await $0.schemas(in: name)
            }
            // System schemas are hidden by default; the user rarely browses pg_catalog.
            return schemas.filter { !$0.isSystem }.map { schema in
                SidebarItem(
                    id: "\(id.uuidString)/db/\(name)/schema/\(schema.name)",
                    kind: .schema(connection: id, ref: schema.ref),
                    title: schema.name,
                    symbolName: "square.stack.3d.up",
                    children: []
                )
            }

        case let .schema(id, ref):
            guard let session = environment.session(for: id) else { return [] }
            let tables = try await session.introspection(.tables(ref)) { try await $0.tables(in: ref) }
            for table in tables where !knownTables.contains(where: { $0.table.ref == table.ref }) {
                knownTables.append((connection: id, table: table))
            }
            var folders: [SidebarItem] = []
            for kind in [TableKind.table, .partitionedTable, .view, .materializedView, .foreignTable] {
                let matching = tables.filter { $0.kind == kind }
                guard !matching.isEmpty else { continue }
                folders.append(SidebarItem(
                    id: "\(item.id)/kind/\(kind.rawValue)",
                    kind: .tableFolder(connection: id, schema: ref, kind: kind),
                    title: Self.folderTitle(for: kind),
                    subtitle: "\(matching.count)",
                    symbolName: kind.symbolName,
                    children: matching.map { table in
                        SidebarItem(
                            id: "\(id.uuidString)/table/\(table.ref.id)",
                            kind: .table(connection: id, info: table),
                            title: table.name,
                            subtitle: table.approximateRowCount.map { "~\($0)" },
                            symbolName: kind.symbolName
                        )
                    }
                ))
            }
            folders.append(SidebarItem(
                id: "\(item.id)/routines",
                kind: .routineFolder(connection: id, schema: ref),
                title: "Functions",
                symbolName: "function",
                children: []
            ))
            return folders

        case let .routineFolder(id, ref):
            guard let session = environment.session(for: id) else { return [] }
            let routines = try await session.introspection(.routines(ref)) { try await $0.routines(in: ref) }
            return routines.map { routine in
                SidebarItem(
                    id: "\(item.id)/\(routine.id)",
                    kind: .routine(
                        connection: id, schema: ref, name: routine.name, signature: routine.signature
                    ),
                    title: routine.name,
                    subtitle: routine.signature.isEmpty ? nil : "(\(routine.signature))",
                    symbolName: routine.kind == .procedure ? "gearshape.2" : "function"
                )
            }

        case .tableFolder:
            // The schema's own load already attached this folder's tables. There is
            // nothing further to read, and caching an empty list here would make
            // `applyCachedChildren` replace those tables with it — the folder would then
            // draw as open and empty while its badge still counted them.
            return item.children ?? []

        case .table, .routine, .loading, .failure:
            return []
        }
    }

    static func folderTitle(for kind: TableKind) -> String {
        switch kind {
        case .table: "Tables"
        case .partitionedTable: "Partitioned Tables"
        case .view: "Views"
        case .materializedView: "Materialized Views"
        case .foreignTable: "Foreign Tables"
        case .systemTable: "System Tables"
        }
    }

    // MARK: - Quick open

    /// Fuzzy-matches table names across every connection whose schema has been read.
    ///
    /// A subsequence match, ranked by how early and how tightly the letters appear, which
    /// is what makes `usr` find `users` ahead of `user_sessions`.
    public func quickOpenMatches(_ query: String, limit: Int = 40) -> [(connection: UUID, table: TableInfo)] {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return Array(knownTables.prefix(limit)) }
        return knownTables
            .compactMap { entry -> (score: Int, connection: UUID, table: TableInfo)? in
                guard let score = Self.fuzzyScore(needle: needle, haystack: entry.table.name.lowercased()) else {
                    return nil
                }
                return (score, entry.connection, entry.table)
            }
            .sorted { ($0.score, $0.table.name) < ($1.score, $1.table.name) }
            .prefix(limit)
            .map { (connection: $0.connection, table: $0.table) }
    }

    /// Lower is better. `nil` when the needle is not a subsequence of the haystack.
    static func fuzzyScore(needle: String, haystack: String) -> Int? {
        if haystack.hasPrefix(needle) { return 0 }
        var score = haystack.contains(needle) ? 10 : 100
        var index = haystack.startIndex
        var gaps = 0
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            gaps += haystack.distance(from: index, to: found)
            index = haystack.index(after: found)
        }
        score += gaps
        return score
    }
}
