import DBCore
import Foundation
import NIOSSL
import PostgresNIO

/// Translates driver and server failures into ``DBError`` without rewriting the server's words.
enum PostgresErrorMapper {
    /// SQLSTATE PostgreSQL reports when a statement is cancelled at the user's request.
    static let queryCanceledSQLState = "57014"
    /// SQLSTATE for a backend terminated by an administrator.
    static let adminShutdownSQLState = "57P01"

    /// Maps an error raised while a statement was running.
    static func map(_ error: any Error, user: String) -> DBError {
        if let dbError = error as? DBError { return dbError }
        if error is CancellationError { return .cancelled }

        guard let psql = error as? PSQLError else {
            return .protocolError(String(reflecting: error))
        }

        if let info = psql.serverInfo {
            let sqlState = info[.sqlState]
            if sqlState == queryCanceledSQLState { return .cancelled }
            let serverError = ServerError(
                sqlState: sqlState,
                code: nil,
                message: info[.message] ?? "Unknown server error",
                detail: info[.detail],
                hint: info[.hint],
                position: info[.position].flatMap(Int.init)
            )
            // Authentication failures carry class 28; the sheet shows the stage, not a rewrite.
            if sqlState?.hasPrefix("28") == true { return .authenticationFailed(user: user) }
            return .server(serverError)
        }

        switch psql.code {
        case .queryCancelled:
            return .cancelled
        case .sslUnsupported:
            return .tlsRequiredButUnavailable
        case .authMechanismRequiresPassword:
            return .authenticationFailed(user: user)
        case .unsupportedAuthMechanism:
            return .connectionFailed(
                underlying: "The server requested an authentication method this client does not support",
                hint: "PostgreSQL supports password, MD5 and SCRAM-SHA-256 here"
            )
        case .clientClosedConnection, .serverClosedConnection:
            return .notConnected
        case .connectionError:
            return .connectionFailed(underlying: underlyingText(psql), hint: nil)
        default:
            return .protocolError(String(reflecting: psql))
        }
    }

    /// Maps an error raised while opening a connection, tagging the stage it failed at.
    static func mapConnect(_ error: any Error, config: ResolvedConnectionConfig) -> DBError {
        if let dbError = error as? DBError { return dbError }
        if error is CancellationError { return .cancelled }

        guard let psql = error as? PSQLError else {
            return .connectionFailed(underlying: String(reflecting: error), hint: nil)
        }

        if let info = psql.serverInfo {
            let sqlState = info[.sqlState]
            let message = info[.message] ?? "Connection refused by server"
            if sqlState?.hasPrefix("28") == true { return .authenticationFailed(user: config.user) }
            if sqlState == "3D000" {
                return .connectionFailed(underlying: message, hint: "The database does not exist on this server")
            }
            return .server(ServerError(
                sqlState: sqlState, code: nil, message: message,
                detail: info[.detail], hint: info[.hint], position: nil
            ))
        }

        switch psql.code {
        case .sslUnsupported:
            return .tlsRequiredButUnavailable
        case .failedToAddSSLHandler, .receivedUnencryptedDataAfterSSLRequest:
            return .tunnelFailed(stage: .tls, underlying: underlyingText(psql))
        case .authMechanismRequiresPassword:
            return .authenticationFailed(user: config.user)
        case .connectionError:
            let text = underlyingText(psql)
            let stage: TunnelStage = text.lowercased().contains("nodename")
                || text.lowercased().contains("name or service") ? .dns : .tcp
            return .tunnelFailed(stage: stage, underlying: text)
        default:
            return .connectionFailed(underlying: underlyingText(psql), hint: nil)
        }
    }

    /// The most specific text available, preferring NIO's own message over the wrapper's.
    private static func underlyingText(_ error: PSQLError) -> String {
        if let underlying = error.underlying {
            if let sslError = underlying as? NIOSSLError { return String(reflecting: sslError) }
            return String(reflecting: underlying)
        }
        return String(reflecting: error)
    }
}
