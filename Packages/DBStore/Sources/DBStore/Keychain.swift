import DBCore
import Foundation
import Security

/// Stores connection secrets in the macOS Keychain.
///
/// Nothing else in the app ever writes a password: configs carry a ``SecretRef`` and the
/// session resolves it here (SPEC §9). A test asserts that no secret reaches the store file.
public struct KeychainSecretStore: SecretStore {
    /// Set to run tests against a scratch service name instead of the real one.
    public let serviceOverride: String?

    public init(serviceOverride: String? = nil) {
        self.serviceOverride = serviceOverride
    }

    private func service(for reference: SecretRef) -> String {
        serviceOverride ?? reference.service
    }

    private func baseQuery(_ reference: SecretRef) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: reference),
            kSecAttrAccount as String: reference.account,
        ]
    }

    public func secret(for reference: SecretRef) async throws -> String? {
        var query = baseQuery(reference)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data else { return nil }
            return String(data: data, encoding: .utf8)
        case errSecItemNotFound:
            // A secret saved before the rename lives under the old service; bring it over.
            guard serviceOverride == nil, reference.service == SecretRef.defaultService else { return nil }
            let legacy = SecretRef(service: SecretRef.legacyService, account: reference.account)
            guard let value = try await secret(for: legacy) else { return nil }
            try? await setSecret(value, for: reference)
            return value
        default:
            throw KeychainError(status: status, operation: "read")
        }
    }

    public func setSecret(_ value: String, for reference: SecretRef) async throws {
        let data = Data(value.utf8)
        let query = baseQuery(reference)
        let update: [String: Any] = [
            kSecValueData as String: data,
            // The secret is needed whenever the app runs, but never syncs to another device.
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "update")
        }
        var insert = query
        insert.merge(update) { _, new in new }
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus, operation: "add")
        }
    }

    public func deleteSecret(for reference: SecretRef) async throws {
        let status = SecItemDelete(baseQuery(reference) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status, operation: "delete")
        }
    }

    /// Deletes every secret belonging to a connection, which is what removing it must do.
    public func deleteSecrets(forConnection id: UUID) async throws {
        for field in SecretField.allCases {
            try await deleteSecret(for: SecretRef.forConnection(id, field: field.rawValue))
        }
    }
}

/// The secret fields one connection can have. Deleting a connection deletes all of them.
public enum SecretField: String, Sendable, CaseIterable {
    case password
    case sshPassword
    case sshPassphrase
}

/// A Keychain call that failed, carrying the OS status so the message is actionable.
public struct KeychainError: Error, CustomStringConvertible {
    public let status: OSStatus
    public let operation: String

    public var description: String {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return "Keychain \(operation) failed: \(message)"
    }
}
