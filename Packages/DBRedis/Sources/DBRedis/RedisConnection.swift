import DBCore
import Foundation
import Logging
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import NIOSSL

/// One connection to a Redis server, bound to one logical database.
///
/// Commands are pipelined: each is written as soon as it is sent and its reply is
/// matched in order, so a batch of a thousand costs one round trip, not a thousand.
/// Server errors come back as ``DBError/server(_:)`` with the server's line verbatim.
public actor RedisConnection {
    /// Where to connect and as whom, after the password was read and any tunnel opened.
    public struct Endpoint: Sendable, Hashable {
        public var host: String
        public var port: Int
        public var user: String?
        public var password: String?
        public var database: Int
        public var tls: TLSConfig
        public var tlsServerName: String?
        public var connectTimeout: Duration
        /// How long one reply may take before the connection is given up on. Nil waits.
        public var commandTimeout: Duration?

        public init(
            host: String, port: Int, user: String? = nil, password: String? = nil, database: Int = 0,
            tls: TLSConfig = TLSConfig(mode: .disable), tlsServerName: String? = nil,
            connectTimeout: Duration = .seconds(10), commandTimeout: Duration? = nil
        ) {
            self.host = host
            self.port = port
            self.user = user
            self.password = password
            self.database = database
            self.tls = tls
            self.tlsServerName = tlsServerName
            self.connectTimeout = connectTimeout
            self.commandTimeout = commandTimeout
        }
    }

    static let eventLoopGroup: MultiThreadedEventLoopGroup = .init(numberOfThreads: 2)

    public nonisolated let endpoint: Endpoint
    private let channel: any Channel
    private let logger: Logger
    public private(set) var database: Int

    private init(channel: any Channel, endpoint: Endpoint, logger: Logger) {
        self.channel = channel
        self.endpoint = endpoint
        self.logger = logger
        database = endpoint.database
    }

    /// Connects, authenticates, names the client and selects the database.
    public static func connect(_ endpoint: Endpoint, logger: Logger) async throws -> RedisConnection {
        let tls = try tlsContext(endpoint)
        let serverName = endpoint.tlsServerName ?? endpoint.tls.serverNameOverride ?? endpoint.host
        let bootstrap = ClientBootstrap(group: eventLoopGroup)
            .connectTimeout(.nanoseconds(Int64(endpoint.connectTimeout.components.seconds) * 1_000_000_000))
            .channelOption(.socketOption(.so_keepalive), value: 1)
            .channelOption(.tcpOption(.tcp_nodelay), value: 1)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        let name = serverName.isIPAddress ? nil : serverName
                        let handler = try NIOSSLClientHandler(context: tls, serverHostname: name)
                        try channel.pipeline.syncOperations.addHandler(handler)
                    }
                    // One reply may hold a 512 MiB string; nothing legitimate needs more buffered.
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(RESPDecoder(), maximumBufferSize: RESPCodec.maximumBulkLength + 64 * 1_024 * 1_024))
                    try channel.pipeline.syncOperations.addHandler(RedisCommandHandler())
                }
            }
        let channel: any Channel
        do {
            channel = try await bootstrap.connect(host: endpoint.host, port: endpoint.port).get()
        } catch {
            throw DBError.connectionFailed(
                underlying: "Cannot reach Redis at \(endpoint.host):\(endpoint.port): \(error)",
                hint: "Check the host, the port, and that the server is running")
        }
        let connection = RedisConnection(channel: channel, endpoint: endpoint, logger: logger)
        do {
            try await connection.handshake()
        } catch {
            await connection.close()
            throw error
        }
        return connection
    }

    private func handshake() async throws {
        if let password = endpoint.password, !password.isEmpty {
            let user = endpoint.user.flatMap { $0.isEmpty ? nil : $0 }
            do {
                if let user {
                    _ = try await send(["AUTH", RedisArgument(user), RedisArgument(password)])
                } else {
                    _ = try await send(["AUTH", RedisArgument(password)])
                }
            } catch let DBError.server(error) {
                if error.message.contains("WRONGPASS") || error.message.contains("invalid password")
                    || error.message.contains("invalid username")
                {
                    throw DBError.authenticationFailed(user: user ?? "default")
                }
                throw DBError.server(error)
            }
        }
        // Named so the server's CLIENT LIST shows who this is. Older servers and some
        // proxies refuse CLIENT; that is not a reason to fail.
        _ = try? await send(["CLIENT", "SETNAME", "tinker"])
        if endpoint.database != 0 { try await select(endpoint.database) }
    }

    /// Switches this connection to another logical database.
    public func select(_ index: Int) async throws {
        _ = try await send(["SELECT", RedisArgument(index)])
        database = index
    }

    /// Sends one command and waits for its reply. A server error throws.
    @discardableResult
    public func send(_ arguments: [RedisArgument]) async throws -> RESPValue {
        let reply = try await sendRaw(arguments)
        if case let .error(message) = reply { throw DBError.server(ServerError(message: message)) }
        return reply
    }

    /// Sends one command and returns its reply, a server error included as `.error`.
    /// The console uses this: an error is an answer to show, not a failure.
    public func sendRaw(_ arguments: [RedisArgument]) async throws -> RESPValue {
        guard channel.isActive else { throw RedisNotSent() }
        let promise = channel.eventLoop.makePromise(of: RESPValue.self)
        channel.writeAndFlush(RedisRequest(arguments: [arguments], promises: [promise]), promise: nil)
        return try await wait(promise.futureResult)
    }

    /// Sends several commands in one write and returns their replies in order. Errors
    /// stay in the result as `.error`, so one refused command does not hide the others.
    public func pipeline(_ commands: [[RedisArgument]]) async throws -> [RESPValue] {
        guard !commands.isEmpty else { return [] }
        guard channel.isActive else { throw RedisNotSent() }
        let promises = commands.map { _ in channel.eventLoop.makePromise(of: RESPValue.self) }
        channel.writeAndFlush(RedisRequest(arguments: commands, promises: promises), promise: nil)
        var replies: [RESPValue] = []
        replies.reserveCapacity(promises.count)
        for promise in promises { replies.append(try await wait(promise.futureResult)) }
        return replies
    }

    private func wait(_ future: EventLoopFuture<RESPValue>) async throws -> RESPValue {
        guard let timeout = endpoint.commandTimeout else { return try await mapped(future) }
        let channel = channel
        let fired = NIOLockedValueBox(false)
        let timer = channel.eventLoop.scheduleTask(in: .nanoseconds(Int64(timeout.components.seconds) * 1_000_000_000)) {
            // A reply that never comes leaves the stream out of step; the connection
            // cannot be used again, so it is closed and every waiter fails.
            fired.withLockedValue { $0 = true }
            channel.close(promise: nil)
        }
        defer { timer.cancel() }
        do {
            return try await mapped(future)
        } catch DBError.notConnected where fired.withLockedValue({ $0 }) {
            // Only a timer that really fired is a timeout; any other drop stays a drop.
            throw DBError.timeout(after: timeout)
        }
    }

    private func mapped(_ future: EventLoopFuture<RESPValue>) async throws -> RESPValue {
        do {
            return try await future.get()
        } catch let error as DBError {
            throw error
        } catch let error as RedisNotSent {
            throw error
        } catch let error as RESPError {
            throw DBError.protocolError(error.description)
        } catch is ChannelError {
            throw DBError.notConnected
        } catch {
            throw DBError.connectionFailed(underlying: String(describing: error), hint: nil)
        }
    }

    public var isOpen: Bool { channel.isActive }

    public func close() async {
        try? await channel.close()
    }

    private static func tlsContext(_ endpoint: Endpoint) throws -> NIOSSLContext? {
        // Redis has no STARTTLS: a port speaks TLS or it does not. "Prefer" cannot probe,
        // so it means plain, and "require" and stricter mean TLS.
        guard endpoint.tls.mode.requiresTLS else { return nil }
        var tls = TLSConfiguration.makeClientConfiguration()
        tls.minimumTLSVersion = .tlsv12
        if let caFile = endpoint.tls.caFile, !caFile.isEmpty {
            do {
                tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMFile(caFile))
            } catch {
                throw DBError.tunnelFailed(stage: .tls, underlying: "Cannot read CA file \(caFile): \(error)")
            }
        }
        if let certFile = endpoint.tls.clientCertFile, let keyFile = endpoint.tls.clientKeyFile,
            !certFile.isEmpty, !keyFile.isEmpty
        {
            do {
                tls.certificateChain = try NIOSSLCertificate.fromPEMFile(certFile).map { .certificate($0) }
                tls.privateKey = .privateKey(try NIOSSLPrivateKey(file: keyFile, format: .pem))
            } catch {
                throw DBError.tunnelFailed(stage: .tls, underlying: "Cannot read client certificate or key: \(error)")
            }
        }
        tls.certificateVerification =
            switch endpoint.tls.mode {
            case .disable, .prefer, .require: .none
            case .verifyCA: .noHostnameVerification
            case .verifyFull: .fullVerification
            }
        do {
            return try NIOSSLContext(configuration: tls)
        } catch {
            throw DBError.tunnelFailed(stage: .tls, underlying: String(describing: error))
        }
    }
}

