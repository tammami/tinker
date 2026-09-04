import DBCore
import DBMySQL
import DBPostgres
import DBStore
import DBTunnel
import Foundation
import Logging
import Observation
import SwiftUI

/// Everything the app shares across windows: the store, the Keychain, and one session per
/// configured connection.
///
/// SPEC §10.1 requires sessions to be shared app-wide rather than per window, so two
/// windows browsing the same server reuse one pool and one schema cache.
@MainActor
@Observable
public final class AppEnvironment {
    public private(set) var connections: [ConnectionConfig] = []
    /// Folders the user made, including empty ones; connections carry their own path.
    public private(set) var groups: [StoredGroup] = []
    public private(set) var startupError: String?
    /// How NULL is written when copied, mirrored from settings so grids need not know them.
    public var nullDisplayText = ""

    public let registry = DriverRegistry([
        .postgresql: PostgresDriver.self,
        .mysql: MySQLDriver.self,
    ])
    public let secrets: any SecretStore
    public let tunnelProvider: any TunnelProvider = SSHTunnelProvider()

    private var store: DBStore?
    private var sessions: [UUID: ConnectionSession] = [:]
    private let logger: Logger

    public init(secrets: any SecretStore = KeychainSecretStore()) {
        self.secrets = secrets
        var logger = Logger(label: "dbstudio.app")
        logger.logLevel = .info
        self.logger = logger
    }

    /// Opens the store and loads the saved connections. Called once at launch.
    public func load() async {
        do {
            let store = try await DBStore()
            self.store = store
            connections = try await store.connections()
            groups = try await store.groups()
            startupError = nil
        } catch {
            startupError = String(describing: error)
            logger.error("cannot open the store", metadata: ["error": "\(error)"])
        }
    }

    // MARK: - Connections

    public func save(_ config: ConnectionConfig) async {
        do {
            try await store?.save(config)
            connections = try await store?.connections() ?? connections
        } catch {
            startupError = String(describing: error)
        }
    }

    /// Deletes a connection, its Keychain items and everything remembered about it.
    public func delete(_ config: ConnectionConfig) async {
        await session(for: config.id)?.disconnect()
        sessions.removeValue(forKey: config.id)
        do {
            try await store?.deleteConnection(id: config.id)
            try await secrets.deleteSecrets(forConnection: config.id)
            connections = try await store?.connections() ?? []
        } catch {
            startupError = String(describing: error)
        }
    }

    /// Copies a connection, including its stored password, under a new identity.
    public func duplicate(_ config: ConnectionConfig) async {
        var copy = config
        copy.id = UUID()
        copy.name = "\(config.name) copy"
        if let source = config.passwordRef,
            let password = try? await secrets.secret(for: source)
        {
            let destination = SecretRef.forConnection(copy.id, field: SecretField.password.rawValue)
            try? await secrets.setSecret(password, for: destination)
            copy.passwordRef = destination
        }
        await save(copy)
    }

    // MARK: - Folders

    /// Every folder path, stored or implied by a connection, sorted for a menu.
    public var allGroupPaths: [[String]] {
        var paths = Set(groups.map(\.path).filter { !$0.isEmpty })
        for config in connections where !config.groupPath.isEmpty {
            // A nested path implies each of its ancestors.
            for depth in 1 ... config.groupPath.count { paths.insert(Array(config.groupPath.prefix(depth))) }
        }
        return paths.sorted { $0.joined(separator: "\u{1F}") < $1.joined(separator: "\u{1F}") }
    }

    public func createGroup(_ path: [String]) async {
        guard !path.isEmpty else { return }
        try? await store?.save(StoredGroup(path: path, isExpanded: true, sortOrder: groups.count))
        groups = (try? await store?.groups()) ?? groups
    }

    /// Renames the last component of a folder; every connection and subfolder follows.
    public func renameGroup(_ path: [String], to name: String) async {
        guard !path.isEmpty, !name.isEmpty else { return }
        let renamed = Array(path.dropLast()) + [name]
        for config in connections where config.groupPath.starts(with: path) {
            var moved = config
            moved.groupPath = renamed + Array(config.groupPath.dropFirst(path.count))
            try? await store?.save(moved)
        }
        for group in groups where group.path.starts(with: path) {
            try? await store?.deleteGroup(path: group.path)
            try? await store?.save(
                StoredGroup(
                    path: renamed + Array(group.path.dropFirst(path.count)),
                    isExpanded: group.isExpanded, sortOrder: group.sortOrder
                ))
        }
        await reloadFromStore()
    }

