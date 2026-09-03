import Citadel
import Crypto
import DBCore
import DBPostgres
import DBTestKit
import Foundation
import Logging
import NIOCore
import NIOPosix
// The test SSH server drives NIOSSH directly, and its authentication types predate
// Swift 6 concurrency checking. Same rationale as the library's own import.
@preconcurrency import NIOSSH
import XCTest

@testable import DBTunnel

/// End-to-end tunnel tests against an SSH server hosted inside the test process.
///
/// The machine's own `sshd` is not used: Remote Login is off on most developer machines
/// and enabling it needs administrator rights, which `testenv/prepare.sh` is forbidden to
/// take (SPEC §17.1). The in-process server speaks the same protocol over a real socket,
/// so the client path — key exchange, authentication, `direct-tcpip` forwarding — is
/// genuinely exercised. Password and jump-host coverage against a *real* sshd still comes
/// from `DBSTUDIO_TEST_SSH_PASSWORD_URL` / `DBSTUDIO_TEST_SSH_JUMP_URL` when they are set.
final class TunnelIntegrationTests: XCTestCase {
    var logger: Logger {
        var logger = Logger(label: "test.tunnel")
        logger.logLevel = .critical
        return logger
    }

    var server: SSHServer?
    var serverPort = 0
    let password = "test-password"

    override func setUp() async throws {
        serverPort = try TestSSHServer.freePort()
        server = try await TestSSHServer.start(
            port: serverPort, password: password, authorizedKey: nil, logger: logger
        )
    }

    override func tearDown() async throws {
        try? await server?.close()
        server = nil
    }

    func makeConfig(auth: SSHAuth) -> SSHConfig {
        SSHConfig(
            host: "127.0.0.1", port: serverPort, user: "tester",
            auth: auth, knownHostsPolicy: .ignore
        )
    }

    func passwordAuth() async throws -> (SSHAuth, any SecretStore) {
        let reference = SecretRef(account: "test.ssh.password")
        let secrets = EphemeralSecretStore()
        try await secrets.setSecret(password, for: reference)
        return (.password(reference), secrets)
    }

    // MARK: - Forwarding

    func testForwardsBytesToALocalEchoServer() async throws {
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }

        let (auth, secrets) = try await passwordAuth()
        let tunnel = try await SSHTunnelProvider().openTunnel(
            makeConfig(auth: auth), to: "127.0.0.1", port: echo.port, secrets: secrets, logger: logger
        )
        let isOpen = await tunnel.isOpen
        XCTAssertTrue(isOpen)
        XCTAssertGreaterThan(tunnel.localPort, 0)