extension String {
    fileprivate var isIPAddress: Bool {
        var v4 = in_addr()
        var v6 = in6_addr()
        return inet_pton(AF_INET, self, &v4) == 1 || inet_pton(AF_INET6, self, &v6) == 1
    }
}

// MARK: - Channel handlers

/// The command never reached the server: the connection was already closed. Unlike a
/// drop after sending, retrying on a new connection cannot run anything twice.
public struct RedisNotSent: Error, Sendable, CustomStringConvertible {
    public init() {}
    public var description: String { "The connection to Redis is closed." }
}

/// Commands to write, with a promise for each reply.
struct RedisRequest {
    let arguments: [[RedisArgument]]
    let promises: [EventLoopPromise<RESPValue>]
}

struct RESPDecoder: ByteToMessageDecoder {
    typealias InboundOut = RESPValue
    private var scanner = RESPFrameScanner()

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        // The frame is found first, resuming where the last read stopped; it is built
        // only once all of it has arrived.
        guard let length = try scanner.scan(buffer), var frame = buffer.readSlice(length: length) else {
            return .needMoreData
        }
        guard let value = try RESPCodec.decode(&frame) else { throw RESPError("incomplete frame") }
        context.fireChannelRead(wrapInboundOut(value))
        return .continue
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws
        -> DecodingState
    {
        try decode(context: context, buffer: &buffer)
    }
}

