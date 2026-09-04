import DBCore
import DBSQL
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO

/// The PostgreSQL driver.
///
/// One ``PostgresSQLConnection`` is one physical connection. Pooling belongs to
/// `ConnectionSession`, which is why this uses `PostgresConnection` rather than
/// `PostgresClient` (DECISIONS.md ADR-0007).
public enum PostgresDriver: SQLDriver {
    public static var dialect: SQLDialect { .postgresql }
    public static var displayName: String { "PostgreSQL" }
    public static var defaultPort: Int { 5432 }

    /// The event loop group every PostgreSQL connection runs on. One group for the whole
    /// process; connections are cheap to add to it and it is never shut down.
    static let eventLoopGroup: MultiThreadedEventLoopGroup = .init(numberOfThreads: 2)

    /// Monotonic ids for PostgresNIO's connection logging metadata.
    private static let connectionCounter = Counter()

    public static func connect(
        _ config: ResolvedConnectionConfig,
        logger: Logger
    ) async throws -> any SQLConnection {
        let tls = try makeTLS(config)
        var configuration = PostgresConnection.Configuration(
            host: config.host,
            port: config.port,
            username: config.user,
            password: config.password,
            database: config.database,
            tls: tls
        )
        configuration.options.connectTimeout = .nanoseconds(
            config.connectTimeout.components.seconds * 1_000_000_000
                + Int64(config.connectTimeout.components.attoseconds / 1_000_000_000)
        )
        if config.tls.mode.verifiesHostname {
            configuration.options.tlsServerName = config.tlsServerName ?? config.host
        }
        var startupParameters: [(String, String)] = []
        if let applicationName = config.options[ConnectionConfig.OptionKey.applicationName] {
            startupParameters.append(("application_name", applicationName))
        } else {
            startupParameters.append(("application_name", "Tinker"))
        }
        configuration.options.additionalStartupParameters = startupParameters

        let underlying: PostgresConnection
        do {
            underlying = try await PostgresConnection.connect(
                on: eventLoopGroup.next(),
                configuration: configuration,
                id: connectionCounter.next(),
                logger: logger
            )
        } catch {
            throw PostgresErrorMapper.mapConnect(error, config: config)
        }

        do {
            return try await PostgresSQLConnection(
                underlying: underlying, config: config, logger: logger
            )
        } catch {
            try? await underlying.close()
            throw error
        }
    }

    /// Builds the NIO TLS configuration for the requested mode.
    ///
    /// `prefer` allows an unencrypted fallback; `require` encrypts without checking the
    /// certificate; `verify-ca` checks the chain; `verify-full` also checks the host name.
    static func makeTLS(_ config: ResolvedConnectionConfig) throws -> PostgresConnection.Configuration.TLS {
        guard config.tls.mode != .disable else { return .disable }

        var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
        if let caFile = config.tls.caFile, !caFile.isEmpty {
            do {
                tlsConfiguration.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(caFile))
            } catch {
                throw DBError.tunnelFailed(stage: .tls, underlying: "Cannot read CA file \(caFile): \(error)")
            }
        }
        if let certFile = config.tls.clientCertFile, let keyFile = config.tls.clientKeyFile,
            !certFile.isEmpty, !keyFile.isEmpty
        {
            do {
                tlsConfiguration.certificateChain = try NIOSSLCertificate.fromPEMFile(certFile).map { .certificate($0) }
                tlsConfiguration.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyFile, format: .pem))
            } catch {
                throw DBError.tunnelFailed(stage: .tls, underlying: "Cannot read client certificate or key: \(error)")
            }
        }
        tlsConfiguration.certificateVerification =
            switch config.tls.mode {
            case .disable, .prefer, .require: .none
            case .verifyCA: .noHostnameVerification
            case .verifyFull: .fullVerification
            }

        let context: NIOSSLContext
        do {
            context = try NIOSSLContext(configuration: tlsConfiguration)
        } catch {
            throw DBError.tunnelFailed(stage: .tls, underlying: String(reflecting: error))
        }
        return config.tls.mode == .prefer ? .prefer(context) : .require(context)
    }
}

/// A thread-safe monotonic counter.
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}
