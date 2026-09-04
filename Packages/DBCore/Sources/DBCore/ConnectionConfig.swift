import Foundation

/// A reference to a secret held in the macOS Keychain. The secret itself never
/// appears in a config, on disk, in a log, or in a crash report.
public struct SecretRef: Sendable, Hashable, Codable {
    /// Keychain service, always `com.tinker.connection`.
    public let service: String
    /// Keychain account, `<configID>.<field>`.
    public let account: String

    public init(service: String = SecretRef.defaultService, account: String) {
        self.service = service
        self.account = account
    }

    public static let defaultService = "com.tinker.connection"
    /// The service the app used while it was called DBStudio; a secret still filed
    /// there is read once and moved.
    public static let legacyService = "com.dbstudio.connection"

    /// The reference for one field of one connection, e.g. `password` or `sshPassphrase`.
    public static func forConnection(_ id: UUID, field: String) -> SecretRef {
        SecretRef(account: "\(id.uuidString).\(field)")
    }
}

/// The colour stripe shown on a connection and its tabs.
public enum ConnectionColor: String, Sendable, Hashable, Codable, CaseIterable {
    case red, orange, yellow, green, blue, purple, gray
}

/// How much of the server's certificate chain is checked.
public enum TLSMode: String, Sendable, Hashable, Codable, CaseIterable {
    /// Never negotiate TLS.
    case disable
    /// Use TLS when the server offers it; fall back to plaintext otherwise.
    case prefer
    /// Require TLS but do not verify the certificate.
    case require
    /// Require TLS and verify the chain against the CA.
    case verifyCA = "verify-ca"
    /// Require TLS, verify the chain, and check the host name.
    case verifyFull = "verify-full"

    public var requiresTLS: Bool { self != .disable && self != .prefer }
    public var verifiesCertificate: Bool { self == .verifyCA || self == .verifyFull }
    public var verifiesHostname: Bool { self == .verifyFull }
}

public struct TLSConfig: Sendable, Hashable, Codable {
    public var mode: TLSMode
    /// PEM file holding the CA certificate(s) to verify against.
    public var caFile: String?
    /// Client certificate for mutual TLS (Phase 3).
    public var clientCertFile: String?
    public var clientKeyFile: String?
    /// Host name to verify against, when it differs from the connection host.
    public var serverNameOverride: String?

    public init(
        mode: TLSMode = .prefer,
        caFile: String? = nil,
        clientCertFile: String? = nil,
        clientKeyFile: String? = nil,
        serverNameOverride: String? = nil
    ) {
        self.mode = mode
        self.caFile = caFile
        self.clientCertFile = clientCertFile
        self.clientKeyFile = clientKeyFile
        self.serverNameOverride = serverNameOverride
    }

    public static let `default` = TLSConfig()
}

/// How the SSH host key is checked.
public enum KnownHostsPolicy: String, Sendable, Hashable, Codable, CaseIterable {
    /// Fail unless the key is already in `known_hosts`.
    case strict
    /// Accept and record a key for a host that is not yet known; fail on a changed key.
    case acceptNew = "accept-new"
    /// Accept any key. Requires an explicit opt-in in the UI.
    case ignore
}

/// How to authenticate to the SSH host.
public enum SSHAuth: Sendable, Hashable, Codable {
    case password(SecretRef)
    case privateKey(path: String, passphrase: SecretRef?)
    case agent
}

public struct SSHConfig: Sendable, Hashable, Codable {
    public var host: String
    public var port: Int
    public var user: String
    public var auth: SSHAuth
    /// One level of bastion host. Boxed so the struct stays a value type.
    public var jumpHost: Box<SSHConfig>?
    public var knownHostsPolicy: KnownHostsPolicy

    public init(
        host: String,
        port: Int = 22,
        user: String,
        auth: SSHAuth,
        jumpHost: SSHConfig? = nil,
        knownHostsPolicy: KnownHostsPolicy = .acceptNew
    ) {
        self.host = host
        self.port = port
        self.user = user
        self.auth = auth
        self.jumpHost = jumpHost.map(Box.init)
        self.knownHostsPolicy = knownHostsPolicy
    }
}

/// A reference box, used where a value type needs to contain itself.
public final class Box<Wrapped: Sendable & Hashable & Codable>: Sendable, Hashable, Codable {
    public let value: Wrapped

