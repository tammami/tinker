import Foundation
import Logging

/// A live port forward. While it exists, `127.0.0.1:localPort` reaches the remote endpoint.
public protocol Tunnel: Sendable {
    /// The loopback port the driver connects to.
    var localPort: Int { get }
    /// True while the underlying SSH connection is up.
    var isOpen: Bool { get async }
    func close() async
}

/// Opens port forwards. `DBTunnel` provides the SSH implementation; `DBCore` only
/// declares the interface so the session actor does not depend on an SSH library.
public protocol TunnelProvider: Sendable {
    /// Opens a forward from an ephemeral loopback port to `remoteHost:remotePort`,
    /// reached through the SSH host in `config` (and its jump host, if any).
    ///
    /// - Throws: ``DBError/tunnelFailed(stage:underlying:)`` naming the stage that failed.
    func openTunnel(
        _ config: SSHConfig,
        to remoteHost: String,
        port remotePort: Int,
        secrets: any SecretStore,
        logger: Logger
    ) async throws -> any Tunnel
}
