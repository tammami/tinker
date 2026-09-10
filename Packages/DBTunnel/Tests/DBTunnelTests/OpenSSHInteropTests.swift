import DBCore
import DBTestKit
import Foundation
import Logging
import XCTest

@testable import DBTunnel

/// Interoperability with the OpenSSH `sshd` the machine ships.
///
/// ADR-0014 hosts an SSH server inside the test process because enabling Remote Login
/// needs administrator rights. That server accepts whatever the client offers, so it
/// cannot show what a *real* server refuses — and since OpenSSH 8.8 a real server refuses
/// `ssh-rsa`, the SHA-1 signature, for public-key authentication. These tests start
/// `/usr/sbin/sshd` unprivileged on a free port, which needs no administrator rights and
/// no change to the machine, and log in as the current user.
///
/// They skip when `sshd` is missing or refuses to start.
final class OpenSSHInteropTests: XCTestCase {
    var daemon: OpenSSHDaemon?

    var logger: Logger {
        var logger = Logger(label: "test.tunnel.openssh")
        logger.logLevel = .critical
        return logger
    }

    override func tearDown() async throws {
        await daemon?.stop()
        daemon = nil
    }

    /// Opens a tunnel to `echo` through `daemon`; a failure carries sshd's own log, which
    /// says why the server refused.
    func openTunnel(
        through daemon: OpenSSHDaemon, to echo: EchoServer, config: SSHConfig? = nil, secrets: any SecretStore = EphemeralSecretStore()
    ) async throws -> any Tunnel {
        do {
            return try await SSHTunnelProvider().openTunnel(
                config ?? self.config(for: daemon), to: "127.0.0.1", port: echo.port, secrets: secrets, logger: logger
            )
        } catch {
            throw TestError("\(error)\n--- sshd log ---\n\(daemon.logTail())")
        }
    }

    func config(for daemon: OpenSSHDaemon) -> SSHConfig {
        SSHConfig(
            host: "127.0.0.1", port: daemon.port, user: daemon.user,
            auth: .privateKey(path: daemon.clientKeyPath, passphrase: nil),
            knownHostsPolicy: .ignore
        )
    }

    /// A default OpenSSH server, which since 8.8 accepts `rsa-sha2-256`/`rsa-sha2-512`
    /// but not `ssh-rsa`. An RSA key file must still authenticate.
    func testRSAKeyAuthenticatesAgainstADefaultOpenSSHServer() async throws {
        let daemon = try await OpenSSHDaemon.start(keyType: "rsa")
        self.daemon = daemon
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }

        let tunnel = try await openTunnel(through: daemon, to: echo)
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "rsa")
        XCTAssertEqual(echoed, "rsa")
    }

    /// A server old enough to accept only `ssh-rsa` must still work: the client falls
    /// back through the algorithms it can sign with.
    func testRSAKeyAuthenticatesAgainstAnSSHRSAOnlyServer() async throws {
        let daemon = try await OpenSSHDaemon.start(
            keyType: "rsa", extraConfig: ["PubkeyAcceptedAlgorithms ssh-rsa"]
        )
        self.daemon = daemon
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }

        let tunnel = try await openTunnel(through: daemon, to: echo)
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "legacy")
        XCTAssertEqual(echoed, "legacy")
    }

    func testEd25519KeyAuthenticatesAgainstOpenSSH() async throws {
        let daemon = try await OpenSSHDaemon.start(keyType: "ed25519")
        self.daemon = daemon
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }

        let tunnel = try await openTunnel(through: daemon, to: echo)
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "ed25519")
        XCTAssertEqual(echoed, "ed25519")
    }

    /// A passphrase-protected RSA key is what `ssh-keygen` writes when the user answers
    /// its prompt, and it is encrypted with bcrypt — a different code path from a bare key.
    func testEncryptedRSAKeyAuthenticatesAgainstOpenSSH() async throws {
        let daemon = try await OpenSSHDaemon.start(keyType: "rsa", passphrase: "s3cret")
        self.daemon = daemon
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }

        let reference = SecretRef(account: "test.ssh.passphrase")
        let secrets = EphemeralSecretStore()
        try await secrets.setSecret("s3cret", for: reference)
        var config = config(for: daemon)
        config.auth = .privateKey(path: daemon.clientKeyPath, passphrase: reference)

        let tunnel = try await openTunnel(through: daemon, to: echo, config: config, secrets: secrets)
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "encrypted")
        XCTAssertEqual(echoed, "encrypted")
    }
}

