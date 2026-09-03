import Foundation

/// Where passwords and passphrases live.
///
/// `DBCore` only knows the interface; the Keychain implementation is in `DBStore`, so
/// nothing here links against Security and tests can substitute an in-memory store.
/// Secrets are never written to a config, a log, or the store file (SPEC §9).
public protocol SecretStore: Sendable {
    func secret(for reference: SecretRef) async throws -> String?
    func setSecret(_ value: String, for reference: SecretRef) async throws
    func deleteSecret(for reference: SecretRef) async throws
    /// Removes every secret belonging to one connection, called when it is deleted.
    func deleteSecrets(forConnection id: UUID) async throws
}

/// An in-memory secret store, for tests and for previewing the connection editor.
public actor EphemeralSecretStore: SecretStore {
    private var secrets: [String: String] = [:]

    public init(_ initial: [SecretRef: String] = [:]) {
        for (reference, value) in initial { secrets[Self.key(reference)] = value }
    }

    private static func key(_ reference: SecretRef) -> String {
        "\(reference.service)/\(reference.account)"
    }

    public func secret(for reference: SecretRef) async throws -> String? {
        secrets[Self.key(reference)]
    }

    public func setSecret(_ value: String, for reference: SecretRef) async throws {
        secrets[Self.key(reference)] = value
    }

    public func deleteSecret(for reference: SecretRef) async throws {
        secrets.removeValue(forKey: Self.key(reference))
    }

    public func deleteSecrets(forConnection id: UUID) async throws {
        let prefix = id.uuidString
        for key in secrets.keys where key.contains(prefix) { secrets.removeValue(forKey: key) }
    }
}
