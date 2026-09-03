// Citadel predates Swift 6 concurrency checking and marks neither `SSHClient` nor
// `SSHAuthenticationMethod` as Sendable, although both are used across event loops by its
// own API. `@preconcurrency` accepts that contract rather than weakening ours: every use
// here is funnelled through the `SSHPortForward` actor or a single connect call.
@preconcurrency import Citadel
import Crypto
import DBCore
import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSH

/// Opens SSH port forwards using Citadel.
///
/// One provider serves the whole app; each call opens its own SSH connection, because a
/// connection's lifetime is tied to the session that asked for it.
public struct SSHTunnelProvider: TunnelProvider {
    /// The event loop group tunnels run on. Shared, and never shut down.
    static let eventLoopGroup: MultiThreadedEventLoopGroup = .init(numberOfThreads: 2)

    public init() {}

    public func openTunnel(
        _ config: SSHConfig,
        to remoteHost: String,
        port remotePort: Int,
        secrets: any SecretStore,
        logger: Logger
    ) async throws -> any Tunnel {
        let client = try await Self.connectClient(config, secrets: secrets, logger: logger)
        do {
            return try await SSHPortForward(
                client: client, remoteHost: remoteHost, remotePort: remotePort, logger: logger
            )
        } catch {
            try? await client.close()
            throw error
        }
    }

    /// Connects to the SSH host, hopping through the jump host first when one is configured.
    static func connectClient(
        _ config: SSHConfig,
        secrets: any SecretStore,
        logger: Logger
    ) async throws -> SSHClient {
        let authentication = try await authenticationMethod(for: config, secrets: secrets)
        let validator = try hostKeyValidator(for: config)

        if let jump = config.jumpHost?.value {
            let jumpClient = try await connectClient(jump, secrets: secrets, logger: logger)
            do {
                let settings = SSHClientSettings(
                    host: config.host,
                    port: config.port,
                    authenticationMethod: { authentication },
                    hostKeyValidator: validator
                )
                return try await jumpClient.jump(to: settings)
            } catch {
                try? await jumpClient.close()
                throw mapError(error, config: config, stage: .ssh)
            }
        }

        do {
            return try await SSHClient.connect(
                host: config.host,
                port: config.port,
                authenticationMethod: authentication,
                hostKeyValidator: validator,
                reconnect: .never,
                group: eventLoopGroup,
                connectTimeout: .seconds(15)
            )
        } catch {
            throw mapError(error, config: config, stage: .ssh)
        }
    }

    /// Builds the authentication method the config asks for.
    ///
    /// Private keys are read from disk in OpenSSH format. `ed25519` and `rsa` keys are
    /// supported; ECDSA keys are not, because Citadel exposes no OpenSSH reader for them
    /// (see DECISIONS.md ADR-0013).
    static func authenticationMethod(
        for config: SSHConfig,
        secrets: any SecretStore
    ) async throws -> SSHAuthenticationMethod {
        switch config.auth {
        case let .password(reference):
            guard let password = try await secrets.secret(for: reference) else {
                throw DBError.tunnelFailed(
                    stage: .sshAuth, underlying: "No SSH password is stored for \(config.user)@\(config.host)"
                )
            }
            return .passwordBased(username: config.user, password: password)

        case let .privateKey(path, passphraseRef):
            let expanded = (path as NSString).expandingTildeInPath
            guard let contents = try? String(contentsOfFile: expanded, encoding: .utf8) else {
                throw DBError.tunnelFailed(
                    stage: .sshAuth, underlying: "Cannot read the private key at \(expanded)"
                )
            }
            var passphrase: Data?
            if let passphraseRef, let text = try await secrets.secret(for: passphraseRef) {
                passphrase = Data(text.utf8)
            }
            return try privateKeyAuthentication(
                username: config.user, contents: contents, passphrase: passphrase, path: expanded
            )

        case .agent:
            throw DBError.tunnelFailed(
                stage: .sshAuth,
                underlying: "SSH agent authentication is not available in this build. "
                    + "Choose a key file instead; ~/.ssh/id_ed25519 is the usual one."
            )
        }
    }

