import DBCore
import Foundation
import XCTest

@testable import DBStore

/// Keychain round-trips, run against a scratch service name so nothing the user owns is
/// touched. If the Keychain is unavailable — an unsigned test binary on a locked-down
/// machine — the test skips with the OS status rather than failing.
final class KeychainSecretStoreTests: XCTestCase {
    var store: KeychainSecretStore!
    var service: String!
    var connectionID: UUID!

    override func setUp() async throws {
        service = "com.dbstudio.tests.\(UUID().uuidString)"
        store = KeychainSecretStore(serviceOverride: service)
        connectionID = UUID()

        // Prove the Keychain is usable here before relying on it.
        let probe = SecretRef.forConnection(connectionID, field: "probe")
        do {
            try await store.setSecret("probe", for: probe)
            try await store.deleteSecret(for: probe)
        } catch let error as KeychainError {
            throw XCTSkip("Keychain unavailable in this environment: \(error.description)")
        }
    }

    override func tearDown() async throws {
        try? await store.deleteSecrets(forConnection: connectionID)
    }

    func testRoundTrip() async throws {
        let reference = SecretRef.forConnection(connectionID, field: "password")
        let missing = try await store.secret(for: reference)
        XCTAssertNil(missing)

        try await store.setSecret("hunter2", for: reference)
        let stored = try await store.secret(for: reference)
        XCTAssertEqual(stored, "hunter2")

        // Writing again updates rather than duplicating.
        try await store.setSecret("hunter3", for: reference)
        let updated = try await store.secret(for: reference)
        XCTAssertEqual(updated, "hunter3")

        try await store.deleteSecret(for: reference)
        let deleted = try await store.secret(for: reference)
        XCTAssertNil(deleted)
    }

    func testUnicodeAndLongSecretsSurvive() async throws {
        let reference = SecretRef.forConnection(connectionID, field: "password")
        let secret = "pässwörd 日本語 🔐 " + String(repeating: "x", count: 4_000)
        try await store.setSecret(secret, for: reference)
        let stored = try await store.secret(for: reference)
        XCTAssertEqual(stored, secret)
    }

    func testDeletingAConnectionRemovesEveryField() async throws {
        for field in SecretField.allCases {
            try await store.setSecret(
                "value-\(field.rawValue)", for: SecretRef.forConnection(connectionID, field: field.rawValue))
        }
        for field in SecretField.allCases {
            let stored = try await store.secret(for: SecretRef.forConnection(connectionID, field: field.rawValue))
            XCTAssertEqual(stored, "value-\(field.rawValue)")
        }

        try await store.deleteSecrets(forConnection: connectionID)
        for field in SecretField.allCases {
            let stored = try await store.secret(for: SecretRef.forConnection(connectionID, field: field.rawValue))
            XCTAssertNil(stored, "\(field.rawValue) survived deletion")
        }
    }

    func testSecretsAreScopedToTheirConnection() async throws {
        let other = UUID()
        try await store.setSecret("mine", for: SecretRef.forConnection(connectionID, field: "password"))
        try await store.setSecret("theirs", for: SecretRef.forConnection(other, field: "password"))

        try await store.deleteSecrets(forConnection: connectionID)
        let survivor = try await store.secret(for: SecretRef.forConnection(other, field: "password"))
        XCTAssertEqual(survivor, "theirs")
        try await store.deleteSecrets(forConnection: other)
    }

    func testDeletingSomethingThatIsNotThereIsNotAnError() async throws {
        let reference = SecretRef.forConnection(UUID(), field: "password")
        try await store.deleteSecret(for: reference)
    }
}

final class EphemeralSecretStoreTests: XCTestCase {
    func testBehavesLikeTheKeychainStore() async throws {
        let store = EphemeralSecretStore()
        let id = UUID()
        let reference = SecretRef.forConnection(id, field: "password")
        let missing = try await store.secret(for: reference)
        XCTAssertNil(missing)

        try await store.setSecret("hunter2", for: reference)
        let stored = try await store.secret(for: reference)
        XCTAssertEqual(stored, "hunter2")

        try await store.deleteSecrets(forConnection: id)
        let deleted = try await store.secret(for: reference)
        XCTAssertNil(deleted)
    }
}