extension OpenSSHInteropTests {
    /// ECDSA keys were refused outright before ADR-0039; NIOSSH signs them natively.
    func testECDSAKeyAuthenticatesAgainstOpenSSH() async throws {
        let daemon = try await OpenSSHDaemon.start(keyType: "ecdsa", keygenArguments: ["-b", "384"])
        self.daemon = daemon
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let tunnel = try await openTunnel(through: daemon, to: echo)
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "ecdsa")
        XCTAssertEqual(echoed, "ecdsa")
    }

    /// `ssh-keygen -m PEM` writes the `BEGIN RSA PRIVATE KEY` format every `id_rsa` from
    /// before OpenSSH 7.8 (2018) is in.
    func testPEMRSAKeyAuthenticatesAgainstOpenSSH() async throws {
        let daemon = try await OpenSSHDaemon.start(keyType: "rsa", keygenArguments: ["-m", "PEM"])
        self.daemon = daemon
        XCTAssertTrue(try String(contentsOfFile: daemon.clientKeyPath, encoding: .utf8).contains("BEGIN RSA PRIVATE KEY"))
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }
        let tunnel = try await openTunnel(through: daemon, to: echo)
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "pem")
        XCTAssertEqual(echoed, "pem")
    }

    /// A passphrase on a PEM key means OpenSSL's legacy `DEK-Info` encryption (MD5, AES-CBC).
    func testEncryptedPEMRSAKeyAuthenticatesAgainstOpenSSH() async throws {
        let daemon = try await OpenSSHDaemon.start(keyType: "rsa", passphrase: "pem-pass", keygenArguments: ["-m", "PEM"])
        self.daemon = daemon
        XCTAssertTrue(try String(contentsOfFile: daemon.clientKeyPath, encoding: .utf8).contains("DEK-Info"))
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }

        let reference = SecretRef(account: "test.ssh.passphrase")
        let secrets = EphemeralSecretStore()
        try await secrets.setSecret("pem-pass", for: reference)
        var config = config(for: daemon)
        config.auth = .privateKey(path: daemon.clientKeyPath, passphrase: reference)
        let tunnel = try await openTunnel(through: daemon, to: echo, config: config, secrets: secrets)
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "pem-encrypted")
        XCTAssertEqual(echoed, "pem-encrypted")
    }

    /// `ssh-keygen -Z` picks the cipher; CBC is the other mode OpenSSH keys use.
    func testAESCBCEncryptedKeyAuthenticatesAgainstOpenSSH() async throws {
        let daemon = try await OpenSSHDaemon.start(
            keyType: "ed25519", passphrase: "cbc-pass", keygenArguments: ["-Z", "aes256-cbc"]
        )
        self.daemon = daemon
        let echo = try await EchoServer.start()
        defer { Task { await echo.stop() } }

        let reference = SecretRef(account: "test.ssh.passphrase")
        let secrets = EphemeralSecretStore()
        try await secrets.setSecret("cbc-pass", for: reference)
        var config = config(for: daemon)
        config.auth = .privateKey(path: daemon.clientKeyPath, passphrase: reference)
        let tunnel = try await openTunnel(through: daemon, to: echo, config: config, secrets: secrets)
        defer { Task { await tunnel.close() } }
        let echoed = try await TCPProbe.roundTrip(host: "127.0.0.1", port: tunnel.localPort, sending: "cbc")
        XCTAssertEqual(echoed, "cbc")
    }

    /// The refusal names every algorithm that was tried, so the user can tell a wrong key
    /// from a server that only takes SHA-1.
    func testAKeyTheServerDoesNotKnowIsRefusedNamingEveryAlgorithm() async throws {
        let daemon = try await OpenSSHDaemon.start(keyType: "ed25519")
        self.daemon = daemon
        let stranger = try SSHKeyFixture.generate(type: "rsa")
        defer { stranger.remove() }
        var config = config(for: daemon)
        config.auth = .privateKey(path: stranger.path, passphrase: nil)
        do {
            _ = try await SSHTunnelProvider().openTunnel(
                config, to: "127.0.0.1", port: 1, secrets: EphemeralSecretStore(), logger: logger
            )
            XCTFail("expected the stranger's key to be refused")
        } catch let DBError.tunnelFailed(stage, message) {
            XCTAssertEqual(stage, .sshAuth)
            XCTAssertTrue(message.contains("rsa-sha2-512, rsa-sha2-256, ssh-rsa"), message)
        }
    }
}

