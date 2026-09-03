import DBCore
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
    public private(set) var startupError: String?

    // MySQL joins the registry in Phase 6; until then a MySQL connection reports that
    // no driver is registered rather than failing obscurely.
    public let registry = DriverRegistry([.postgresql: PostgresDriver.self])
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
           let password = try? await secrets.secret(for: source) {
            let destination = SecretRef.forConnection(copy.id, field: SecretField.password.rawValue)
            try? await secrets.setSecret(password, for: destination)
            copy.passwordRef = destination
        }
        await save(copy)
    }

    public func reorderConnections(_ ids: [UUID]) async {
        try? await store?.reorderConnections(ids)
        connections = (try? await store?.connections()) ?? connections
    }

    // MARK: - Sessions

    /// The session for a configuration, created on first use.
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

    /// Drops a cached session so the next use picks up an edited configuration.
    public func invalidateSession(for id: UUID) async {
        guard let session = sessions.removeValue(forKey: id) else { return }
        await session.disconnect()
    }

    public func disconnectAll() async {
        for session in sessions.values { await session.disconnect() }
        sessions.removeAll()
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
