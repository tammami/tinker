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
    ///
    /// SQLSTATE 57014 is what the server reports both for a cancel this client asked for
    /// and for its own `statement_timeout`. Only the first is `.cancelled`; the second
    /// keeps the server's words ("canceling statement due to statement timeout"), which
    /// is what the user needs to read. `cancelRequested` says which one this was.
    static func map(_ error: any Error, user: String, cancelRequested: Bool = false) -> DBError {
        if let dbError = error as? DBError { return dbError }
        if error is CancellationError { return .cancelled }

        guard let psql = error as? PSQLError else {
            return .protocolError(String(reflecting: error))
        }

        if let info = psql.serverInfo {
            let sqlState = info[.sqlState]
            if sqlState == queryCanceledSQLState, cancelRequested { return .cancelled }
            // Class 28 after connect (`SET SESSION AUTHORIZATION`, `SET ROLE`) is a server
            // error like any other and is shown verbatim; only `mapConnect` reads it as
            // a failed login.
            return .server(
                ServerError(
                    sqlState: sqlState,
                    code: nil,
                    message: info[.message] ?? "Unknown server error",
                    detail: info[.detail],
                    hint: info[.hint],
                    position: info[.position].flatMap(Int.init)
                ))
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
            // Not `String(reflecting:)`: PSQLError's debug description carries the query
            // and its bound values, which must not reach a banner or the history file.
            return .protocolError(summary(psql))
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
            return .server(
                ServerError(
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
            let stage: TunnelStage =
                text.lowercased().contains("nodename")
                    || text.lowercased().contains("name or service") ? .dns : .tcp
            return .tunnelFailed(stage: stage, underlying: text)
        default:
            return .connectionFailed(underlying: underlyingText(psql), hint: nil)
        }
    }

    /// The most specific text available, preferring NIO's own message over the wrapper's.
    /// Never the wrapper's debug description, which includes the query and its values.
    private static func underlyingText(_ error: PSQLError) -> String {
        if let underlying = error.underlying {
            if let sslError = underlying as? NIOSSLError { return String(reflecting: sslError) }
            return String(describing: underlying)
        }
        return summary(error)
    }

    /// The error's code and, when the server sent one, its message; nothing else.
    private static func summary(_ error: PSQLError) -> String {
        let code = "\(error.code)"
        if let info = error.serverInfo, let message = info[.message] { return "\(code): \(message)" }
        if let underlying = error.underlying { return "\(code): \(String(describing: underlying))" }
        return code
    }
}
