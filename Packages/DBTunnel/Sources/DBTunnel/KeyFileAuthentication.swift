import Foundation
import NIOCore
import NIOSSH
import os

/// The ways a key file's key can be offered to a server, strongest first.
///
/// An RSA key can sign three ways — `rsa-sha2-512`, `rsa-sha2-256` and `ssh-rsa` (SHA-1) —
/// and a server takes some subset: OpenSSH 8.8 and later refuse `ssh-rsa`, servers older
/// than 7.2 know nothing else. swift-nio-ssh names one algorithm per key, so each way is a
/// key of its own. The other key types have one algorithm each.
enum KeyFileAuthentication {
    static func candidates(for key: OpenSSHPrivateKey) -> [KeyCandidate] {
        switch key {
        case let .rsa(material):
            return [
                KeyCandidate(
                    algorithm: RSASHA512.name,
                    key: NIOSSHPrivateKey(custom: RSASSHPrivateKey<RSASHA512>(material: material))),
                KeyCandidate(
                    algorithm: RSASHA256.name,
                    key: NIOSSHPrivateKey(custom: RSASSHPrivateKey<RSASHA256>(material: material))),
                KeyCandidate(
                    algorithm: RSASHA1.name,
                    key: NIOSSHPrivateKey(custom: RSASSHPrivateKey<RSASHA1>(material: material))),
            ]
        case let .ed25519(key):
            return [KeyCandidate(algorithm: "ssh-ed25519", key: NIOSSHPrivateKey(ed25519Key: key))]
        case let .ecdsaP256(key):
            return [KeyCandidate(algorithm: "ecdsa-sha2-nistp256", key: NIOSSHPrivateKey(p256Key: key))]
        case let .ecdsaP384(key):
            return [KeyCandidate(algorithm: "ecdsa-sha2-nistp384", key: NIOSSHPrivateKey(p384Key: key))]
        case let .ecdsaP521(key):
            return [KeyCandidate(algorithm: "ecdsa-sha2-nistp521", key: NIOSSHPrivateKey(p521Key: key))]
        }
    }
}

/// A key ready to offer, and the name it is offered under.
///
/// `NIOSSHPrivateKey` predates Sendable and holds only immutable key material.
struct KeyCandidate: @unchecked Sendable {
    let algorithm: String
    let key: NIOSSHPrivateKey
}

/// Offers one key, once.
///
/// Citadel's `SSHAuthenticationMethod` gives a custom delegate a single turn and then
/// reports every option as failed, so a second algorithm cannot be offered on the same
/// connection; `SSHTunnelProvider.connectClient` opens a new one per candidate instead.
final class SingleKeyAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate, Sendable {
    private let username: String
    private let candidate: KeyCandidate
    private let offered = OSAllocatedUnfairLock(initialState: false)

    init(username: String, candidate: KeyCandidate) {
        self.username = username
        self.candidate = candidate
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.publicKey) else {
            nextChallengePromise.fail(KeyAuthenticationRefused.publicKeyNotAccepted)
            return
        }
        let alreadyOffered = offered.withLock { offered in
            defer { offered = true }
            return offered
        }
        guard !alreadyOffered else {
            nextChallengePromise.fail(KeyAuthenticationRefused.keyRefused(candidate.algorithm))
            return
        }
        // swift-nio-ssh asks on the connection's event loop, and the offer type predates
        // Sendable; `assumeIsolated` checks the loop rather than trusting it.
        nextChallengePromise.assumeIsolated().succeed(
            NIOSSHUserAuthenticationOffer(
                username: username, serviceName: "",
                offer: .privateKey(.init(privateKey: candidate.key))
            ))
    }
}

/// The server would not let the key in.
enum KeyAuthenticationRefused: Error, CustomStringConvertible {
    case publicKeyNotAccepted
    case keyRefused(String)

    var description: String {
        switch self {
        case .publicKeyNotAccepted:
            return "the server does not accept public-key authentication"
        case let .keyRefused(algorithm):
            return "the server refused the key as \(algorithm)"
        }
    }
}
