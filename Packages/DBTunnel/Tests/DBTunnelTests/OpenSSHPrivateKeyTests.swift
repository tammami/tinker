import Crypto
import Foundation
import NIOCore
import XCTest
import _CryptoExtras

@testable import DBTunnel

/// The key-file parser and the RSA signature algorithms, without a server.
///
/// Keys come from `ssh-keygen`, so every format tested is one OpenSSH actually writes.
final class OpenSSHPrivateKeyTests: XCTestCase {
    // MARK: - Formats

    func testEveryKeyTypeOpenSSHWritesIsRead() throws {
        let cases: [(type: String, arguments: [String], expected: String)] = [
            ("rsa", [], "rsa"),
            ("ed25519", [], "ed25519"),
            ("ecdsa", ["-b", "256"], "ecdsaP256"),
            ("ecdsa", ["-b", "384"], "ecdsaP384"),
            ("ecdsa", ["-b", "521"], "ecdsaP521"),
            ("rsa", ["-m", "PEM"], "rsa"),
            ("ecdsa", ["-b", "256", "-m", "PEM"], "ecdsaP256"),
        ]
        for testCase in cases {
            let key = try SSHKeyFixture.generate(type: testCase.type, arguments: testCase.arguments)
            defer { key.remove() }
            let parsed = try OpenSSHPrivateKey.parse(key.contents, passphrase: nil)
            XCTAssertEqual(parsed.caseName, testCase.expected, "\(testCase.type) \(testCase.arguments)")
        }
    }

    func testEncryptedKeysDecryptWithTheirPassphrase() throws {
        let cases: [(type: String, arguments: [String])] = [
            ("rsa", []),  // aes256-ctr, the default
            ("ed25519", ["-Z", "aes128-ctr"]),
            ("ed25519", ["-Z", "aes256-cbc"]),
            ("rsa", ["-m", "PEM"]),  // OpenSSL's DEK-Info scheme
        ]
        for testCase in cases {
            let key = try SSHKeyFixture.generate(type: testCase.type, passphrase: "s3cret", arguments: testCase.arguments)
            defer { key.remove() }
            XCTAssertNoThrow(
                try OpenSSHPrivateKey.parse(key.contents, passphrase: Data("s3cret".utf8)),
                "\(testCase.type) \(testCase.arguments)")
        }
    }

    /// The public numbers read back from the file match what `ssh-keygen` published.
    func testRSAPublicNumbersMatchThePublicKeyFile() throws {
        let key = try SSHKeyFixture.generate(type: "rsa")
        defer { key.remove() }
        guard case let .rsa(material) = try OpenSSHPrivateKey.parse(key.contents, passphrase: nil) else {
            return XCTFail("expected an RSA key")
        }
        // The .pub line is `ssh-rsa <base64 blob> comment`; the blob is string "ssh-rsa",
        // mpint e, mpint n.
        let blob = try XCTUnwrap(Data(base64Encoded: String(key.publicKeyLine.split(separator: " ")[1])))
        var reader = ByteBufferAllocator().buffer(bytes: blob)
        XCTAssertEqual(reader.readSSHStringForTest(), Data("ssh-rsa".utf8))
        XCTAssertEqual(reader.readSSHStringForTest(), material.publicExponent)
        XCTAssertEqual(reader.readSSHStringForTest(), material.modulus)
        XCTAssertEqual(reader.readableBytes, 0)
    }

    // MARK: - Errors

    func testAWrongPassphraseIsToldApartFromADamagedFile() throws {
        for arguments in [[], ["-m", "PEM"], ["-Z", "aes256-cbc"]] {
            let key = try SSHKeyFixture.generate(type: "rsa", passphrase: "right", arguments: arguments)
            defer { key.remove() }
            XCTAssertThrowsError(try OpenSSHPrivateKey.parse(key.contents, passphrase: Data("wrong".utf8))) { error in
                XCTAssertEqual(error as? OpenSSHKeyError, .wrongPassphrase, "\(arguments)")
            }
            XCTAssertThrowsError(try OpenSSHPrivateKey.parse(key.contents, passphrase: nil)) { error in
                XCTAssertEqual(error as? OpenSSHKeyError, .passphraseRequired, "\(arguments)")
            }
            XCTAssertThrowsError(try OpenSSHPrivateKey.parse(key.contents, passphrase: Data())) { error in
                XCTAssertEqual(error as? OpenSSHKeyError, .passphraseRequired, "\(arguments)")
            }
        }
    }

