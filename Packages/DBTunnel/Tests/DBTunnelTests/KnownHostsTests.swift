import Crypto
import DBCore
import Foundation
import NIOCore
import NIOSSH
import XCTest

@testable import DBTunnel

final class KnownHostsTests: XCTestCase {
    var directory: URL!
    var path: String!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tinker-known-hosts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("known_hosts").path
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A real ed25519 host key, so parsing is checked against something NIOSSH accepts.
    func makeKeyLine(host: String) throws -> (line: String, key: NIOSSHPublicKey) {
        let privateKey = Curve25519.Signing.PrivateKey()
        let key = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey
        var buffer = ByteBufferAllocator().buffer(capacity: 128)
        key.write(to: &buffer)
        let blob = Data(buffer.readBytes(length: buffer.readableBytes) ?? [])
        return ("\(host) ssh-ed25519 \(blob.base64EncodedString())", key)
    }

    func testParsesPlainEntries() throws {
        let (line, key) = try makeKeyLine(host: "db.example")
        try line.write(toFile: path, atomically: true, encoding: .utf8)
        let file = KnownHostsFile(path: path)
        XCTAssertEqual(file.entries().count, 1)
        XCTAssertEqual(file.keys(forHost: "db.example", port: 22), [key])
        XCTAssertTrue(file.keys(forHost: "other.example", port: 22).isEmpty)
    }

    func testSkipsCommentsAndBlankLines() throws {
        let (line, _) = try makeKeyLine(host: "db.example")
        let contents = "# a comment\n\n\(line)\n   \n"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(KnownHostsFile(path: path).entries().count, 1)
    }

    func testHandlesMultipleHostsPerLine() throws {
        let (line, key) = try makeKeyLine(host: "a.example,b.example")
        let file = KnownHostsFile(path: path)
        try line.write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(file.keys(forHost: "b.example", port: 22), [key])
    }

    /// A certificate authority signs host certificates; it is not itself a host key, so
    /// it must never be offered as one. A revoked key must never be trusted, and must be
    /// reported as revoked so the server presenting it is refused.
    func testMarkersAreHonoured() throws {
        let (authority, _) = try makeKeyLine(host: "db.example")
        let (revokedLine, revokedKey) = try makeKeyLine(host: "db.example")
        let (trustedLine, trustedKey) = try makeKeyLine(host: "db.example")
        let contents = "@cert-authority \(authority)\n@revoked \(revokedLine)\n\(trustedLine)\n"
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
        let file = KnownHostsFile(path: path)
        XCTAssertEqual(file.entries().count, 3)
        XCTAssertEqual(file.keys(forHost: "db.example", port: 22), [trustedKey])
        XCTAssertEqual(file.revokedKeys(forHost: "db.example", port: 22), [revokedKey])
        XCTAssertTrue(file.knows(host: "db.example", port: 22))
    }

    func testNonDefaultPortsUseTheBracketForm() throws {
        let (line, key) = try makeKeyLine(host: "[db.example]:2222")
        try line.write(toFile: path, atomically: true, encoding: .utf8)
        let file = KnownHostsFile(path: path)
        XCTAssertEqual(file.keys(forHost: "db.example", port: 2_222), [key])
        XCTAssertTrue(file.keys(forHost: "db.example", port: 22).isEmpty)
    }

    /// OpenSSH's `HashKnownHosts yes` stores an HMAC-SHA1 of the host name.
    func testMatchesHashedHostNames() throws {
        let host = "db.example"
        let salt = Data((0 ..< 20).map { _ in UInt8.random(in: 0 ... 255) })
        let digest = Crypto.HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(host.utf8), using: SymmetricKey(data: salt)
        )
        let pattern = "|1|\(salt.base64EncodedString())|\(Data(digest).base64EncodedString())"
        let (line, key) = try makeKeyLine(host: pattern)
        try line.write(toFile: path, atomically: true, encoding: .utf8)

        let file = KnownHostsFile(path: path)
        XCTAssertTrue(file.entries()[0].isHashed)
        XCTAssertEqual(file.keys(forHost: host, port: 22), [key])
        XCTAssertTrue(file.keys(forHost: "other.example", port: 22).isEmpty)
    }

    func testAppendRoundTrips() throws {
        let privateKey = Curve25519.Signing.PrivateKey()
        let key = NIOSSHPrivateKey(ed25519Key: privateKey).publicKey
        let file = KnownHostsFile(path: path)
        XCTAssertFalse(file.knows(host: "new.example", port: 22))

        try file.append(host: "new.example", port: 2_222, key: key)
        XCTAssertTrue(file.knows(host: "new.example", port: 2_222))
        XCTAssertEqual(file.keys(forHost: "new.example", port: 2_222), [key])

        // Appending a second host keeps the first.
        try file.append(host: "another.example", port: 22, key: key)
        XCTAssertEqual(file.entries().count, 2)
    }

    func testMissingFileIsNotAnError() {
        let file = KnownHostsFile(path: directory.appendingPathComponent("nope").path)
        XCTAssertTrue(file.entries().isEmpty)
        XCTAssertFalse(file.knows(host: "x", port: 22))
    }

    func testMalformedLinesAreSkippedRatherThanFailing() throws {
        let (line, _) = try makeKeyLine(host: "db.example")
        try "garbage\nalso garbage here\n\(line)".write(toFile: path, atomically: true, encoding: .utf8)
        XCTAssertEqual(KnownHostsFile(path: path).keys(forHost: "db.example", port: 22).count, 1)
    }

    // MARK: - Policy

    func testStrictPolicyRefusesAnUnknownHost() {
        let config = SSHConfig(
            host: "never.seen.example", user: "me", auth: .agent, knownHostsPolicy: .strict
        )
        XCTAssertThrowsError(try SSHTunnelProvider.hostKeyValidator(for: config)) { error in
            guard case let DBError.tunnelFailed(stage, message)? = error as? DBError else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertEqual(stage, .ssh)
            XCTAssertTrue(message.contains("never.seen.example"), message)
        }
    }

    func testIgnorePolicyAcceptsAnything() throws {
        let config = SSHConfig(host: "anything", user: "me", auth: .agent, knownHostsPolicy: .ignore)
        XCTAssertNoThrow(try SSHTunnelProvider.hostKeyValidator(for: config))
    }

    func testAcceptNewPolicyDoesNotRefuseAnUnknownHost() throws {
        let config = SSHConfig(host: "never.seen.example", user: "me", auth: .agent, knownHostsPolicy: .acceptNew)
        XCTAssertNoThrow(try SSHTunnelProvider.hostKeyValidator(for: config))
    }
}

