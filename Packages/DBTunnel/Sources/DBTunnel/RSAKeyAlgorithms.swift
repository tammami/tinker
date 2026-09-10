import Crypto
import Foundation
import NIOCore
import NIOSSH
import _CryptoExtras

/// One way of signing with an RSA key over SSH: the algorithm's name and its hash.
///
/// RFC 8332 added `rsa-sha2-256` and `rsa-sha2-512` to the original `ssh-rsa`, which signs
/// with SHA-1. The key is the same in all three; only the name and the hash differ.
protocol RSASignatureAlgorithm {
    static var name: String { get }
    static func sign(_ data: some DataProtocol, with key: _RSA.Signing.PrivateKey) throws -> Data
    static func verify(_ signature: Data, of data: some DataProtocol, with key: _RSA.Signing.PublicKey) -> Bool
}

enum RSASHA512: RSASignatureAlgorithm {
    static let name = "rsa-sha2-512"

    static func sign(_ data: some DataProtocol, with key: _RSA.Signing.PrivateKey) throws -> Data {
        try key.signature(for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }

    static func verify(_ signature: Data, of data: some DataProtocol, with key: _RSA.Signing.PublicKey) -> Bool {
        key.isValidSignature(.init(rawRepresentation: signature), for: SHA512.hash(data: data), padding: .insecurePKCS1v1_5)
    }
}

enum RSASHA256: RSASignatureAlgorithm {
    static let name = "rsa-sha2-256"

    static func sign(_ data: some DataProtocol, with key: _RSA.Signing.PrivateKey) throws -> Data {
        try key.signature(for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }

    static func verify(_ signature: Data, of data: some DataProtocol, with key: _RSA.Signing.PublicKey) -> Bool {
        key.isValidSignature(.init(rawRepresentation: signature), for: SHA256.hash(data: data), padding: .insecurePKCS1v1_5)
    }
}

/// The original `ssh-rsa`, SHA-1. OpenSSH 8.8 and later refuse it, so it is offered last.
enum RSASHA1: RSASignatureAlgorithm {
    static let name = "ssh-rsa"

    static func sign(_ data: some DataProtocol, with key: _RSA.Signing.PrivateKey) throws -> Data {
        try key.signature(for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5).rawRepresentation
    }

    static func verify(_ signature: Data, of data: some DataProtocol, with key: _RSA.Signing.PublicKey) -> Bool {
        key.isValidSignature(.init(rawRepresentation: signature), for: Insecure.SHA1.hash(data: data), padding: .insecurePKCS1v1_5)
    }
}

// MARK: - swift-nio-ssh key types

/// An RSA private key that signs with one algorithm. swift-nio-ssh names the public-key
/// algorithm in the authentication request after the key's prefix, so one key file becomes
/// one of these per algorithm to offer.
struct RSASSHPrivateKey<Algorithm: RSASignatureAlgorithm>: NIOSSHPrivateKeyProtocol, Sendable {
    static var keyPrefix: String { Algorithm.name }

    let material: RSAKeyMaterial

    var publicKey: NIOSSHPublicKeyProtocol {
        RSASSHPublicKey<Algorithm>(
            key: material.key.publicKey, publicExponent: material.publicExponent, modulus: material.modulus
        )
    }

    func signature<D: DataProtocol>(for data: D) throws -> NIOSSHSignatureProtocol {
        RSASSHSignature<Algorithm>(rawRepresentation: try Algorithm.sign(data, with: material.key))
    }
}

/// The public half, in the wire form `string "ssh-rsa", mpint e, mpint n` from RFC 4253 —
/// with the algorithm's own name in place of `ssh-rsa`, which is where swift-nio-ssh reads
/// the name from (see ADR-0039).
struct RSASSHPublicKey<Algorithm: RSASignatureAlgorithm>: NIOSSHPublicKeyProtocol, Sendable {
    static var publicKeyPrefix: String { Algorithm.name }

    let key: _RSA.Signing.PublicKey
    let publicExponent: Data
    let modulus: Data

    var rawRepresentation: Data {
        var buffer = ByteBufferAllocator().buffer(capacity: publicExponent.count + modulus.count + 8)
        _ = write(to: &buffer)
        return Data(buffer.readableBytesView)
    }

    func isValidSignature<D: DataProtocol>(_ signature: NIOSSHSignatureProtocol, for data: D) -> Bool {
        guard let signature = signature as? RSASSHSignature<Algorithm> else { return false }
        return Algorithm.verify(signature.rawRepresentation, of: data, with: key)
    }

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHBlob(publicExponent) + buffer.writeSSHBlob(modulus)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let publicExponent = buffer.readSSHBlob(), let modulus = buffer.readSSHBlob() else {
            throw RSAWireError.truncatedPublicKey
        }
        return Self(
            key: try _RSA.Signing.PublicKey(n: modulus, e: publicExponent),
            publicExponent: publicExponent, modulus: modulus
        )
    }
}

/// A signature blob: `string <algorithm name>, string <signature bytes>` on the wire; the
/// name is written by swift-nio-ssh from `signaturePrefix`.
struct RSASSHSignature<Algorithm: RSASignatureAlgorithm>: NIOSSHSignatureProtocol, Sendable {
    static var signaturePrefix: String { Algorithm.name }

    let rawRepresentation: Data

    func write(to buffer: inout ByteBuffer) -> Int {
        buffer.writeSSHBlob(rawRepresentation)
    }

    static func read(from buffer: inout ByteBuffer) throws -> Self {
        guard let bytes = buffer.readSSHBlob() else { throw RSAWireError.truncatedSignature }
        return Self(rawRepresentation: bytes)
    }
}

enum RSAWireError: Error {
    case truncatedPublicKey
    case truncatedSignature
}

extension ByteBuffer {
    /// Writes an SSH `string`: a big-endian `uint32` length, then the bytes.
    fileprivate mutating func writeSSHBlob(_ bytes: Data) -> Int {
        writeInteger(UInt32(bytes.count)) + writeBytes(bytes)
    }

    /// Reads an SSH `string`, or returns nil and leaves the buffer alone when it is short.
    fileprivate mutating func readSSHBlob() -> Data? {
        guard let length = getInteger(at: readerIndex, as: UInt32.self),
            let bytes = getBytes(at: readerIndex + 4, length: Int(length))
        else { return nil }
        moveReaderIndex(forwardBy: 4 + Int(length))
        return Data(bytes)
    }
}