    /// Removes a folder; its connections and subfolders move up to its parent.
    public func removeGroup(_ path: [String]) async {
        guard !path.isEmpty else { return }
        let parent = Array(path.dropLast())
        for config in connections where config.groupPath.starts(with: path) {
            var moved = config
            moved.groupPath = parent + Array(config.groupPath.dropFirst(path.count))
            try? await store?.save(moved)
        }
        for group in groups where group.path.starts(with: path) {
            try? await store?.deleteGroup(path: group.path)
            let rest = Array(group.path.dropFirst(path.count))
            if !rest.isEmpty {
                try? await store?.save(
                    StoredGroup(path: parent + rest, isExpanded: group.isExpanded, sortOrder: group.sortOrder))
            }
        }
        await reloadFromStore()
    }

    public func move(_ config: ConnectionConfig, toGroup path: [String]) async {
        var moved = config
        moved.groupPath = path
        await save(moved)
        if !path.isEmpty, !groups.contains(where: { $0.path == path }) { await createGroup(path) }
    }

    private func reloadFromStore() async {
        connections = (try? await store?.connections()) ?? connections
        groups = (try? await store?.groups()) ?? groups
    }

    public func reorderConnections(_ ids: [UUID]) async {
        try? await store?.reorderConnections(ids)
        connections = (try? await store?.connections()) ?? connections
    }

    // MARK: - Sessions

    /// The session for a configuration, created on first use.
    /// Sessions opened on other databases of a connection, keyed by connection and name.
    private var databaseSessions: [String: ConnectionSession] = [:]

    public func session(for id: UUID) -> ConnectionSession? {
        if let existing = sessions[id] { return existing }
        guard let config = connections.first(where: { $0.id == id }) else { return nil }
        let session = ConnectionSession(
            config: config,
            registry: registry,
            secrets: secrets,
            tunnelProvider: tunnelProvider,
            logger: logger
        )
        sessions[id] = session
        return session
    }

    /// A session on the same server but another database — what PostgreSQL needs to
    /// read or write a database other than the one the connection opens. The main
    /// session is returned when `database` is that one or nil.
    public func session(for id: UUID, database: String?) -> ConnectionSession? {
        guard let config = connections.first(where: { $0.id == id }) else { return nil }
        guard let database, !database.isEmpty, database != config.database else { return session(for: id) }
        let key = "\(id.uuidString)/\(database)"
        if let existing = databaseSessions[key] { return existing }
        var other = config
        other.database = database
        let session = ConnectionSession(
            config: other, registry: registry, secrets: secrets, tunnelProvider: tunnelProvider, logger: logger)
        databaseSessions[key] = session
        return session
    }

    /// Drops a cached session so the next use picks up an edited configuration.
    public func invalidateSession(for id: UUID) async {
        let prefix = id.uuidString + "/"
        for key in databaseSessions.keys where key.hasPrefix(prefix) {
            if let other = databaseSessions.removeValue(forKey: key) { await other.disconnect() }
        }
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.disconnect()
    }

    public func disconnectAll() async {
        for session in sessions.values { await session.disconnect() }
        sessions.removeAll()
        for session in databaseSessions.values { await session.disconnect() }
        databaseSessions.removeAll()
    }

    // MARK: - History, preferences, settings

    public func recordHistory(_ entry: QueryHistoryEntry) async {
        _ = try? await store?.record(entry)
    }

    public func history(connectionID: UUID? = nil, matching search: String? = nil) async -> [QueryHistoryEntry] {
        (try? await store?.history(connectionID: connectionID, matching: search)) ?? []
    }

    public func clearHistory() async {
        try? await store?.clearHistory()
    }

    public func snippets(dialect: SQLDialect?) async -> [Snippet] {
        (try? await store?.snippets(dialect: dialect?.rawValue)) ?? []
    }

    @discardableResult
    public func saveSnippet(_ snippet: Snippet) async -> Int64 {
        (try? await store?.saveSnippet(snippet)) ?? 0
    }

    public func deleteSnippet(id: Int64) async {
        try? await store?.deleteSnippet(id: id)
    }

    public func gridPreferences(connectionID: UUID, table: String) async -> GridPreferences {
        (try? await store?.gridPreferences(connectionID: connectionID, table: table)) ?? .empty
    }

    public func saveGridPreferences(
        _ preferences: GridPreferences,
        connectionID: UUID,
        table: String
    ) async {
        try? await store?.saveGridPreferences(preferences, connectionID: connectionID, table: table)
    }

    public func setting<Value: Codable & Sendable>(_ key: String, default fallback: Value) async -> Value {
        (try? await store?.setting(key, default: fallback)) ?? fallback
    }

    public func setSetting<Value: Codable & Sendable>(_ value: Value, for key: String) async {
        try? await store?.setSetting(value, for: key)
    }
}