final class SSHAuthenticationTests: XCTestCase {
    func testAgentAuthenticationSaysWhatToDoInstead() async {
        let config = SSHConfig(host: "h", user: "me", auth: .agent)
        do {
            _ = try await SSHTunnelProvider.authenticationAttempts(for: config, secrets: EphemeralSecretStore())
            XCTFail("expected agent authentication to be refused")
        } catch let error as DBError {
            guard case let .tunnelFailed(stage, message) = error else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertEqual(stage, .sshAuth)
            XCTAssertTrue(message.contains("id_ed25519"), "the message should name the alternative: \(message)")
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMissingPasswordIsReported() async {
        let reference = SecretRef(account: "absent")
        let config = SSHConfig(host: "h", user: "me", auth: .password(reference))
        do {
            _ = try await SSHTunnelProvider.authenticationAttempts(for: config, secrets: EphemeralSecretStore())
            XCTFail("expected the missing password to be reported")
        } catch let error as DBError {
            guard case let .tunnelFailed(stage, _) = error else { return XCTFail("expected .tunnelFailed") }
            XCTAssertEqual(stage, .sshAuth)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func testMissingKeyFileIsReportedWithItsPath() async {
        let config = SSHConfig(host: "h", user: "me", auth: .privateKey(path: "/nope/id_ed25519", passphrase: nil))
        do {
            _ = try await SSHTunnelProvider.authenticationAttempts(for: config, secrets: EphemeralSecretStore())
            XCTFail("expected the missing key to be reported")
        } catch let error as DBError {
            guard case let .tunnelFailed(_, message) = error else { return XCTFail("expected .tunnelFailed") }
            XCTAssertTrue(message.contains("/nope/id_ed25519"), message)
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    /// Loads keys that OpenSSH itself wrote, which is the format users actually have.
    func testKeysWrittenByOpenSSHLoad() throws {
        for (type, passphrase) in [("ed25519", ""), ("ed25519", "s3cret"), ("rsa", "")] {
            let key = try SSHKeyFixture.generate(type: type, passphrase: passphrase)
            defer { key.remove() }
            XCTAssertNoThrow(
                try SSHTunnelProvider.privateKeyAuthentication(
                    username: "me", contents: key.contents,
                    passphrase: passphrase.isEmpty ? nil : Data(passphrase.utf8),
                    path: key.path
                ),
                "\(type) key with\(passphrase.isEmpty ? "out" : "") a passphrase"
            )
        }
    }

    func testAWrongPassphraseIsReported() throws {
        let key = try SSHKeyFixture.generate(type: "ed25519", passphrase: "right")
        defer { key.remove() }
        XCTAssertThrowsError(
            try SSHTunnelProvider.privateKeyAuthentication(
                username: "me", contents: key.contents, passphrase: Data("wrong".utf8), path: key.path
            )
        ) { error in
            guard case let DBError.tunnelFailed(_, message)? = error as? DBError else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("passphrase"), message)
        }
    }

    func testGarbageKeyFileIsRejectedClearly() {
        XCTAssertThrowsError(
            try SSHTunnelProvider.privateKeyAuthentication(
                username: "me", contents: "not a key", passphrase: nil, path: "/tmp/bogus"
            )
        ) { error in
            guard case let DBError.tunnelFailed(stage, message)? = error as? DBError else {
                return XCTFail("expected .tunnelFailed, got \(error)")
            }
            XCTAssertEqual(stage, .sshAuth)
            XCTAssertTrue(message.contains("/tmp/bogus"), message)
        }
    }
}

/// Generates real OpenSSH key pairs with `ssh-keygen`, which ships with macOS.
enum SSHKeyFixture {
    struct Key {
        let path: String
        let contents: String
        let publicKeyLine: String

        func remove() {
            try? FileManager.default.removeItem(atPath: path)
            try? FileManager.default.removeItem(atPath: path + ".pub")
        }
    }

    static func generate(type: String, passphrase: String = "", arguments extra: [String] = []) throws -> Key {
        let path = NSTemporaryDirectory() + "tinker-key-\(UUID().uuidString)"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        var arguments = ["-t", type, "-f", path, "-N", passphrase, "-C", "tinker-test", "-q"]
        if type == "rsa" { arguments += ["-b", "2048"] }
        process.arguments = arguments + extra
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("ssh-keygen failed with status \(process.terminationStatus)")
        }
        return Key(
            path: path,
            contents: try String(contentsOfFile: path, encoding: .utf8),
            publicKeyLine: try String(contentsOfFile: path + ".pub", encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
