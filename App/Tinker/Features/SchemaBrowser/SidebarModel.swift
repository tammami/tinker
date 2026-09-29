import DBCore
import DBRedis
import DBStore
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
    /// MySQL and MariaDB share a dialect, so only a live server says which one this is.
    public private(set) var flavors: [UUID: ServerFlavor] = [:]
    /// The tables of every open branch, for Quick Open and the command palette.
    ///
    /// Derived from the tree rather than remembered: a table is offered while its
    /// connection, database and schema are all open, and stops being offered the moment
    /// any of them is closed. Nothing lingers from a database that was shut.
    public var knownTables: [(connection: UUID, table: TableInfo)] {
        var result: [(connection: UUID, table: TableInfo)] = []
        for (key, children) in childCache where isBranchOpen(key) {
            for folder in children {
                guard case .tableFolder = folder.kind else { continue }
                for child in folder.children ?? [] {
                    if case let .table(id, info) = child.kind { result.append((id, info)) }
                }
            }
        }
        return result
    }

    /// True when the node and every ancestor between it and the connection are expanded.
    private func isBranchOpen(_ id: SidebarItem.ID) -> Bool {
        guard expanded.contains(id) else { return false }
        let parts = id.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        var prefix = ""
        for (index, part) in parts.enumerated() {
            prefix = index == 0 ? part : prefix + "/" + part
            // Ancestors are the connection (the bare uuid) and each `…/db/<name>`.
            let isAncestor = index == 0 || (index >= 2 && parts[index - 1] == "db")
            if isAncestor, prefix != id, !expanded.contains(prefix) { return false }
        }
        return true
    }

    private let environment: AppEnvironment
    private var childCache: [SidebarItem.ID: [SidebarItem]] = [:]
    private var loading: Set<SidebarItem.ID> = []
    private var stateWatchers: [UUID: Task<Void, Never>] = [:]

    public init(environment: AppEnvironment) {
        self.environment = environment
        rebuildRoots()
    }

    /// Rebuilds the top level: folders (nested, including empty ones the user made) with
    /// their connections inside, then the connections that belong to no folder.
    public func rebuildRoots() {
        roots = buildLevel(path: [])
        // A watcher for a connection that no longer exists would run for the life of the
        // window; nothing cancelled them before.
        let known = Set(environment.connections.map(\.id))
        openedConnections.formIntersection(known)
        for id in stateWatchers.keys where !known.contains(id) {
            stateWatchers.removeValue(forKey: id)?.cancel()
            states.removeValue(forKey: id)
            mainStates.removeValue(forKey: id)
        }
        for key in databaseStateWatchers.keys
        where !known.contains(where: { key.hasPrefix($0.uuidString + "/") }) {
            databaseStateWatchers.removeValue(forKey: key)?.cancel()
        }
    }

    /// The user's answer to a dropped connection: connect again, giving up whatever
    /// transaction was open on the old one. The session refuses to do this on its own
    /// (SPEC §9.6), which is why the menu item exists.
    public func reconnect(connectionID: UUID) async {
        for session in environment.sessions(for: connectionID) {
            do {
                try await session.reconnect()
            } catch {
                // The session published its `.degraded` state with the reason; the dot
                // and its tooltip show it, and the next attempt is one click away.
                continue
            }
        }
        await refresh(connectionID: connectionID)
    }

    private func connectionItem(_ config: ConnectionConfig) -> SidebarItem {
        SidebarItem(
            id: config.id.uuidString,
            kind: .connection(config.id),
            title: config.name,
            subtitle: config.dialect.isFileBased && !config.isRedis
                ? ((config.database ?? "") as NSString).abbreviatingWithTildeInPath
                : "\(config.user)@\(config.host)",
            symbolName: Icon.connection,
            children: childCache[config.id.uuidString] ?? []
        )
    }

    /// `items` in the order a person scans a list: by name, case-insensitively, with
    /// numbers in numeric order (`table_2` before `table_10`), whatever the server's
    /// collation returned.
    static func byName<T>(_ items: [T], _ name: (T) -> String) -> [T] {
        items.sorted { name($0).localizedStandardCompare(name($1)) == .orderedAscending }
    }

    /// The rows directly inside `path`: its subfolders, then its own connections.
    private func buildLevel(path: [String]) -> [SidebarItem] {
        var childNames: [String] = []
        var seen: Set<String> = []
        func note(_ candidate: [String]) {
            guard candidate.count > path.count, candidate.starts(with: path) else { return }
            let name = candidate[path.count]
            if seen.insert(name).inserted { childNames.append(name) }
        }
        for group in environment.groups { note(group.path) }
        for config in environment.connections { note(config.groupPath) }
        childNames.sort { $0.localizedStandardCompare($1) == .orderedAscending }

        var items: [SidebarItem] = childNames.map { name in
            let folderPath = path + [name]
            let children = buildLevel(path: folderPath)
            return SidebarItem(
                id: "group/\(folderPath.joined(separator: "\u{1F}"))",
                kind: .group(path: folderPath),
                title: name,
                subtitle: children.isEmpty ? "empty" : nil,
                symbolName: Icon.group,
                children: children
            )
        }
        // Connections in name order, like everything else in the tree.
        items.append(
            contentsOf: environment.connections
                .filter { $0.groupPath == path }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .map(connectionItem))
        return items
    }

    public func state(of connectionID: UUID) -> ConnectionState {
        // A Redis connection has no SQL session to report; the tree's last answer stands in.
        if liveRedis.contains(connectionID) { return .connected }
        return states[connectionID] ?? .disconnected
    }

    /// Follows a session's state so the status dot stays honest.
    public func watchState(of connectionID: UUID) {
        guard stateWatchers[connectionID] == nil, let session = environment.session(for: connectionID) else {
            return
        }
        stateWatchers[connectionID] = Task { [weak self] in
            for await state in await session.states() {
                guard let self else { return }
                mainStates[connectionID] = state
                // A database session that has failed keeps the dot red until it recovers.
                if case .degraded = states[connectionID] ?? .disconnected,
                    degradedDatabases[connectionID]?.isEmpty == false
                {
                    continue
                }
                states[connectionID] = state
                if case .connected = state, flavors[connectionID] == nil,
                    let version = try? await session.connect()
                {
                    flavors[connectionID] = version.flavor
                    await rememberFlavor(version.flavor, of: connectionID)
                }
            }
        }
    }

    /// Writes the flavour onto the saved connection so the badge is still right the next
    /// time the app opens, before anything has connected.
    private func rememberFlavor(_ flavor: ServerFlavor, of connectionID: UUID) async {
        guard var config = environment.connections.first(where: { $0.id == connectionID }),
            config.knownFlavor != flavor
        else { return }
        config.knownFlavor = flavor
        await environment.save(config)
    }

    /// What the live server said, or failing that what it said last time.
    public func flavor(of connectionID: UUID) -> ServerFlavor? {
        flavors[connectionID]
            ?? environment.connections.first { $0.id == connectionID }?.knownFlavor
    }

    /// The main session's own state, kept apart so a database session's failure can
    /// colour the dot without losing what the main session last said.
    private var mainStates: [UUID: ConnectionState] = [:]
    /// Which of a connection's other-database sessions are currently failing.
    private var degradedDatabases: [UUID: Set<String>] = [:]
    private var databaseStateWatchers: [String: Task<Void, Never>] = [:]

    /// Follows a session opened on another database of the connection: its failure shows
    /// on the connection's dot, since that is the only dot there is.
    func watchState(of connectionID: UUID, database: String, session: ConnectionSession) {
        let key = "\(connectionID.uuidString)/\(database)"
        guard databaseStateWatchers[key] == nil else { return }
        databaseStateWatchers[key] = Task { [weak self] in
            for await state in await session.states() {
                guard let self else { return }
                if case .degraded = state {
                    degradedDatabases[connectionID, default: []].insert(database)
                    states[connectionID] = state
                } else {
                    degradedDatabases[connectionID]?.remove(database)
                    if degradedDatabases[connectionID]?.isEmpty != false {
                        states[connectionID] = mainStates[connectionID] ?? states[connectionID] ?? .disconnected
                    }
                }
            }
        }
    }

    /// Folders are open unless the user closed them; everything else is closed until opened.
    public func isExpanded(_ id: SidebarItem.ID) -> Bool {
        if id.hasPrefix("group/") { return !collapsedGroups.contains(id) }
        return expanded.contains(id)
    }

    private var collapsedGroups: Set<SidebarItem.ID> = []

    /// Records that a node is open, without waiting for its children.
    ///
    /// The disclosure control reads this back on the very next layout pass, so it has to
    /// change synchronously; doing it inside the loading task made the triangle snap shut
    /// again before the query returned.
    public func markExpanded(_ id: SidebarItem.ID) {
        if id.hasPrefix("group/") { collapsedGroups.remove(id) }
        // A connection's row is its id alone; opening it is what gives it a chevron.
        if let connectionID = UUID(uuidString: id) { openedConnections.insert(connectionID) }
        expanded.insert(id)
    }

    /// Connections the user has opened — with a double-click, Expand, or anything that
    /// expands the row for them. Only these draw a chevron: a connection is not browsed
    /// until it is asked for, and a single click only selects it. A query tab (⌘T) opens
    /// its own session and leaves this alone.
    public private(set) var openedConnections: Set<UUID> = []

    public func isOpened(_ connectionID: UUID) -> Bool { openedConnections.contains(connectionID) }

    /// Loads a node's children if they have not been read yet.
    public func loadChildrenIfNeeded(_ item: SidebarItem) async {
        guard childCache[item.id] == nil || stale.contains(item.id), !loading.contains(item.id) else { return }
        await loadChildren(of: item)
    }

    /// Expands a node, loading its children the first time.
    public func expand(_ item: SidebarItem) async {
        markExpanded(item.id)
        await loadChildrenIfNeeded(item)
    }

    public func collapse(_ id: SidebarItem.ID) {
        if id.hasPrefix("group/") { collapsedGroups.insert(id) }
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
        openedConnections.remove(connectionID)
        liveRedis.remove(connectionID)
        let marker = connectionID.uuidString
        expanded = expanded.filter { !$0.contains(marker) }
        childCache = childCache.filter { !$0.key.contains(marker) }
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

    /// Re-reads a connection's tree: every open level again, from the connection down.
    ///
    /// What is on screen stays until its replacement arrives, so a refresh after a DROP or
    /// a TRUNCATE does not empty the tree while it waits. Levels that were loaded but are
    /// not open are forgotten, so opening them later reads the server.
    ///
    /// Refreshes of one connection never overlap. Several table operations in a row each
    /// ask for one; an ask that arrives while one is running is folded into a single
    /// further pass, and every caller returns once the tree reflects its change.
    public func refresh(connectionID: UUID) async {
        pendingRefreshes.insert(connectionID)
        if let running = refreshes[connectionID] {
            await running.value
            return
        }
        let task = Task { [weak self] in
            while let self, self.pendingRefreshes.remove(connectionID) != nil {
                await self.performRefresh(connectionID)
            }
            // Cleared in the same step that found nothing pending, so a new ask can never
            // see a finished task and wait on it in vain.
            self?.refreshes[connectionID] = nil
        }
        refreshes[connectionID] = task
        await task.value
    }

    private var refreshes: [UUID: Task<Void, Never>] = [:]
    private var pendingRefreshes: Set<UUID> = []
    /// Cached levels read before the refresh that is running; each is replaced as it is
    /// re-read, and whatever is still here at the end is dropped.
    private var stale: Set<SidebarItem.ID> = []

    private func performRefresh(_ connectionID: UUID) async {
        for session in environment.sessions(for: connectionID) { await session.invalidateIntrospection() }
        let marker = connectionID.uuidString
        let previous = Set(childCache.keys.filter { $0.contains(marker) })
        stale.formUnion(previous)
        // Loading the connection loads every open level beneath it, parents before
        // children (see `loadChildren`).
        if expanded.contains(marker), let item = find(id: marker) { await loadChildren(of: item) }
        let leftover = stale.intersection(previous)
        stale.subtract(previous)
        childCache = childCache.filter { !leftover.contains($0.key) }
        rebuildRoots()
        applyCachedChildren()
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

    /// Reads a node's children, then those of every child that is open, so a branch that
    /// was open before a refresh or a reconnect comes back open *and filled*. Without this
    /// a database row stayed open with nothing under it until it was closed and reopened.
    private func loadChildren(of item: SidebarItem) async {
        loading.insert(item.id)
        defer { loading.remove(item.id) }
        var loaded: [SidebarItem] = []
        do {
            let children = try await children(of: item)
            childCache[item.id] = children
            loaded = children
        } catch {
            let message = (error as? DBError)?.errorDescription ?? String(describing: error)
            childCache[item.id] = [
                SidebarItem(
                    id: "\(item.id)/error",
                    kind: .failure(parent: item.id, message: message),
                    title: message,
                    symbolName: Icon.warning
                )
            ]
        }
        stale.remove(item.id)
        rebuildRoots()
        applyCachedChildren()
        for child in loaded where child.isExpandable && expanded.contains(child.id) && !loading.contains(child.id) {
            guard childCache[child.id] == nil || stale.contains(child.id) else { continue }
            await loadChildren(of: child)
        }
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
            return buildLevel(path: path)

        case let .connection(id) where environment.redisSession(for: id) != nil:
            return try await redisDatabases(of: id)

        case let .connection(id):
            guard let session = environment.session(for: id) else { return [] }
            watchState(of: id)
            _ = try await session.connect()
            let databases = try await session.introspection(.databases) { try await $0.databases() }
            // Which one the main session sits on decides whether another needs its own session.
            environment.currentDatabases[id] = databases.first { $0.isCurrent }?.name
            return Self.byName(databases, \.name).map { database in
                SidebarItem(
                    id: "\(id.uuidString)/db/\(database.name)",
                    kind: .database(connection: id, name: database.name),
                    title: database.name,
                    subtitle: database.isCurrent ? "current" : nil,
                    symbolName: Icon.database,
                    children: []
                )
            }

        case let .database(id, name):
            // PostgreSQL reads another database only through a session opened on it.
            guard let session = environment.session(for: id, database: name) else { return [] }
            if session !== environment.session(for: id) { watchState(of: id, database: name, session: session) }
            _ = try await session.connect()
            // MySQL and SQLite have no schema layer: a database holds its tables directly,
            // so the folders hang off the database row rather than off a schema of the
            // same name.
            if let ref = SchemaRef.pseudoSchema(session.config.dialect, database: name) {
                return try await children(
                    of: SidebarItem(
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
            return Self.byName(schemas.filter { !$0.isSystem }, \.name).map { schema in
                SidebarItem(
                    id: "\(id.uuidString)/db/\(name)/schema/\(schema.name)",
                    kind: .schema(connection: id, ref: schema.ref),
                    title: schema.name,
                    symbolName: Icon.schema,
                    children: []
                )
            }

        case let .schema(id, ref):
            guard let session = environment.session(for: id, schema: ref) else { return [] }
            let tables = try await session.introspection(.tables(ref)) { try await $0.tables(in: ref) }
            var folders: [SidebarItem] = []
            for kind in [TableKind.table, .partitionedTable, .view, .materializedView, .foreignTable] {
                let matching = tables.filter { $0.kind == kind }
                guard !matching.isEmpty else { continue }
                folders.append(
                    SidebarItem(
                        id: "\(item.id)/kind/\(kind.rawValue)",
                        kind: .tableFolder(connection: id, schema: ref, kind: kind),
                        title: Self.folderTitle(for: kind),
                        subtitle: "\(matching.count)",
                        symbolName: kind.symbolName,
                        children: Self.byName(matching, \.name).map { table in
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
            folders.append(
                SidebarItem(
                    id: "\(item.id)/routines",
                    kind: .routineFolder(connection: id, schema: ref),
                    title: "Functions",
                    symbolName: Icon.function,
                    children: []
                ))
            // MySQL and MariaDB only. The row carries the scheduler's state: an event
            // stored while it is off never fires, and the server says nothing.
            if session.config.dialect.hasScheduledEvents {
                let state = await schedulerState(of: session)
                folders.append(
                    SidebarItem(
                        id: "\(item.id)/events",
                        kind: .eventFolder(connection: id, schema: ref),
                        title: "Events",
                        subtitle: Self.schedulerNote(state),
                        symbolName: Icon.event,
                        children: []
                    ))
            }
            return folders

        case let .routineFolder(id, ref):
            guard let session = environment.session(for: id, schema: ref) else { return [] }
            let routines = try await session.introspection(.routines(ref)) { try await $0.routines(in: ref) }
            return Self.byName(routines, \.name).map { routine in
                SidebarItem(
                    id: "\(item.id)/\(routine.id)",
                    kind: .routine(
                        connection: id, schema: ref, name: routine.name, signature: routine.signature
                    ),
                    title: routine.name,
                    subtitle: routine.signature.isEmpty ? nil : "(\(routine.signature))",
                    symbolName: routine.kind.symbolName
                )
            }

        case let .eventFolder(id, ref):
            guard let session = environment.session(for: id, schema: ref) else { return [] }
            let events = try await session.introspection(.events(ref)) {
                guard let server = $0.server else { return [EventInfo]() }
                return try await server.events(in: ref)
            }
            return Self.byName(events, \.name).map { event in
                SidebarItem(
                    id: "\(item.id)/\(event.name)",
                    kind: .event(
                        connection: id, schema: ref, name: event.name, isEnabled: event.isEnabled),
                    title: event.name,
                    subtitle: event.isEnabled
                        ? event.scheduleSummary : "\(event.scheduleSummary) · disabled",
                    symbolName: Icon.event
                )
            }

        case .tableFolder:
            // The schema's own load already attached this folder's tables. There is
            // nothing further to read, and caching an empty list here would make
            // `applyCachedChildren` replace those tables with it — the folder would then
            // draw as open and empty while its badge still counted them.
            return item.children ?? []

        case .table, .routine, .event, .loading, .failure, .redisDatabase:
            return []
        }
    }

    /// A Redis connection's logical databases, every one of them — an empty database can
    /// be opened and written to — with its key count from `INFO keyspace`.
    private func redisDatabases(of id: UUID) async throws -> [SidebarItem] {
        guard let session = environment.redisSession(for: id) else { return [] }
        do {
            let info = try await session.connect()
            let databases = try await session.withConnection(database: session.defaultDatabase) { connection in
                try await RedisKeyspace.databases(connection, count: info.databaseCount)
            }
            liveRedis.insert(id)
            return databases.map { database in
                SidebarItem(
                    id: "\(id.uuidString)/redis/\(database.index)",
                    kind: .redisDatabase(connection: id, index: database.index),
                    title: "db\(database.index)",
                    subtitle: database.keys == 0 ? nil : "\(database.keys) key\(database.keys == 1 ? "" : "s")",
                    symbolName: Icon.database
                )
            }
        } catch {
            liveRedis.remove(id)
            throw error
        }
    }

    /// Redis connections that answered the last time the tree asked. They have no SQL
    /// session to report a state, so the badge reads this.
    public private(set) var liveRedis: Set<UUID> = []

    /// A failure here must not hide the folder, so it answers `.unsupported`.
    private func schedulerState(of session: ConnectionSession) async -> SchedulerState {
        do {
            return try await session.withLease { connection in
                guard let server = connection.introspector.server else { return .unsupported }
                return try await server.schedulerState()
            }
        } catch {
            return .unsupported
        }
    }

    /// Nothing when the scheduler is running: a badge always there stops being read.
    static func schedulerNote(_ state: SchedulerState) -> String? {
        switch state {
        case .on, .unsupported: nil
        case .off: "scheduler off"
        case .disabled: "scheduler disabled"
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
    /// A subsequence match (`FuzzyMatch`), ranked by how early and how tightly the letters
    /// appear, which is what makes `usr` find `users` ahead of `user_sessions`.
    public func quickOpenMatches(_ query: String, limit: Int = 40) -> [(connection: UUID, table: TableInfo)] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        guard !needle.isEmpty else { return Array(knownTables.prefix(limit)) }
        let ordered = knownTables.sorted { $0.table.name.localizedStandardCompare($1.table.name) == .orderedAscending }
        return Array(FuzzyMatch.filter(ordered, query: needle, text: { $0.table.name }).prefix(limit))
    }
}
