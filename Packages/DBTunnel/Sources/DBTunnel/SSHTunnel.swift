// Citadel predates Swift 6 concurrency checking and marks neither `SSHClient` nor
// `SSHAuthenticationMethod` as Sendable, although both are used across event loops by its
// own API. `@preconcurrency` accepts that contract rather than weakening ours: every use
// here is funnelled through the `SSHPortForward` actor or a single connect call.
@preconcurrency import Citadel
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
    ///
    /// A key file yields one attempt per signature algorithm the key supports, strongest
    /// first, and each attempt is a connection of its own: Citadel's authentication method
    /// gives a delegate one turn (see `SingleKeyAuthenticationDelegate`). A modern server
    /// accepts the first; only a server that refuses it costs another handshake.
    static func connectClient(
        _ config: SSHConfig,
        secrets: any SecretStore,
        logger: Logger
    ) async throws -> SSHClient {
        let attempts = try await authenticationAttempts(for: config, secrets: secrets)
        let validator = try hostKeyValidator(for: config)

        var jumpClient: SSHClient?
        if let jump = config.jumpHost?.value {
            jumpClient = try await connectClient(jump, secrets: secrets, logger: logger)
        }

        var refused: [String] = []
        for (index, attempt) in attempts.enumerated() {
            do {
                if let jumpClient {
                    let settings = SSHClientSettings(
                        host: config.host,
                        port: config.port,
                        authenticationMethod: { attempt.method },
                        hostKeyValidator: validator
                    )
                    return try await jumpClient.jump(to: settings)
                }
                return try await SSHClient.connect(
                    host: config.host,
                    port: config.port,
                    authenticationMethod: attempt.method,
                    hostKeyValidator: validator,
                    reconnect: .never,
                    group: eventLoopGroup,
                    connectTimeout: .seconds(15)
                )
            } catch {
                if let algorithm = attempt.algorithm {
                    refused.append(algorithm)
                    if index < attempts.count - 1, Self.isKeyRefusal(error) {
                        logger.debug(
                            "ssh key refused; trying the next algorithm",
                            metadata: ["refused": "\(algorithm)", "next": "\(attempts[index + 1].algorithm ?? "")"])
                        continue
                    }
                }
                if let jumpClient { try? await jumpClient.close() }
                throw mapError(error, config: config, stage: .ssh, refusedAlgorithms: refused)
            }
        }
        // `authenticationAttempts` never returns an empty list.
        throw DBError.tunnelFailed(stage: .sshAuth, underlying: "No way to authenticate to \(config.host)")
    }

    /// Whether the server turned the offered key down, as opposed to the connection failing
    /// for another reason. Citadel reports the refusal as every option having failed.
    static func isKeyRefusal(_ error: any Error) -> Bool {
        if let refused = error as? KeyAuthenticationRefused, case .keyRefused = refused { return true }
        return String(reflecting: error).contains("allAuthenticationOptionsFailed")
    }

    /// Builds the authentication attempts the config asks for — one for a password, one per
    /// signature algorithm for a key file.
    ///
    /// Private keys are read by `OpenSSHPrivateKey` — the OpenSSH format and the older PEM
    /// ones, encrypted or not — and offered through `SingleKeyAuthenticationDelegate`
    /// (ADR-0039).
    static func authenticationAttempts(
        for config: SSHConfig,
        secrets: any SecretStore
    ) async throws -> [SSHAuthenticationAttempt] {
        switch config.auth {
        case let .password(reference):
            guard let password = try await secrets.secret(for: reference) else {
                throw DBError.tunnelFailed(
                    stage: .sshAuth, underlying: "No SSH password is stored for \(config.user)@\(config.host)"
                )
            }
            return [SSHAuthenticationAttempt(algorithm: nil, method: .passwordBased(username: config.user, password: password))]

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
    ) throws -> [SSHAuthenticationAttempt] {
        let key: OpenSSHPrivateKey
        do {
            key = try OpenSSHPrivateKey.parse(contents, passphrase: passphrase)
        } catch let error as OpenSSHKeyError {
            throw DBError.tunnelFailed(stage: .sshAuth, underlying: error.message(path: path))
        }
        return KeyFileAuthentication.candidates(for: key).map { candidate in
            SSHAuthenticationAttempt(
                algorithm: candidate.algorithm,
                method: .custom(SingleKeyAuthenticationDelegate(username: username, candidate: candidate))
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
        let revoked = Set(file.revokedKeys(forHost: config.host, port: config.port))
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
            return .custom(RevocationAwareHostKeyValidator(trusted: Set(keys), revoked: revoked, recordingTo: nil))
        case .acceptNew:
            let keys = file.keys(forHost: config.host, port: config.port)
            if !keys.isEmpty {
                return .custom(RevocationAwareHostKeyValidator(trusted: Set(keys), revoked: revoked, recordingTo: nil))
            }
            return .custom(
                RevocationAwareHostKeyValidator(
                    trusted: [], revoked: revoked,
                    recordingTo: RecordingHostKeyValidator(file: file, host: config.host, port: config.port)))
        }
    }

    static func mapError(
        _ error: any Error, config: SSHConfig, stage: TunnelStage, refusedAlgorithms: [String] = []
    ) -> DBError {
        if let dbError = error as? DBError { return dbError }
        let text = String(reflecting: error)
        if error is RevokedHostKey || text.contains("RevokedHostKey") {
            return .tunnelFailed(
                stage: .ssh,
                underlying: "The host key of \(config.host) is marked @revoked in \(KnownHostsFile.defaultPath)"
            )
        }
        if error is InvalidHostKey || error is UntrustedHostKey {
            return .tunnelFailed(
                stage: .ssh,
                underlying: "The host key of \(config.host) does not match \(KnownHostsFile.defaultPath)"
            )
        }
        if let refused = error as? KeyAuthenticationRefused, case .publicKeyNotAccepted = refused {
            return .tunnelFailed(
                stage: .sshAuth,
                underlying: "SSH authentication failed for \(config.user)@\(config.host): \(refused)"
            )
        }
        if isKeyRefusal(error) || text.lowercased().contains("authentication") {
            let detail =
                refusedAlgorithms.isEmpty
                ? ""
                : ": the server refused the key (offered \(refusedAlgorithms.joined(separator: ", ")))"
            return .tunnelFailed(
                stage: .sshAuth,
                underlying: "SSH authentication failed for \(config.user)@\(config.host)" + detail
            )
        }
        return .tunnelFailed(stage: stage, underlying: text)
    }
}

/// One way of authenticating: a password, or a key under one signature algorithm.
struct SSHAuthenticationAttempt {
    /// The public-key algorithm name, or nil for a password.
    let algorithm: String?
    let method: SSHAuthenticationMethod
}

/// Refuses a key `known_hosts` marks `@revoked`, whatever the policy; otherwise accepts a
/// trusted key, or — with a recorder — a first sighting, as `accept-new` does.
final class RevocationAwareHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let trusted: Set<NIOSSHPublicKey>
    private let revoked: Set<NIOSSHPublicKey>
    private let recorder: RecordingHostKeyValidator?

    init(trusted: Set<NIOSSHPublicKey>, revoked: Set<NIOSSHPublicKey>, recordingTo recorder: RecordingHostKeyValidator?)
    {
        self.trusted = trusted
        self.revoked = revoked
        self.recorder = recorder
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        if revoked.contains(hostKey) {
            validationCompletePromise.fail(RevokedHostKey())
            return
        }
        if trusted.contains(hostKey) {
            validationCompletePromise.succeed(())
            return
        }
        if let recorder {
            recorder.validateHostKey(hostKey: hostKey, validationCompletePromise: validationCompletePromise)
            return
        }
        validationCompletePromise.fail(UntrustedHostKey())
    }
}

/// The server presented a key `known_hosts` marks `@revoked`.
struct RevokedHostKey: Error {}

/// The server presented a key that is neither trusted nor, under this policy, recordable.
struct UntrustedHostKey: Error {}

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