    func testAnUnsupportedCipherIsNamed() throws {
        let key = try SSHKeyFixture.generate(type: "ed25519", passphrase: "x", arguments: ["-Z", "chacha20-poly1305@openssh.com"])
        defer { key.remove() }
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse(key.contents, passphrase: Data("x".utf8))) { error in
            XCTAssertEqual(error as? OpenSSHKeyError, .unsupportedCipher("chacha20-poly1305@openssh.com"))
            let message = (error as? OpenSSHKeyError)?.message(path: "/k") ?? ""
            XCTAssertTrue(message.contains("ssh-keygen -p -f /k"), message)
        }
    }

    func testTextThatIsNotAKeyIsRejected() {
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse("not a key", passphrase: nil)) { error in
            XCTAssertEqual(error as? OpenSSHKeyError, .unrecognisedFormat)
        }
        let truncated = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n-----END OPENSSH PRIVATE KEY-----\n"
        XCTAssertThrowsError(try OpenSSHPrivateKey.parse(truncated, passphrase: nil)) { error in
            guard case .malformed? = error as? OpenSSHKeyError else { return XCTFail("expected .malformed, got \(error)") }
        }
    }

    func testMessagesCarryThePathAndAHint() {
        XCTAssertTrue(OpenSSHKeyError.passphraseRequired.message(path: "/id").hasPrefix("/id is encrypted"))
        XCTAssertTrue(OpenSSHKeyError.unsupportedKeyType("sk-ssh-ed25519@openssh.com").message(path: "/id").contains("hardware-token"))
        XCTAssertTrue(OpenSSHKeyError.unsupportedEncryption("PKCS#8").message(path: "/id").contains("ssh-keygen -p"))
    }

    // MARK: - mpint

    func testMpintDropsLeadingZerosAndKeepsTheSignBitClear() {
        XCTAssertEqual(RSAKeyMaterial.mpint(Data([0x00, 0x00, 0x01, 0x02])), Data([0x01, 0x02]))
        XCTAssertEqual(RSAKeyMaterial.mpint(Data([0x80, 0x01])), Data([0x00, 0x80, 0x01]))
        XCTAssertEqual(RSAKeyMaterial.mpint(Data([0x00, 0x80])), Data([0x00, 0x80]))
        XCTAssertEqual(RSAKeyMaterial.mpint(Data([0x00])), Data())
    }

    // MARK: - Algorithms

    func testRSACandidatesAreOfferedStrongestFirst() throws {
        let key = try SSHKeyFixture.generate(type: "rsa")
        defer { key.remove() }
        let candidates = KeyFileAuthentication.candidates(for: try OpenSSHPrivateKey.parse(key.contents, passphrase: nil))
        XCTAssertEqual(candidates.map(\.algorithm), ["rsa-sha2-512", "rsa-sha2-256", "ssh-rsa"])

        let ed25519 = try SSHKeyFixture.generate(type: "ed25519")
        defer { ed25519.remove() }
        XCTAssertEqual(
            KeyFileAuthentication.candidates(for: try OpenSSHPrivateKey.parse(ed25519.contents, passphrase: nil)).map(\.algorithm),
            ["ssh-ed25519"])
    }

    /// Each algorithm's signature verifies under its own name and under no other, and the
    /// public key blob round-trips through the wire format.
    func testRSASignaturesVerifyOnlyUnderTheirOwnAlgorithm() throws {
        let key = try SSHKeyFixture.generate(type: "rsa")
        defer { key.remove() }
        guard case let .rsa(material) = try OpenSSHPrivateKey.parse(key.contents, passphrase: nil) else {
            return XCTFail("expected an RSA key")
        }
        let message = Array("the exchange hash".utf8)

        let sha512Key = RSASSHPrivateKey<RSASHA512>(material: material)
        let sha256Key = RSASSHPrivateKey<RSASHA256>(material: material)
        let sha1Key = RSASSHPrivateKey<RSASHA1>(material: material)
        let sha512Signature = try sha512Key.signature(for: message)
        let sha256Signature = try sha256Key.signature(for: message)

        XCTAssertEqual(type(of: sha512Signature).signaturePrefix, "rsa-sha2-512")
        XCTAssertTrue(sha512Key.publicKey.isValidSignature(sha512Signature, for: message))
        XCTAssertFalse(sha512Key.publicKey.isValidSignature(sha256Signature, for: message))
        XCTAssertTrue(sha256Key.publicKey.isValidSignature(sha256Signature, for: message))
        XCTAssertFalse(sha256Key.publicKey.isValidSignature(sha256Signature, for: Array("another".utf8)))
        XCTAssertTrue(sha1Key.publicKey.isValidSignature(try sha1Key.signature(for: message), for: message))

        var buffer = ByteBufferAllocator().buffer(capacity: 600)
        _ = sha512Key.publicKey.write(to: &buffer)
        let readBack = try RSASSHPublicKey<RSASHA512>.read(from: &buffer)
        XCTAssertEqual(readBack.rawRepresentation, sha512Key.publicKey.rawRepresentation)
        XCTAssertTrue(readBack.isValidSignature(sha512Signature, for: message))
        XCTAssertEqual(buffer.readableBytes, 0)
    }
}

extension OpenSSHPrivateKey {
    fileprivate var caseName: String {
        switch self {
        case .rsa: return "rsa"
        case .ed25519: return "ed25519"
        case .ecdsaP256: return "ecdsaP256"
        case .ecdsaP384: return "ecdsaP384"
        case .ecdsaP521: return "ecdsaP521"
        }
    }
}

extension ByteBuffer {
    fileprivate mutating func readSSHStringForTest() -> Data? {
        guard let length = readInteger(as: UInt32.self), let bytes = readBytes(length: Int(length)) else { return nil }
        return Data(bytes)
    }
}
