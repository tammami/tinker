import DBCore
import Foundation
import Logging

/// What the server said about itself when the session connected.
public struct RedisServerInfo: Sendable, Hashable {
    /// `redis_version`, or Valkey's `valkey_version` when the server is Valkey.
    public var version: String
    /// "Redis", "Valkey", "KeyDB", "Dragonfly" — from INFO, for the title and the badge.
    public var product: String
    /// `standalone`, `cluster` or `sentinel`.
    public var mode: String
    /// How many logical databases SELECT accepts (CONFIG GET databases; 16 when refused).
    public var databaseCount: Int
    /// Loaded modules by name: `ReJSON`, `search`, `bf`, `timeseries`…
    public var modules: Set<String>
    public var role: String
    /// The commands of ``RedisServerInfo/probedCommands`` this server has, lowercased.
    /// Asked of the server (`COMMAND INFO`), so a fork, a managed service or an older
    /// version is offered exactly what it can do.
    public var commands: Set<String> = []

    public var hasJSON: Bool { supports(.json) || modules.contains("ReJSON") || modules.contains("json") }
    public var hasSearch: Bool { modules.contains("search") || modules.contains("ft") }
    /// Expiry on single hash fields: `HEXPIRE`, `HPTTL`, `HPERSIST` (Redis 7.4).
    public var hasHashFieldExpiry: Bool { supports("hpttl") && supports("hpexpire") && supports("hpersist") }

    /// Whether the server knows a command.
    public func supports(_ command: String) -> Bool { commands.contains(command.lowercased()) }

    /// Whether keys of a type can exist on this server.
    public func supports(_ type: RedisKeyType) -> Bool {
        guard let probe = type.probeCommand else { return true }
        return commands.contains(probe)
    }

    /// The documented types this server has, in the documentation's order.
    public var keyTypes: [RedisKeyType] { RedisKeyType.documented.filter(supports) }

    /// Every command Tinker uses only where the server has it.
    public static let probedCommands: [String] = [
        "json.get", "json.set", "ts.info", "ts.range", "ts.create", "ts.add", "ts.del", "bf.info", "bf.reserve",
        "bf.add", "bf.exists", "cf.info", "cf.reserve", "cf.add", "cf.exists", "cf.del", "topk.info", "topk.list",
        "topk.add", "topk.reserve", "cms.info", "cms.query", "cms.incrby", "cms.initbydim", "tdigest.info",
        "tdigest.quantile", "tdigest.add", "tdigest.create", "tdigest.min", "tdigest.max", "vcard", "vdim", "vinfo",
        "vrandmember", "vrange", "vemb", "vgetattr", "vsim", "vadd", "vrem", "hpttl", "hpexpire", "hpersist", "geopos",
        "geoadd", "pfcount", "pfadd", "bitcount", "object", "memory", "copy", "unlink",
    ]

    /// The commands of a reply to `COMMAND INFO name…`: an entry per name, null for one
    /// the server does not have.
    static func commands(from reply: RESPValue) -> Set<String> {
        var result: Set<String> = []
        for entry in reply.array ?? [] {
            if let name = entry.array?.first?.string { result.insert(name.lowercased()) }
        }
        return result
    }

    /// What a server that refuses `COMMAND` must have, from its version and modules.
    static func assumedCommands(version: String, modules: Set<String>) -> Set<String> {
        let parts = version.split(separator: ".").map { Int($0) ?? 0 }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        func atLeast(_ wantedMajor: Int, _ wantedMinor: Int) -> Bool {
            major > wantedMajor || (major == wantedMajor && minor >= wantedMinor)
        }
        let names = Set(modules.map { $0.lowercased() })
        var prefixes: [String] = []
        if names.contains("rejson") || names.contains("json") { prefixes.append("json.") }
        if names.contains("timeseries") { prefixes.append("ts.") }
        if names.contains("bf") { prefixes += ["bf.", "cf.", "topk.", "cms.", "tdigest."] }
        var result = Set(probedCommands.filter { command in prefixes.contains { command.hasPrefix($0) } })
        result.formUnion(["geopos", "geoadd", "pfcount", "pfadd", "bitcount", "object"])
        if atLeast(4, 0) { result.formUnion(["memory", "unlink"]) }
        if atLeast(6, 2) { result.insert("copy") }
        if atLeast(7, 4) { result.formUnion(["hpttl", "hpexpire", "hpersist"]) }
        if names.contains("vectorset") {
            result.formUnion(probedCommands.filter { $0.hasPrefix("v") })
        }
        return result
    }
}

