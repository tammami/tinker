import Foundation

/// The stage a connection attempt reached before failing. The connection sheet
/// shows this so the user knows whether to look at DNS, the network, SSH, TLS or credentials.
public enum TunnelStage: String, Sendable, Hashable, Codable, CaseIterable {
    case dns
    case tcp
    case ssh
    case sshAuth
    case portForward
    case tls
    case auth
    case startup
}

/// An error reported by the database server, preserved exactly as received.
public struct ServerError: Sendable, Hashable, Codable {
    /// Five-character SQLSTATE where the server provides one.
    public let sqlState: String?
    /// MySQL numeric error code.
    public let code: Int?
    /// The server's message, verbatim. Never rewritten, translated or summarised.
    public let message: String
    public let detail: String?
    public let hint: String?
    /// One-based character offset into the statement, when the server reports one.
    public let position: Int?

    public init(
        sqlState: String? = nil,
        code: Int? = nil,
        message: String,
        detail: String? = nil,
        hint: String? = nil,
        position: Int? = nil
    ) {
        self.sqlState = sqlState
        self.code = code
        self.message = message
        self.detail = detail
        self.hint = hint
        self.position = position
    }
}

/// Every failure the database layer can produce.
public enum DBError: Error, Sendable, Hashable {
    case connectionFailed(underlying: String, hint: String?)
    case authenticationFailed(user: String)
    case tlsRequiredButUnavailable
    case tunnelFailed(stage: TunnelStage, underlying: String)
    /// The task running the query was cancelled and the server was told to stop.
    case cancelled
    case timeout(after: Duration)
    case server(ServerError)
    case unsupportedType(nativeName: String)
    case protocolError(String)
    case notConnected
}

extension DBError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case let .connectionFailed(underlying, hint):
            hint.map { "\(underlying) (\($0))" } ?? underlying
        case let .authenticationFailed(user):
            "Authentication failed for user \(user)"
        case .tlsRequiredButUnavailable:
            "The server does not support TLS, which this connection requires"
        case let .tunnelFailed(stage, underlying):
            "SSH tunnel failed at stage \(stage.rawValue): \(underlying)"
        case .cancelled:
            "Cancelled"
        case let .timeout(after):
            "Timed out after \(after)"
        case let .server(error):
            error.message
        case let .unsupportedType(nativeName):
            "Unsupported type \(nativeName)"
        case let .protocolError(message):
            "Protocol error: \(message)"
        case .notConnected:
            "Not connected"
        }
    }
}
