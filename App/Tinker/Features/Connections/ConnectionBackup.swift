import CommonCrypto
import CryptoKit
import DBCore
import Foundation
import UniformTypeIdentifiers

/// A `.think` file: every connection and every sidebar folder, with the passwords sealed
/// under a passphrase the person types.
///
/// The point is a second Mac. Everything the connection editor asks for travels — host,
/// port, user, database, TLS, SSH with its jump host, options, colour, the production and
/// read-only marks — so a restore leaves nothing to fill in.
///
/// What is readable and what is not: the connections themselves are plain JSON, so a
/// backup can be looked at, diffed and kept in version control. The secrets are one
/// AES-GCM box whose key is derived from the passphrase; without it they are noise, and
/// no part of the app can read them either. The Keychain remains the only place a secret
/// lives unsealed (SPEC §9).
struct ConnectionBackupFile: Codable, Sendable {
    /// What this file is. A file that does not say this is not ours, whatever it is named.
    static let formatName = "tinker.connections"
    /// The version this build writes. A file from a later version is refused rather than
    /// half-read.
    static let currentVersion = 1

    var format: String
    var version: Int
    var createdAt: Date
    /// The app that wrote it, for a person reading the file a year from now.
    var app: String
    var connections: [ConnectionConfig]
    var groups: [BackupGroup]
    var secrets: SealedSecrets

    /// The sidebar folder tree, which `StoredGroup` cannot carry itself.
    struct BackupGroup: Codable, Sendable, Hashable {
        var path: [String]
        var isExpanded: Bool
        var sortOrder: Int
    }

    /// The sealed passwords: the salt the key was derived with, and the AES-GCM box.
    struct SealedSecrets: Codable, Sendable {
        var kdf: String
        var rounds: Int
        var salt: Data
        /// Nonce, ciphertext and tag as one blob, the way `AES.GCM.SealedBox` combines them.
        var box: Data
    }

    /// One password on its way between Keychains, named by the reference the connection
    /// already carries so a restore puts it back exactly where that connection looks.
    struct StoredSecret: Codable, Sendable {
        var ref: SecretRef
        var value: String
    }
}

/// What can go wrong reading a backup, in words that say what to do about it.
enum ConnectionBackupError: LocalizedError, Equatable {
    case notABackup
    case tooNew(Int)
    case wrongPassphrase
    case emptyPassphrase
    case nothingToBackUp

    var errorDescription: String? {
        switch self {
        case .notABackup:
            "This is not a Tinker connections backup."
        case let .tooNew(version):
            "This backup was written by a newer version of Tinker (format \(version)). Update Tinker and try again."
        case .wrongPassphrase:
            "That passphrase does not open this backup."
        case .emptyPassphrase:
            "A backup needs a passphrase: it is what its passwords are sealed with."
        case .nothingToBackUp:
            "There are no connections to back up yet."
        }
    }
}