/// A Redis connection as the app uses it: resolved once from a ``ConnectionConfig``
/// (password from the secret store, SSH tunnel when configured), then one connection per
/// logical database, opened when first used and reopened once if it drops.
///
/// A dedicated actor rather than a ``ConnectionSession``: Redis has no SQL, no schema
/// and no transactions in the sense the SQL session manages, and giving it its own
/// session keeps the SQL code free of Redis special cases.
public actor RedisSession {
    public nonisolated let config: ConnectionConfig
    private let secrets: any SecretStore
    private let tunnelProvider: (any TunnelProvider)?
    private let logger: Logger

    private var tunnel: (any Tunnel)?
    private var tunnelOpening: Task<any Tunnel, any Error>?
    private var password: String??
    private var connections: [Int: RedisConnection] = [:]
    /// Connects in flight, so two callers asking for the same database share one.
    private var connecting: [Int: Task<RedisConnection, any Error>] = [:]
    /// Bumped by ``disconnect()``: a connect that started before it is thrown away
    /// rather than stored in a session that was just closed.
    private var generation = 0
    public private(set) var info: RedisServerInfo?
    /// Set from the connection's read-only flag, and toggled by the lock (⌘⇧L).
    public private(set) var isReadOnly: Bool

    public init(
        config: ConnectionConfig, secrets: any SecretStore, tunnelProvider: (any TunnelProvider)? = nil,
        logger: Logger = Logger(label: "tinker.redis")
    ) {
        self.config = config
        self.secrets = secrets
        self.tunnelProvider = tunnelProvider
        self.logger = logger
        isReadOnly = config.readOnly
    }

    /// The database a connection opens on: the connection's own setting, else 0.
    public nonisolated var defaultDatabase: Int { Int(config.database ?? "") ?? 0 }

    public func setReadOnly(_ readOnly: Bool) { isReadOnly = readOnly }

    /// Connects (if needed) and describes the server.
    @discardableResult
    public func connect() async throws -> RedisServerInfo {
        if let info, let connection = connections[defaultDatabase], await connection.isOpen { return info }
        let connection = try await connection(database: defaultDatabase)
        let described = try await Self.describe(connection)
        info = described
        return described
    }

    /// The connection for a logical database, opened on first use.
    public func connection(database: Int) async throws -> RedisConnection {
        if let existing = connections[database] {
            if await existing.isOpen { return existing }
            if connections[database] === existing { connections[database] = nil }
            await existing.close()
        }
        if let inFlight = connecting[database] { return try await inFlight.value }
        let started = generation
        let logger = logger
        let task = Task { () async throws -> RedisConnection in
            let endpoint = try await self.endpoint(database: database)
            return try await RedisConnection.connect(endpoint, logger: logger)
        }
        connecting[database] = task
        defer { if started == generation { connecting[database] = nil } }
        let connection = try await task.value
        guard started == generation else {
            await connection.close()
            throw DBError.notConnected
        }
        connections[database] = connection
        return connection
    }

    /// Runs `body` on the database's connection, reconnecting once when the connection
    /// was found closed before anything was sent (a server restart, an idle timeout, a
    /// laptop that slept). A drop after a command went out is not retried: the server may
    /// have run it, and running `INCR` or `RPUSH` twice is worse than an error.
    public func withConnection<T: Sendable>(
        database: Int, _ body: @Sendable (RedisConnection) async throws -> T
    ) async throws -> T {
        let connection = try await connection(database: database)
        do {
            return try await body(connection)
        } catch is RedisNotSent {
            if connections[database] === connection { connections[database] = nil }
            await connection.close()
            let fresh = try await self.connection(database: database)
            do {
                return try await body(fresh)
            } catch is RedisNotSent {
                throw DBError.notConnected
            }
        } catch let error as DBError where error.indicatesLostConnection {
            if connections[database] === connection { connections[database] = nil }
            await connection.close()
            throw error
        }
    }

    /// A connection nobody else uses, for commands that hold it: SUBSCRIBE, MONITOR,
    /// BLPOP, or a transfer that must not queue behind the browser. The caller closes it.
    public func dedicatedConnection(database: Int) async throws -> RedisConnection {
        try await RedisConnection.connect(try await endpoint(database: database), logger: logger)
    }

    public func disconnect() async {
        generation += 1
        for task in connecting.values { task.cancel() }
        connecting = [:]
        let open = connections.values
        connections = [:]
        info = nil
        for connection in open { await connection.close() }
        tunnelOpening?.cancel()
        tunnelOpening = nil
        let closing = tunnel
        tunnel = nil
        await closing?.close()
    }

    private func endpoint(database: Int) async throws -> RedisConnection.Endpoint {
        if password == nil {
            if let reference = config.passwordRef {
                password = .some(try await secrets.secret(for: reference))
            } else {
                password = .some(nil)
            }
        }
        var host = config.host
        var port = config.port
        if let ssh = config.ssh {
            let forward = try await openTunnel(ssh)
            host = "127.0.0.1"
            port = forward.localPort
        }
        return RedisConnection.Endpoint(
            host: host, port: port, user: config.user.isEmpty ? nil : config.user, password: password ?? nil,
            database: database, tls: config.tls, tlsServerName: config.tls.serverNameOverride ?? config.host,
            commandTimeout: config.statementTimeout)
    }

    /// The SSH forward, opened once however many databases connect at the same time.
    private func openTunnel(_ ssh: SSHConfig) async throws -> any Tunnel {
        if let tunnel, await tunnel.isOpen { return tunnel }
        if let opening = tunnelOpening { return try await opening.value }
        guard let tunnelProvider else {
            throw DBError.tunnelFailed(stage: .ssh, underlying: "SSH tunnelling is not available")
        }
        let (host, port, secrets, logger) = (config.host, config.port, secrets, logger)
        let task = Task { try await tunnelProvider.openTunnel(ssh, to: host, port: port, secrets: secrets, logger: logger) }
        tunnelOpening = task
        defer { tunnelOpening = nil }
        let opened = try await task.value
        let previous = tunnel
        tunnel = opened
        await previous?.close()
        return opened
    }

    /// INFO server, the module list and the database count, read in one round trip.
    static func describe(_ connection: RedisConnection) async throws -> RedisServerInfo {
        let replies = try await connection.pipeline([
            ["INFO", "server"], ["CONFIG", "GET", "databases"], ["MODULE", "LIST"], ["INFO", "replication"],
            ["COMMAND", "INFO"] + RedisServerInfo.probedCommands.map { RedisArgument($0) },
        ])
        let server = RedisInfo.parse(replies[0].string ?? "")
        let fields = server.values
        var product = "Redis"
        var version = fields["redis_version"] ?? "?"
        if let valkey = fields["valkey_version"] {
            product = "Valkey"
            version = valkey
        } else if fields["dragonfly_version"] != nil {
            product = "Dragonfly"
            version = fields["dragonfly_version"] ?? version
        } else if fields.keys.contains(where: { $0.hasPrefix("keydb") }) || (fields["server_name"] ?? "") == "keydb" {
            product = "KeyDB"
        }
        // Managed services often refuse CONFIG; SELECT then decides, and 16 is Redis's default.
        let databases = replies[1].pairs.first.flatMap { $0.1.integer }.map(Int.init) ?? 16
        var modules: Set<String> = []
        for module in replies[2].array ?? [] {
            for (key, value) in module.pairs where key.string == "name" {
                if let name = value.string { modules.insert(name) }
            }
        }
        let role = RedisInfo.parse(replies[3].string ?? "").values["role"] ?? "master"
        // A server that refuses COMMAND (an ACL, a proxy) is taken at its version's word.
        var commands = RedisServerInfo.commands(from: replies[4])
        if case .error = replies[4] { commands = RedisServerInfo.assumedCommands(version: version, modules: modules) }
        return RedisServerInfo(
            version: version, product: product, mode: fields["redis_mode"] ?? "standalone",
            databaseCount: max(1, databases), modules: modules, role: role, commands: commands)
    }
}

