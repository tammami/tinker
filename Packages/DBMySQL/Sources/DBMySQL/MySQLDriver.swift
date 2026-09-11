import DBCore
import DBSQL
import Foundation
import Logging
import MySQLNIO
import NIOCore
import NIOPosix
import NIOSSL

/// The MySQL and MariaDB driver.
///
/// Authentication covers `caching_sha2_password` — MySQL 8's default, including the RSA
/// public-key exchange used when TLS is off — and `mysql_native_password` (SPEC §7.3).
/// `sha256_password` is not offered by mysql-nio and fails with the server's own message.
public enum MySQLDriver: SQLDriver {
    public static var dialect: SQLDialect { .mysql }
    public static var displayName: String { "MySQL / MariaDB" }
    public static var defaultPort: Int { 3306 }

    /// One event loop group for every MySQL connection in the process.
    static let eventLoopGroup: MultiThreadedEventLoopGroup = .init(numberOfThreads: 2)

    public static func connect(
        _ config: ResolvedConnectionConfig,
        logger: Logger
    ) async throws -> any SQLConnection {
        let underlying = try await openConnection(config, logger: logger)
        do {
            return try await MySQLSQLConnection(underlying: underlying, config: config, logger: logger)
        } catch {
            try? await underlying.close().get()
            throw error
        }
    }

    /// Opens one physical connection, honouring the TLS mode.
    ///
    /// `prefer` falls back to plaintext when the handshake is refused, which is what the
    /// mode means; every stricter mode fails loudly instead. mysql-nio itself proceeds
    /// in the clear when a server greeting lacks the SSL capability, so ``MySQLSQLConnection``
    /// checks the negotiated cipher after the handshake and refuses an unencrypted wire
    /// for any mode that requires one.
    static func openConnection(
        _ config: ResolvedConnectionConfig,
        logger: Logger
    ) async throws -> MySQLConnection {
        let address: SocketAddress
        do {
            address = try SocketAddress.makeAddressResolvingHost(config.host, port: config.port)
        } catch {
            throw DBError.tunnelFailed(stage: .dns, underlying: String(reflecting: error))
        }

        func attempt(tls: TLSConfiguration?) async throws -> MySQLConnection {
            try await MySQLConnection.connect(
                to: address,
                username: config.user,
                database: config.database ?? "",
                password: config.password,
                tlsConfiguration: tls,
                serverHostname: serverNameForSNI(config),
                logger: logger,
                on: eventLoopGroup.next()
            ).get()
        }

        // No retry in the clear when the handshake fails. mysql-nio already proceeds
        // without TLS when the server's greeting lacks the SSL capability, which is the
        // only downgrade `prefer` means; a handshake that *starts* and then fails is a
        // broken or hostile server, and reconnecting in plaintext would hand an on-path
        // attacker exactly the downgrade they were after.
        do {
            return try await attempt(tls: try tlsConfiguration(config))
        } catch {
            throw mapConnect(error, config: config)
        }
    }

    /// The name to send in the TLS handshake, or nil when there is none to send.
    ///
    /// Server Name Indication carries a host name; an IP address is not one, and NIOSSL
    /// refuses it outright, which would make every TLS connection to `127.0.0.1` fail.
    static func serverNameForSNI(_ config: ResolvedConnectionConfig) -> String? {
        let name = config.tlsServerName ?? config.host
        return isIPAddress(name) ? nil : name
    }