    public init(_ value: Wrapped) { self.value = value }

    public static func == (lhs: Box<Wrapped>, rhs: Box<Wrapped>) -> Bool { lhs.value == rhs.value }
    public func hash(into hasher: inout Hasher) { hasher.combine(value) }

    public convenience init(from decoder: any Decoder) throws {
        self.init(try Wrapped(from: decoder))
    }

    public func encode(to encoder: any Encoder) throws { try value.encode(to: encoder) }
}

/// Everything needed to reach one server, as edited in the connection sheet and
/// stored in `DBStore`. Contains no secrets, only Keychain references.
public struct ConnectionConfig: Sendable, Hashable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ConnectionColor?
    /// Folder hierarchy in the sidebar, outermost first.
    public var groupPath: [String]
    public var dialect: SQLDialect
    public var host: String
    public var port: Int
    public var user: String
    public var passwordRef: SecretRef?
    /// Database to open on connect.
    public var database: String?
    public var tls: TLSConfig
    public var ssh: SSHConfig?
    /// Driver-specific extras, e.g. `application_name` or `tinyint1IsBool`.
    public var options: [String: String]
    public var statementTimeout: Duration?
    /// Blocks any non-SELECT statement unless the user unlocks the session.
    public var readOnly: Bool
    /// Adds a confirmation to every write and a red badge in the sidebar.
    public var isProduction: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        color: ConnectionColor? = nil,
        groupPath: [String] = [],
        dialect: SQLDialect,
        host: String,
        port: Int,
        user: String,
        passwordRef: SecretRef? = nil,
        database: String? = nil,
        tls: TLSConfig = .default,
        ssh: SSHConfig? = nil,
        options: [String: String] = [:],
        statementTimeout: Duration? = nil,
        readOnly: Bool = false,
        isProduction: Bool = false
    ) {
        self.id = id
        self.name = name
        self.color = color
        self.groupPath = groupPath
        self.dialect = dialect
        self.host = host
        self.port = port
        self.user = user
        self.passwordRef = passwordRef
        self.database = database
        self.tls = tls
        self.ssh = ssh
        self.options = options
        self.statementTimeout = statementTimeout
        self.readOnly = readOnly
        self.isProduction = isProduction
    }

    /// Known keys for ``ConnectionConfig/options``.
    public enum OptionKey {
        /// PostgreSQL `application_name`.
        public static let applicationName = "application_name"
        /// MySQL: treat a column declared `tinyint(1)` as boolean. Default true.
        public static let tinyint1IsBool = "tinyint1IsBool"
    }
}

/// A connection config with its secrets resolved and its endpoint pointing at the
/// real destination — for a tunnelled connection, the local end of the forward.
///
/// Instances are short-lived and never persisted, logged or encoded.
public struct ResolvedConnectionConfig: Sendable {
    public var configID: UUID
    public var dialect: SQLDialect
    /// Where the driver actually connects. `127.0.0.1` when a tunnel is in use.
    public var host: String
    public var port: Int
    /// The host name the certificate must match, which stays the *original* host
    /// when the connection is tunnelled.
    public var tlsServerName: String?
    public var user: String
    public var password: String?
    public var database: String?
    public var tls: TLSConfig
    public var options: [String: String]
    public var connectTimeout: Duration
    public var statementTimeout: Duration?

    public init(
        configID: UUID,
        dialect: SQLDialect,
        host: String,
        port: Int,
        tlsServerName: String? = nil,
        user: String,
        password: String? = nil,
        database: String? = nil,
        tls: TLSConfig = .default,
        options: [String: String] = [:],
        connectTimeout: Duration = .seconds(15),
        statementTimeout: Duration? = nil
    ) {
        self.configID = configID
        self.dialect = dialect
        self.host = host
        self.port = port
        self.tlsServerName = tlsServerName
        self.user = user
        self.password = password
        self.database = database
        self.tls = tls
        self.options = options
        self.connectTimeout = connectTimeout
        self.statementTimeout = statementTimeout
    }
}

extension ResolvedConnectionConfig: CustomStringConvertible {
    /// Deliberately omits the password so the type is safe to interpolate into a log.
    public var description: String {
        "\(dialect.rawValue)://\(user)@\(host):\(port)/\(database ?? "")"
    }
}
