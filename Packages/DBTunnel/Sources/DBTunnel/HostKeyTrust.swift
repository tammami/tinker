import Crypto
import DBCore
import Foundation
import NIOCore
import NIOSSH

/// What the user is shown when a host presents a key nobody has seen before.
public struct HostKeyPresentation: Sendable, Hashable {
    public let host: String
    public let port: Int
    /// `ssh-ed25519`, `ecdsa-sha2-nistp256`, `ssh-rsa`, …
    public let keyType: String
    /// `SHA256:…`, the form `ssh` prints, so it can be compared with what the server's
    /// administrator published.
    public let fingerprint: String

    public init(host: String, port: Int, keyType: String, fingerprint: String) {
        self.host = host
        self.port = port
        self.keyType = keyType
        self.fingerprint = fingerprint
    }

    /// Describes `key` for `host`.
    public init(host: String, port: Int, key: NIOSSHPublicKey) {
        var writer = ByteBufferAllocator().buffer(capacity: 256)
        key.write(to: &writer)
        let blob = Data(writer.readBytes(length: writer.readableBytes) ?? [])
        let digest = Data(SHA256.hash(data: blob))
        // OpenSSH prints the base64 without its trailing padding.
        let encoded = digest.base64EncodedString().replacingOccurrences(of: "=", with: "")
        self.init(
            host: host, port: port,
            keyType: KnownHostsFile.readSSHString(from: blob, at: 0) ?? "unknown",
            fingerprint: "SHA256:\(encoded)"
        )
    }
}

/// Asked once per unknown host under the `accept-new` policy; true trusts and records the
/// key, false refuses the connection. Runs off the event loop, so it may show a sheet.
public typealias HostKeyConfirmation = @Sendable (HostKeyPresentation) async -> Bool

/// Where host keys are read from, where a newly accepted one is written, and who is
/// asked before it is.
///
/// Reading covers the user's own `~/.ssh/known_hosts`, so a host `ssh` already trusts
/// is trusted here too. Recording goes to Tinker's own file: a key accepted on first
/// sight in this app must not become something the user's `ssh` trusts as well, which is
/// what appending to `~/.ssh/known_hosts` did (ADR-0046).
public struct HostKeyTrust: Sendable {
    public var readPaths: [String]
    public var recordPath: String
    public var confirmation: HostKeyConfirmation?

    public init(readPaths: [String], recordPath: String, confirmation: HostKeyConfirmation? = nil) {
        self.readPaths = readPaths
        self.recordPath = recordPath
        self.confirmation = confirmation
    }

    /// The user's `known_hosts` for reading and writing, and no question asked: what
    /// `dbcli` and the tests use, and what the provider did before ADR-0046.
    public static let openSSHDefault = HostKeyTrust(
        readPaths: [KnownHostsFile.defaultPath], recordPath: KnownHostsFile.defaultPath
    )

    /// Every trusted key for `host`, from every file.
    func trustedKeys(host: String, port: Int) -> Set<NIOSSHPublicKey> {
        Set(readPaths.flatMap { KnownHostsFile(path: $0).keys(forHost: host, port: port) })
    }

    /// Every revoked key for `host`, from every file.
    func revokedKeys(host: String, port: Int) -> Set<NIOSSHPublicKey> {
        Set(readPaths.flatMap { KnownHostsFile(path: $0).revokedKeys(forHost: host, port: port) })
    }
}