/// Writes and reads `.think` files.
///
/// An actor because deriving a key from a passphrase is deliberately slow — 600,000 PBKDF2
/// rounds, around half a second — and that must not happen on the main actor.
actor ConnectionBackupCodec {
    /// The file type, so the save and open panels offer it by name. Declared in
    /// `Info.plist`; the extension lookup finds that declaration, and falls back to plain
    /// data on a system that has not seen it yet.
    @MainActor static var contentType: UTType {
        UTType(filenameExtension: fileExtension) ?? .data
    }
    static let fileExtension = "think"

    /// Slow on purpose: the cost a guess has to pay. OWASP's figure for PBKDF2-SHA256.
    private static let rounds = 600_000

    // MARK: - Writing

    /// Seals `secrets` under `passphrase` and returns the file's bytes.
    func write(
        connections: [ConnectionConfig],
        groups: [ConnectionBackupFile.BackupGroup],
        secrets: [ConnectionBackupFile.StoredSecret],
        passphrase: String,
        app: String
    ) throws -> Data {
        guard !connections.isEmpty else { throw ConnectionBackupError.nothingToBackUp }
        guard !passphrase.isEmpty else { throw ConnectionBackupError.emptyPassphrase }
        var salt = Data(count: 32)
        salt.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress {
                _ = SecRandomCopyBytes(kSecRandomDefault, buffer.count, base)
            }
        }
        let key = Self.derive(passphrase: passphrase, salt: salt, rounds: Self.rounds)
        let plain = try Self.encoder.encode(secrets)
        let sealed = try AES.GCM.seal(
            plain, using: key,
            authenticating: Self.authenticatedHeader(
                version: ConnectionBackupFile.currentVersion, connections: connections)
        )
        guard let box = sealed.combined else { throw ConnectionBackupError.notABackup }
        let file = ConnectionBackupFile(
            format: ConnectionBackupFile.formatName,
            version: ConnectionBackupFile.currentVersion,
            createdAt: Date(),
            app: app,
            connections: connections,
            groups: groups,
            secrets: ConnectionBackupFile.SealedSecrets(
                kdf: "pbkdf2-hmac-sha256", rounds: Self.rounds, salt: salt, box: box)
        )
        return try Self.encoder.encode(file)
    }

    // MARK: - Reading

    /// Parses the file without needing the passphrase, which is what lets the restore
    /// sheet say what is inside before asking for one.
    nonisolated func read(_ data: Data) throws -> ConnectionBackupFile {
        guard let file = try? Self.decoder.decode(ConnectionBackupFile.self, from: data),
            file.format == ConnectionBackupFile.formatName
        else { throw ConnectionBackupError.notABackup }
        guard file.version <= ConnectionBackupFile.currentVersion else {
            throw ConnectionBackupError.tooNew(file.version)
        }
        return file
    }

    /// Opens the sealed passwords. The header is authenticated as well as the box, so a
    /// secrets blob lifted from another backup cannot be pasted into this one.
    func secrets(in file: ConnectionBackupFile, passphrase: String) throws -> [ConnectionBackupFile.StoredSecret] {
        guard !passphrase.isEmpty else { throw ConnectionBackupError.emptyPassphrase }
        let key = Self.derive(passphrase: passphrase, salt: file.secrets.salt, rounds: file.secrets.rounds)
        do {
            let sealed = try AES.GCM.SealedBox(combined: file.secrets.box)
            let plain = try AES.GCM.open(
                sealed, using: key,
                authenticating: Self.authenticatedHeader(version: file.version, connections: file.connections)
            )
            return try Self.decoder.decode([ConnectionBackupFile.StoredSecret].self, from: plain)
        } catch {
            // A wrong passphrase and a tampered file fail the same way, and the person can
            // only act on one of them.
            throw ConnectionBackupError.wrongPassphrase
        }
    }

    // MARK: - The pieces a backup is made of

    /// Every secret reference a connection carries: its password, its SSH password or key
    /// passphrase, and the same again for every jump host behind it.
    nonisolated static func secretRefs(of config: ConnectionConfig) -> [SecretRef] {
        var refs: [SecretRef] = []
        if let passwordRef = config.passwordRef { refs.append(passwordRef) }
        var ssh = config.ssh
        while let current = ssh {
            switch current.auth {
            case let .password(ref): refs.append(ref)
            case let .privateKey(_, passphrase): if let passphrase { refs.append(passphrase) }
            case .agent: break
            }
            ssh = current.jumpHost?.value
        }
        return refs
    }

    /// What a restore does with a connection that is already there.
    enum MergePolicy: String, CaseIterable, Sendable {
        /// Keep what this Mac has; bring in only what it does not.
        case skip
        /// Let the backup win, field for field.
        case replace
    }

    /// What a restore would do, worked out before anything is written.
    struct MergePlan: Sendable, Equatable {
        var added: [ConnectionConfig] = []
        var replaced: [ConnectionConfig] = []
        var skipped: [ConnectionConfig] = []

        var isEmpty: Bool { added.isEmpty && replaced.isEmpty }
    }

    /// Connections are matched by identity, not by name: the same connection restored
    /// twice is the same row, and two connections that happen to share a name are two.
    nonisolated static func plan(
        existing: [ConnectionConfig], incoming: [ConnectionConfig], policy: MergePolicy
    ) -> MergePlan {
        let known = Set(existing.map(\.id))
        var plan = MergePlan()
        for config in incoming {
            if !known.contains(config.id) {
                plan.added.append(config)
            } else if policy == .replace {
                plan.replaced.append(config)
            } else {
                plan.skipped.append(config)
            }
        }
        return plan
    }

    /// The name a backup is offered under: dated, so a folder of them reads in order.
    nonisolated static func suggestedFilename(now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return "Tinker Connections \(formatter.string(from: now)).\(fileExtension)"
    }

    // MARK: - Crypto

    /// PBKDF2-HMAC-SHA256. CryptoKit has no password-based derivation; this is the one
    /// the platform ships.
    private static func derive(passphrase: String, salt: Data, rounds: Int) -> SymmetricKey {
        var derived = Data(count: 32)
        let password = Array(passphrase.utf8)
        let status = derived.withUnsafeMutableBytes { output -> Int32 in
            salt.withUnsafeBytes { saltBytes -> Int32 in
                guard let outputBase = output.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    let saltBase = saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self)
                else { return Int32(kCCParamError) }
                return CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2), password, password.count,
                    saltBase, saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(rounds),
                    outputBase, output.count
                )
            }
        }
        // The only failures documented are bad parameters, which are fixed here; a key of
        // zeros would still be a key, and would simply fail to open anything.
        precondition(status == kCCSuccess, "PBKDF2 refused its own parameters")
        return SymmetricKey(data: derived)
    }

    /// What the box is bound to besides its contents: the format, the version and the
    /// connections the secrets belong to.
    private static func authenticatedHeader(version: Int, connections: [ConnectionConfig]) -> Data {
        let ids = connections.map(\.id.uuidString).sorted().joined(separator: ",")
        return Data("\(ConnectionBackupFile.formatName)/\(version)/\(ids)".utf8)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