    /// True for an IPv4 or IPv6 literal.
    static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1
    }

    /// The NIO TLS settings for a mode, or nil to connect in the clear.
    static func tlsConfiguration(_ config: ResolvedConnectionConfig) throws -> TLSConfiguration? {
        guard config.tls.mode != .disable else { return nil }
        var tls = TLSConfiguration.makeClientConfiguration()
        // TLS 1.0 and 1.1 are broken protocols; nothing this app talks to still needs them.
        tls.minimumTLSVersion = .tlsv12
        if let caFile = config.tls.caFile, !caFile.isEmpty {
            do {
                tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(caFile))
            } catch {
                throw DBError.tunnelFailed(stage: .tls, underlying: "Cannot read CA file \(caFile): \(error)")
            }
        }
        if let certFile = config.tls.clientCertFile, let keyFile = config.tls.clientKeyFile,
            !certFile.isEmpty, !keyFile.isEmpty
        {
            do {
                tls.certificateChain = try NIOSSLCertificate.fromPEMFile(certFile).map { .certificate($0) }
                tls.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyFile, format: .pem))
            } catch {
                throw DBError.tunnelFailed(stage: .tls, underlying: "Cannot read client certificate or key: \(error)")
            }
        }
        // MySQL's `verify-identity` is PostgreSQL's `verify-full`; `required` encrypts
        // without checking the certificate, which is what most local servers can offer.
        tls.certificateVerification =
            switch config.tls.mode {
            case .disable, .prefer, .require: .none
            case .verifyCA: .noHostnameVerification
            case .verifyFull: .fullVerification
            }
        return tls
    }

    static func mapConnect(_ error: any Error, config: ResolvedConnectionConfig) -> DBError {
        if let dbError = error as? DBError { return dbError }
        if let mysql = error as? MySQLError {
            switch mysql {
            case let .server(packet):
                let code = Int(packet.errorCode.rawValue)
                // 1045 access denied, 1044 access denied for database, 1698 auth failure.
                if code == 1_045 || code == 1_044 || code == 1_698 {
                    return .authenticationFailed(user: config.user)
                }
                if code == 1_049 {
                    return .connectionFailed(
                        underlying: packet.errorMessage,
                        hint: "The database does not exist on this server"
                    )
                }
                return .server(MySQLErrorMapper.serverError(packet))
            case .secureConnectionRequired:
                return .tlsRequiredButUnavailable
            default:
                break
            }
        }
        let text = String(reflecting: error)
        if text.contains("connection refused") || text.contains("Connection refused")
            || text.contains("ECONNREFUSED") || text.contains("connectTimeout")
        {
            return .tunnelFailed(stage: .tcp, underlying: text)
        }
        if text.lowercased().contains("nodename") || text.lowercased().contains("name or service") {
            return .tunnelFailed(stage: .dns, underlying: text)
        }
        return .connectionFailed(underlying: text, hint: nil)
    }
}

/// Translates MySQL failures into ``DBError`` without rewriting the server's words.
enum MySQLErrorMapper {
    /// MySQL's error number for a statement stopped by `KILL QUERY`.
    static let queryInterruptedCode = 1_317

    static func serverError(_ packet: MySQLProtocol.ERR_Packet) -> ServerError {
        ServerError(
            sqlState: packet.sqlState,
            code: Int(packet.errorCode.rawValue),
            message: packet.errorMessage
        )
    }

    static func map(_ error: any Error, user: String) -> DBError {
        if let dbError = error as? DBError { return dbError }
        if error is CancellationError { return .cancelled }
        // A connection killed under a statement, or a cable pulled, reaches mysql-nio as
        // the transport's own error rather than a MySQL one: over TLS the peer vanishes
        // without a close-notify (`uncleanShutdown`); over plain TCP the channel is
        // simply closed. Both mean the connection is gone, which is what the session
        // needs to know to replace it (SPEC §9.6).
        if let ssl = error as? NIOSSLError, case .uncleanShutdown = ssl { return .notConnected }
        if let channel = error as? ChannelError, case .ioOnClosedChannel = channel { return .notConnected }
        if error is IOError { return .connectionFailed(underlying: String(reflecting: error), hint: nil) }
        guard let mysql = error as? MySQLError else {
            return .protocolError(String(reflecting: error))
        }
        switch mysql {
        case let .server(packet):
            let code = Int(packet.errorCode.rawValue)
            if code == queryInterruptedCode { return .cancelled }
            if code == 1_045 || code == 1_698 { return .authenticationFailed(user: user) }
            return .server(serverError(packet))
        case let .invalidSyntax(message):
            // mysql-nio unwraps 1064 into its own case, dropping the code and SQLSTATE.
            // The UI shows server errors verbatim, so both are put back.
            return .server(ServerError(sqlState: "42000", code: 1_064, message: message))
        case let .duplicateEntry(message):
            return .server(ServerError(sqlState: "23000", code: 1_062, message: message))
        case let .unsupportedServer(message):
            return .connectionFailed(underlying: message, hint: nil)
        case .secureConnectionRequired:
            return .tlsRequiredButUnavailable
        case .closed:
            return .notConnected
        default:
            return .protocolError(String(reflecting: mysql))
        }
    }
}