/// The machine's own `sshd`, started unprivileged in a directory of its own.
///
/// It listens on loopback, knows one authorized key, and lets the current user in — the
/// only user an unprivileged `sshd` can admit.
final class OpenSSHDaemon {
    let port: Int
    let user: String
    let clientKeyPath: String
    private let directory: URL
    private let process: Process
    private let log: URL

    private init(port: Int, user: String, clientKeyPath: String, directory: URL, process: Process, log: URL) {
        self.port = port
        self.user = user
        self.clientKeyPath = clientKeyPath
        self.directory = directory
        self.process = process
        self.log = log
    }

    static func start(
        keyType: String,
        passphrase: String = "",
        keygenArguments: [String] = [],
        extraConfig: [String] = []
    ) async throws -> OpenSSHDaemon {
        let executable = "/usr/sbin/sshd"
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw XCTSkip("\(executable) is not on this machine")
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tinker-sshd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let hostKey = directory.appendingPathComponent("host_key").path
        let clientKey = directory.appendingPathComponent("client_key").path
        try keygen(type: "ed25519", path: hostKey, passphrase: "", arguments: [])
        try keygen(type: keyType, path: clientKey, passphrase: passphrase, arguments: keygenArguments)
        let publicKey = try String(contentsOfFile: clientKey + ".pub", encoding: .utf8)
        let authorizedKeys = directory.appendingPathComponent("authorized_keys")
        try publicKey.write(to: authorizedKeys, atomically: true, encoding: .utf8)

        let port = try TestSSHServer.freePort()
        let log = directory.appendingPathComponent("sshd.log")
        let configuration =
            ([
                "Port \(port)",
                "ListenAddress 127.0.0.1",
                "HostKey \(hostKey)",
                "AuthorizedKeysFile \(authorizedKeys.path)",
                "PidFile \(directory.appendingPathComponent("sshd.pid").path)",
                // The temporary directory is not owned the way sshd wants a home to be.
                "StrictModes no",
                "UsePAM no",
                "PasswordAuthentication no",
                "KbdInteractiveAuthentication no",
                "AllowTcpForwarding yes",
                "LogLevel VERBOSE",
            ] + extraConfig).joined(separator: "\n") + "\n"
        let configurationPath = directory.appendingPathComponent("sshd_config")
        try configuration.write(to: configurationPath, atomically: true, encoding: .utf8)

        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-f", configurationPath.path, "-D", "-e"]
        process.standardOutput = handle
        process.standardError = handle
        do {
            try process.run()
        } catch {
            throw XCTSkip("sshd did not start: \(error)")
        }

        let daemon = OpenSSHDaemon(
            port: port, user: NSUserName(), clientKeyPath: clientKey,
            directory: directory, process: process, log: log
        )
        do {
            try await daemon.waitUntilListening()
        } catch {
            await daemon.stop()
            throw error
        }
        return daemon
    }

    private func waitUntilListening() async throws {
        for _ in 0 ..< 100 {
            if Self.canConnect(port: port) { return }
            if !process.isRunning {
                let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                throw XCTSkip("sshd exited: \(text)")
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw XCTSkip("sshd never started listening")
    }

    /// Whether a TCP connection to loopback on `port` is accepted.
    private static func canConnect(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    /// The last lines sshd wrote, for a failure message.
    func logTail(lines: Int = 12) -> String {
        let text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).suffix(lines).joined(separator: "\n")
    }

    /// Terminates sshd and removes its directory. `Process.waitUntilExit` is not used: it
    /// spins a run loop the test's async context never services, and hangs.
    func stop() async {
        if process.isRunning { process.terminate() }
        for _ in 0 ..< 100 where process.isRunning {
            try? await Task.sleep(for: .milliseconds(20))
        }
        try? FileManager.default.removeItem(at: directory)
    }

    private static func keygen(type: String, path: String, passphrase: String, arguments extra: [String]) throws {
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
    }
}