        let payload = "hello through the tunnel — 日本 🚇"
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: payload)
        XCTAssertEqual(echoed, payload)

        await tunnel.close()
        let closed = await tunnel.isOpen
        XCTAssertFalse(closed)
    }

    func testASecondConnectionThroughTheSameTunnelWorks() async throws {
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let (auth, secrets) = try await passwordAuth()
        let tunnel = try await SSHTunnelProvider().openTunnel(
            makeConfig(auth: auth), to: "127.0.0.1", port: echo.port, secrets: secrets, logger: logger
        )
        defer { Task { await tunnel.close() } }

        for index in 0 ..< 3 {
            let echoed = try await TCPProbe.roundTrip(
                host: "127.0.0.1", port: tunnel.localPort, sending: "message \(index)"
            )
            XCTAssertEqual(echoed, "message \(index)")
        }
    }

    func testLargePayloadSurvivesTheForward() async throws {
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let (auth, secrets) = try await passwordAuth()
        let tunnel = try await SSHTunnelProvider().openTunnel(
            makeConfig(auth: auth), to: "127.0.0.1", port: echo.port, secrets: secrets, logger: logger
        )
        defer { Task { await tunnel.close() } }

        // Larger than one SSH channel window, so the forward must respect flow control.
        let payload = String(repeating: "abcdefghij", count: 40_000)
        let echoed = try await TCPProbe.roundTrip(
            host: "127.0.0.1", port: tunnel.localPort, sending: payload
        )
        XCTAssertEqual(echoed.count, payload.count)
        XCTAssertEqual(echoed, payload)
    }

    // MARK: - Authentication

    func testKeyAuthentication() async throws {
        let key = try SSHKeyFixture.generate(type: "ed25519")
        defer { key.remove() }
        try? await server?.close()
        server = try await TestSSHServer.start(
            port: serverPort, password: nil,
            authorizedKey: try NIOSSHPublicKey(openSSHPublicKey: key.publicKeyLine), logger: logger
        )

        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let tunnel = try await SSHTunnelProvider().openTunnel(
            makeConfig(auth: .privateKey(path: key.path, passphrase: nil)),
            to: "127.0.0.1", port: echo.port, secrets: EphemeralSecretStore(), logger: logger
        )
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "keyed")
        XCTAssertEqual(echoed, "keyed")
    }

    func testWrongPasswordFailsAtTheAuthenticationStage() async throws {
        let reference = SecretRef(account: "test.ssh.password")
        let secrets = EphemeralSecretStore()
        try await secrets.setSecret("not-the-password", for: reference)
        do {
            _ = try await SSHTunnelProvider().openTunnel(
                makeConfig(auth: .password(reference)),
                to: "127.0.0.1", port: 5_432, secrets: secrets, logger: logger
            )
            XCTFail("expected authentication to fail")
        } catch let error as DBError {
            guard case let .tunnelFailed(stage, message) = error else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertEqual(stage, .sshAuth, message)
        }
    }

    func testConnectingToAClosedPortFailsAtTheSSHStage() async throws {
        let (auth, secrets) = try await passwordAuth()
        var config = makeConfig(auth: auth)
        config.port = try TestSSHServer.freePort()
        do {
            _ = try await SSHTunnelProvider().openTunnel(
                config, to: "127.0.0.1", port: 5_432, secrets: secrets, logger: logger
            )
            XCTFail("expected the connection to fail")
        } catch let error as DBError {
            guard case let .tunnelFailed(stage, _) = error else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertEqual(stage, .ssh)
        }
    }

    // MARK: - A real database through the tunnel

    /// SPEC §16 Phase 2 acceptance: a database connection that goes over the forward.
    func testPostgresThroughTheTunnel() async throws {
        let servers = try TestEnvironment.requireServers(for: .postgresql)
        guard let target = servers.first else { return }

        let (auth, secrets) = try await passwordAuth()
        let tunnel = try await SSHTunnelProvider().openTunnel(
            makeConfig(auth: auth), to: target.host, port: target.port, secrets: secrets, logger: logger
        )
        defer { Task { await tunnel.close() } }

        var config = target.resolvedConfig()
        config.tlsServerName = config.host
        config.host = "127.0.0.1"
        config.port = tunnel.localPort

        let connection = try await PostgresDriver.connect(config, logger: logger)
        let version = await connection.serverVersion
        let result = try await connection.executeCollecting("SELECT count(*) FROM smoke")
        await connection.close()

        XCTAssertEqual(result.firstText, "3")
        TestLog.note("SSH tunnel: reached \(version.rawString) through an in-process SSH server")
    }

    /// The whole session path — secrets, tunnel, pool — against the real driver.
    func testConnectionSessionOverTheTunnel() async throws {
        let servers = try TestEnvironment.requireServers(for: .postgresql)
        guard let target = servers.first else { return }

        let reference = SecretRef(account: "session.ssh.password")
        let secrets = EphemeralSecretStore()
        try await secrets.setSecret(password, for: reference)
        if let dbPassword = target.password {
            try await secrets.setSecret(dbPassword, for: SecretRef(account: "session.db.password"))
        }

        let config = ConnectionConfig(
            name: "tunnelled",
            dialect: .postgresql,
            host: target.host,
            port: target.port,
            user: target.user,
            passwordRef: target.password == nil ? nil : SecretRef(account: "session.db.password"),
            database: target.database,
            tls: TLSConfig(mode: .prefer),
            ssh: makeConfig(auth: .password(reference))
        )
        let session = ConnectionSession(
            config: config,
            registry: DriverRegistry([.postgresql: PostgresDriver.self]),
            secrets: secrets,
            tunnelProvider: SSHTunnelProvider(),
            logger: logger
        )
        let version = try await session.connect()
        XCTAssertEqual(version.flavor, .postgresql)

        let (lease, connection) = try await session.lease()
        let result = try await connection.executeCollecting("SELECT 1")
        XCTAssertEqual(result.firstText, "1")
        await session.release(lease)
        await session.disconnect()
        let state = await session.state
        XCTAssertEqual(state, .disconnected)
    }
}

// MARK: - Test helpers

/// An SSH server hosted in the test process, with `direct-tcpip` forwarding enabled.
enum TestSSHServer {
    static func start(
        port: Int,
        password: String?,
        authorizedKey: NIOSSHPublicKey?,
        logger: Logger
    ) async throws -> SSHServer {
        let hostKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let server = try await SSHServer.host(
            host: "127.0.0.1",
            port: port,
            hostKeys: [hostKey],
            logger: logger,
            authenticationDelegate: TestAuthenticationDelegate(
                password: password, authorizedKey: authorizedKey
            )
        )
        // Citadel's own `DirectTCPIPForwardingDelegate` installs only outbound handlers,
        // so nothing is ever forwarded from an inbound read. The test server therefore
        // glues the two channels itself, the same way the client side does.
        server.enableDirectTCPIP(withDelegate: TestForwardingDelegate())
        return server
    }