/// Writes requests and hands each reply to the oldest waiting promise.
final class RedisCommandHandler: ChannelDuplexHandler {
    typealias InboundIn = RESPValue
    typealias OutboundIn = RedisRequest
    typealias OutboundOut = ByteBuffer

    private var waiting = CircularBuffer<EventLoopPromise<RESPValue>>()

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let request = unwrapOutboundIn(data)
        // Closed between the caller's check and this write: nothing will ever answer.
        guard context.channel.isActive else {
            for reply in request.promises { reply.fail(RedisNotSent()) }
            promise?.fail(ChannelError.ioOnClosedChannel)
            return
        }
        var buffer = context.channel.allocator.buffer(capacity: 64)
        for arguments in request.arguments { RESPCodec.encode(arguments, into: &buffer) }
        for reply in request.promises { waiting.append(reply) }
        let written = context.eventLoop.makePromise(of: Void.self)
        // Completed on this channel's event loop, where the handler and context live.
        written.futureResult.assumeIsolated().whenFailure { [weak self] error in
            // A write that failed leaves the stream out of step; every waiter fails with it.
            self?.failAll(error)
            context.close(promise: nil)
        }
        written.futureResult.cascade(to: promise)
        context.write(wrapOutboundOut(buffer), promise: written)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let value = unwrapInboundIn(data)
        // Out-of-band push frames (RESP3 tracking, pub/sub) answer no request.
        if case .push = value { return }
        guard let promise = waiting.popFirst() else { return }
        promise.succeed(value)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        failAll(error)
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        failAll(DBError.notConnected)
        context.fireChannelInactive()
    }

    private func failAll(_ error: any Error) {
        while let promise = waiting.popFirst() { promise.fail(error) }
    }
}