/// The `INFO` reply, as sections of `key:value` lines.
public struct RedisInfo: Sendable, Hashable {
    /// Section name (as written after `# `) → its fields in order.
    public var sections: [(name: String, fields: [(key: String, value: String)])]

    public var values: [String: String] {
        var result: [String: String] = [:]
        for section in sections { for (key, value) in section.fields { result[key] = value } }
        return result
    }

    public static func parse(_ text: String) -> RedisInfo {
        var sections: [(name: String, fields: [(key: String, value: String)])] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#") {
                sections.append((String(trimmed.dropFirst().trimmingCharacters(in: .whitespaces)), []))
                continue
            }
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            if sections.isEmpty { sections.append(("Info", [])) }
            sections[sections.count - 1].fields.append(
                (String(trimmed[..<colon]), String(trimmed[trimmed.index(after: colon)...])))
        }
        return RedisInfo(sections: sections)
    }

    public static func == (lhs: RedisInfo, rhs: RedisInfo) -> Bool {
        lhs.sections.map(\.name) == rhs.sections.map(\.name)
            && zip(lhs.sections, rhs.sections).allSatisfy { a, b in
                a.fields.map(\.key) == b.fields.map(\.key) && a.fields.map(\.value) == b.fields.map(\.value)
            }
    }

    public func hash(into hasher: inout Hasher) {
        for section in sections {
            hasher.combine(section.name)
            for (key, value) in section.fields {
                hasher.combine(key)
                hasher.combine(value)
            }
        }
    }
}