    /// Asks the kernel for a port, then releases it. Good enough for a local test.
    static func freePort() throws -> Int {
        let socketDescriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else { throw TestError("cannot create a probe socket") }
        defer { close(socketDescriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = INADDR_ANY.bigEndian
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketDescriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw TestError("cannot bind a probe socket") }
        var bound_address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &bound_address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketDescriptor, $0, &length)
            }
        }
        guard named == 0 else { throw TestError("cannot read the probe socket's port") }
        return Int(bound_address.sin_port.bigEndian)
    }
}

/// Forwards an accepted `direct-tcpip` channel to a real TCP endpoint.
struct TestForwardingDelegate: DirectTCPIPDelegate {
    func initializeDirectTCPIPChannel(
        _ channel: any Channel,
        request: SSHChannelType.DirectTCPIP,
        context: SSHContext
    ) -> EventLoopFuture<Void> {
        ClientBootstrap(group: channel.eventLoop)
            .connect(host: request.targetHost, port: request.targetPort)
            .flatMap { remote in
                // Citadel already framed this channel into plain byte buffers, so the
                // glue is all that is missing.
                let (sshSide, socketSide) = GlueHandler.matchedPair()
                return channel.pipeline
                    .addHandler(sshSide)
                    .flatMap { remote.pipeline.addHandler(socketSide) }
            }
    }
}

struct TestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Accepts one password and, optionally, one public key.
final class TestAuthenticationDelegate: NIOSSHServerUserAuthenticationDelegate {
    let password: String?
    let authorizedKey: NIOSSHPublicKey?

    init(password: String?, authorizedKey: NIOSSHPublicKey?) {
        self.password = password
        self.authorizedKey = authorizedKey
    }

    var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
        var methods: NIOSSHAvailableUserAuthenticationMethods = []
        if password != nil { methods.insert(.password) }
        if authorizedKey != nil { methods.insert(.publicKey) }
        return methods
    }

    func requestReceived(
        request: NIOSSHUserAuthenticationRequest,
        responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>
    ) {
        switch request.request {
        case let .password(offered):
            responsePromise.succeed(offered.password == password ? .success : .failure)
        case let .publicKey(offered):
            responsePromise.succeed(offered.publicKey == authorizedKey ? .success : .failure)
        default:
            responsePromise.succeed(.failure)
        }
    }
}

/// A TCP server that returns whatever it is sent, used as the tunnel's far end.
actor EchoServer {
    private let channel: any Channel
    nonisolated let port: Int
    private static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

    private init(channel: any Channel, port: Int) {
        self.channel = channel
        self.port = port
    }

    static func start() async throws -> EchoServer {
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(EchoHandler())
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            throw TestError("the echo server did not get a port")
        }
        return EchoServer(channel: channel, port: port)
    }

    func stop() async {
        try? await channel.close()
    }
}

final class EchoHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        context.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        context.flush()
    }
}

/// Sends text to a TCP endpoint and reads back the same number of bytes.
enum TCPProbe {
    static func roundTrip(host: String, port: Int, sending text: String) async throws -> String {
        let expected = text.utf8.count
        let collector = ByteCollector(expecting: expected)
        let channel = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(CollectingHandler(collector: collector))
                }
            }
            .connect(host: host, port: port)
            .get()
        var buffer = channel.allocator.buffer(capacity: expected)
        buffer.writeString(text)
        try await channel.writeAndFlush(buffer).get()
        let result = try await collector.wait()
        try? await channel.close()
        return result
    }
}

/// Gathers bytes until the expected count has arrived.
final class ByteCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let expected: Int
    private var continuation: CheckedContinuation<String, any Error>?

    init(expecting expected: Int) {
        self.expected = expected
    }

    func append(_ bytes: [UInt8]) {
        lock.lock()
        data.append(contentsOf: bytes)
        let finished = data.count >= expected
        let pending = continuation
        if finished { continuation = nil }
        let snapshot = data
        lock.unlock()
        if finished, let pending {
            pending.resume(returning: String(decoding: snapshot, as: UTF8.self))
        }
    }

    func wait() async throws -> String {
        try await withThrowingTaskGroup(of: String.self) { group in
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    self.lock.lock()
                    if self.data.count >= self.expected {
                        let snapshot = self.data
                        self.lock.unlock()
                        continuation.resume(returning: String(decoding: snapshot, as: UTF8.self))
                        return
                    }
                    self.continuation = continuation
                    self.lock.unlock()
                }
            }
            group.addTask {
                try await Task.sleep(for: .seconds(20))
                throw TestError("timed out waiting for the echo")
            }
            guard let first = try await group.next() else { throw TestError("no result") }
            group.cancelAll()
            return first
        }
    }
}

final class CollectingHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    let collector: ByteCollector

    init(collector: ByteCollector) {
        self.collector = collector
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        collector.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }
}