    static func privateKeyAuthentication(
        username: String,
        contents: String,
        passphrase: Data?,
        path: String
    ) throws -> SSHAuthenticationMethod {
        let keyType: SSHKeyType
        do {
            keyType = try SSHKeyDetection.detectPrivateKeyType(from: contents)
        } catch {
            throw DBError.tunnelFailed(
                stage: .sshAuth, underlying: "\(path) is not a recognised OpenSSH private key"
            )
        }
        do {
            switch keyType {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: contents, decryptionKey: passphrase)
                return .ed25519(username: username, privateKey: key)
            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: contents, decryptionKey: passphrase)
                return .rsa(username: username, privateKey: key)
            default:
                throw DBError.tunnelFailed(
                    stage: .sshAuth,
                    underlying: "\(keyType.description) keys are not supported; use an ed25519 or RSA key"
                )
            }
        } catch let error as DBError {
            throw error
        } catch {
            let hint =
                passphrase == nil
                ? " If the key is encrypted, enter its passphrase."
                : " Check the passphrase."
            throw DBError.tunnelFailed(
                stage: .sshAuth, underlying: "Cannot load \(path): \(error)." + hint
            )
        }
    }

    /// Turns the known-hosts policy into a validator.
    ///
    /// `strict` trusts only keys already in `known_hosts`. `accept-new` additionally
    /// accepts a host that has never been seen, and records it. `ignore` accepts anything
    /// and is only reachable from an explicit checkbox with a warning.
    static func hostKeyValidator(for config: SSHConfig) throws -> SSHHostKeyValidator {
        let file = KnownHostsFile()
        switch config.knownHostsPolicy {
        case .ignore:
            return .acceptAnything()
        case .strict:
            let keys = file.keys(forHost: config.host, port: config.port)
            guard !keys.isEmpty else {
                throw DBError.tunnelFailed(
                    stage: .ssh,
                    underlying: "\(config.host) is not in \(file.path). "
                        + "Connect once with ssh, or set the host-key policy to accept new hosts."
                )
            }
            return .trustedKeys(Set(keys))
        case .acceptNew:
            let keys = file.keys(forHost: config.host, port: config.port)
            if !keys.isEmpty { return .trustedKeys(Set(keys)) }
            return .custom(RecordingHostKeyValidator(file: file, host: config.host, port: config.port))
        }
    }

    static func mapError(_ error: any Error, config: SSHConfig, stage: TunnelStage) -> DBError {
        if let dbError = error as? DBError { return dbError }
        let text = String(reflecting: error)
        if error is InvalidHostKey {
            return .tunnelFailed(
                stage: .ssh,
                underlying: "The host key of \(config.host) does not match \(KnownHostsFile.defaultPath)"
            )
        }
        if text.contains("allAuthenticationOptionsFailed") || text.lowercased().contains("authentication") {
            return .tunnelFailed(
                stage: .sshAuth,
                underlying: "SSH authentication failed for \(config.user)@\(config.host)"
            )
        }
        return .tunnelFailed(stage: stage, underlying: text)
    }
}

/// Accepts a host key that has never been seen and writes it to `known_hosts`,
/// which is what OpenSSH's `StrictHostKeyChecking accept-new` does.
final class RecordingHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let file: KnownHostsFile
    private let host: String
    private let port: Int

    init(file: KnownHostsFile, host: String, port: Int) {
        self.file = file
        self.host = host
        self.port = port
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        // A failure to record must not refuse a connection the policy already accepted;
        // it only means the key is offered again next time.
        try? file.append(host: host, port: port, key: hostKey)
        validationCompletePromise.succeed(())
    }
}

/// A local listener whose every accepted connection is forwarded over SSH.
public actor SSHPortForward: Tunnel {
    private let client: SSHClient
    private let listener: any Channel
    private let logger: Logger
    private var closed = false

    public nonisolated let localPort: Int

    init(client: SSHClient, remoteHost: String, remotePort: Int, logger: Logger) async throws {
        self.client = client
        self.logger = logger

        // Accepted sockets run on the SSH connection's own event loop. The two channels
        // are glued together and write into each other directly, which NIO only permits
        // when they share a loop.
        let bootstrap = ServerBootstrap(
            group: SSHTunnelProvider.eventLoopGroup,
            childGroup: client.eventLoop
        )
        .serverChannelOption(ChannelOptions.backlog, value: 16)
        .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
        .childChannelInitializer { channel in
            Self.forward(channel, through: client, to: remoteHost, port: remotePort, logger: logger)
        }
        .childChannelOption(.socketOption(.so_reuseaddr), value: 1)

        do {
            // Port 0 asks the kernel for a free port, and loopback keeps the forward off
            // every other interface.
            listener = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        } catch {
            throw DBError.tunnelFailed(stage: .portForward, underlying: String(reflecting: error))
        }
        guard let port = listener.localAddress?.port else {
            try? await listener.close()
            throw DBError.tunnelFailed(stage: .portForward, underlying: "The forward did not get a local port")
        }
        localPort = port
        logger.debug(
            "ssh forward listening",
            metadata: [
                "localPort": "\(port)", "target": "\(remoteHost):\(remotePort)",
            ])
    }

    /// Wires one accepted local connection to a fresh `direct-tcpip` channel.
    private static func forward(
        _ local: any Channel,
        through client: SSHClient,
        to remoteHost: String,
        port remotePort: Int,
        logger: Logger
    ) -> EventLoopFuture<Void> {
        let promise = local.eventLoop.makePromise(of: Void.self)
        promise.completeWithTask {
            do {
                let (localGlue, remoteGlue) = GlueHandler.matchedPair()
                _ = try await client.createDirectTCPIPChannel(
                    using: SSHChannelType.DirectTCPIP(
                        targetHost: remoteHost,
                        targetPort: remotePort,
                        originatorAddress: local.remoteAddress
                            ?? (try SocketAddress(ipAddress: "127.0.0.1", port: 0))
                    )
                ) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        try channel.pipeline.syncOperations.addHandler(remoteGlue)
                    }
                }
                try await local.eventLoop.submit {
                    try local.pipeline.syncOperations.addHandler(localGlue)
                }.get()
            } catch {
                logger.debug("forward failed", metadata: ["error": "\(error)"])
                try? await local.close()
                throw error
            }
        }
        return promise.futureResult
    }

    public var isOpen: Bool {
        !closed && listener.isActive && client.isConnected
    }

    public func close() async {
        guard !closed else { return }
        closed = true
        try? await listener.close()
        try? await client.close()
    }
}
