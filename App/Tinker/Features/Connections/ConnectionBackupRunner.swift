import AppKit
import DBCore
import DBSQLite
import DBStore
import Foundation
import UniformTypeIdentifiers

/// Backing up connections and putting them back (the File menu's two entries).
///
/// Nothing here connects to a server: a backup is what the connection editor holds, not
/// what the server has. A restored production connection stays marked as production.
@MainActor
extension WorkspaceController {
    /// What the file records about the app that wrote it, for a person reading it later.
    static var writingApp: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(Product.name) \(version) (\(build))"
    }

    /// Opens the sheet that asks for a passphrase, or says there is nothing to back up.
    func backUpConnections() {
        guard !environment.connections.isEmpty else {
            workspace.confirmation = DestructiveConfirmation(
                title: "Nothing to back up",
                message: ConnectionBackupError.nothingToBackUp.errorDescription ?? "",
                confirmTitle: "OK",
                action: {}
            )
            return
        }
        workspace.isBackUpConnectionsPresented = true
    }

    /// Collects the connections, the folders and their secrets, asks where the file goes,
    /// and writes it. Returns the sentence the sheet shows, or nil when the save panel was
    /// cancelled and nothing was written.
    func writeConnectionBackup(passphrase: String) async -> Result<String?, any Error> {
        let connections = environment.connections
        let groups = environment.groups.map {
            ConnectionBackupFile.BackupGroup(path: $0.path, isExpanded: $0.isExpanded, sortOrder: $0.sortOrder)
        }
        var secrets: [ConnectionBackupFile.StoredSecret] = []
        // A secret that is not there is a connection without one. A read the Keychain
        // refused — a denied prompt — is not the same thing, and a backup that quietly
        // left those passwords out would only be found out on the other Mac.
        var unreadable: [String] = []
        for config in connections {
            for ref in ConnectionBackupCodec.secretRefs(of: config) {
                do {
                    guard let value = try await environment.secrets.secret(for: ref), !value.isEmpty else { continue }
                    secrets.append(ConnectionBackupFile.StoredSecret(ref: ref, value: value))
                } catch {
                    if !unreadable.contains(config.name) { unreadable.append(config.name) }
                }
            }
        }
        guard unreadable.isEmpty else { return .failure(ConnectionBackupError.secretsUnreadable(unreadable)) }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ConnectionBackupCodec.contentType]
        panel.nameFieldStringValue = ConnectionBackupCodec.suggestedFilename()
        panel.message = "Where should the backup go?"
        guard panel.runModal() == .OK, let url = panel.url else { return .success(nil) }
        do {
            let data = try await ConnectionBackupCodec().write(
                connections: connections, groups: groups, secrets: secrets,
                passphrase: passphrase, app: Self.writingApp
            )
            try data.write(to: url, options: [.atomic])
            // The file holds sealed passwords: no one else on the machine need read it.
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let passwords = secrets.count
            return .success(
                "Backed up \(connections.count) connection\(connections.count == 1 ? "" : "s") and "
                    + "\(passwords) password\(passwords == 1 ? "" : "s") to “\(url.lastPathComponent)”."
            )
        } catch {
            return .failure(error)
        }
    }

    /// File › Restore Connections…: pick a `.think` file and open its sheet.
    func chooseConnectionBackup() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [ConnectionBackupCodec.contentType]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Tinker connections backup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openConnectionBackup(at: url)
    }

    /// Opens a backup that arrived from Finder or was dropped on the window.
    func openConnectionBackup(at url: URL) {
        // A second file would replace the sheet of a restore still writing, which would
        // then finish with nobody told what it did.
        guard !workspace.isRestoringConnections else {
            workspace.confirmation = DestructiveConfirmation(
                title: "A restore is still running",
                message: "Wait for it to finish before opening another backup.",
                confirmTitle: "OK",
                action: {}
            )
            return
        }
        do {
            // Measured before it is read, so a huge file is not pulled into memory first.
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= ConnectionBackupCodec.largestFile else { throw ConnectionBackupError.tooLarge }
            let file = try ConnectionBackupCodec().read(try Data(contentsOf: url))
            workspace.pendingConnectionRestore = ConnectionRestoreRequest(url: url, file: file)
        } catch {
            workspace.confirmation = DestructiveConfirmation(
                title: "This backup cannot be opened",
                message: (error as? LocalizedError)?.errorDescription ?? String(describing: error),
                confirmTitle: "OK",
                action: {}
            )
        }
    }

    /// Writes the connections back: the folders first, so a connection lands in its own,
    /// then the passwords into this Mac's Keychain, then the connections that use them.
    func restoreConnections(
        from request: ConnectionRestoreRequest,
        passphrase: String,
        policy: ConnectionBackupCodec.MergePolicy
    ) async -> Result<String, any Error> {
        workspace.isRestoringConnections = true
        defer { workspace.isRestoringConnections = false }
        let codec = ConnectionBackupCodec()
        let secrets: [ConnectionBackupFile.StoredSecret]
        do {
            secrets = try await codec.secrets(in: request.file, passphrase: passphrase)
        } catch {
            return .failure(error)
        }
        let plan = ConnectionBackupCodec.plan(
            existing: environment.connections, incoming: request.file.connections, policy: policy)

        // "Keep mine" keeps this Mac's folders too — their order and whether they are
        // open — and the backup's own go after them rather than interleaved by number.
        let known = Set(environment.groups.map(\.path))
        let after = policy == .skip ? (environment.groups.map(\.sortOrder).max() ?? -1) + 1 : 0
        for group in request.file.groups.sorted(by: { $0.sortOrder < $1.sortOrder }) where !group.path.isEmpty {
            guard policy == .replace || !known.contains(group.path) else { continue }
            await environment.restoreGroup(
                StoredGroup(path: group.path, isExpanded: group.isExpanded, sortOrder: after + group.sortOrder))
        }

        // Ids are kept, so every restored connection still points at the secret
        // references its own passwords were filed under. Only those are written, exactly
        // (`read` has refused anything pointing outside the file), and only for the
        // connections being restored: a kept one keeps its own passwords.
        let restoring = (plan.added + plan.replaced).map(Self.forThisMac)
        let restoringIDs = Set(restoring.map(\.id.uuidString))
        var restoredSecrets = 0
        var passwordsLeftOut: [String] = []
        var keychainError: (any Error)?
        for config in restoring {
            let refs = ConnectionBackupCodec.secretRefs(of: config).filter { ref in
                ref.account.split(separator: ".").first.map { restoringIDs.contains(String($0)) } ?? false
            }
            for secret in secrets where refs.contains(secret.ref) {
                do {
                    try await environment.secrets.setSecret(secret.value, for: secret.ref)
                    restoredSecrets += 1
                } catch {
                    keychainError = keychainError ?? error
                    if !passwordsLeftOut.contains(config.name) { passwordsLeftOut.append(config.name) }
                }
            }
        }
        for config in restoring { await environment.save(config) }
        let notSaved = restoring.filter { config in !environment.connections.contains { $0.id == config.id } }

        // A session keeps the settings it was opened with, so a replaced connection went
        // on connecting to the old host, without the read-only lock the backup set, until
        // the next launch. Dropping it is what a save in the connection editor does.
        for config in plan.replaced {
            await environment.invalidateSession(for: config.id)
        }
        sidebar.rebuildRoots()
        for config in plan.replaced {
            await sidebar.refresh(connectionID: config.id)
        }

        var parts: [String] = []
        if !plan.added.isEmpty { parts.append("\(plan.added.count) added") }
        if !plan.replaced.isEmpty { parts.append("\(plan.replaced.count) replaced") }
        if !plan.skipped.isEmpty { parts.append("\(plan.skipped.count) left alone") }
        let done =
            (parts.isEmpty ? "Nothing to restore" : "Restored: " + parts.joined(separator: ", "))
            + ", \(restoredSecrets) password\(restoredSecrets == 1 ? "" : "s") into your Keychain."
        guard passwordsLeftOut.isEmpty, notSaved.isEmpty else {
            return .failure(
                RestoreIncomplete(
                    done: done, passwordsLeftOut: passwordsLeftOut, notSaved: notSaved.map(\.name),
                    keychainError: keychainError, storeError: environment.startupError))
        }
        return .success(done)
    }

    /// A connection as it should arrive on another Mac. A SQLite connection set to create
    /// its file when missing would, at a path that does not exist here, quietly create an
    /// empty database there instead of saying the file is not found.
    static func forThisMac(_ config: ConnectionConfig) -> ConnectionConfig {
        guard config.dialect == .sqlite else { return config }
        var config = config
        config.options[SQLiteDriver.OptionKey.createIfMissing] = nil
        return config
    }
}

/// A restore that wrote some of what it was asked to: which connections are missing
/// their passwords or were not saved at all, and how to finish.
struct RestoreIncomplete: LocalizedError {
    let done: String
    let passwordsLeftOut: [String]
    let notSaved: [String]
    let keychainError: (any Error)?
    let storeError: String?

    var errorDescription: String? {
        var lines = [done]
        if !passwordsLeftOut.isEmpty {
            lines.append(
                "The Keychain did not take the passwords of \(passwordsLeftOut.joined(separator: ", "))"
                    + (keychainError.map { ": \(String(describing: $0))" } ?? "."))
        }
        if !notSaved.isEmpty {
            lines.append(
                "These connections were not saved: \(notSaved.joined(separator: ", "))"
                    + (storeError.map { ": \($0)" } ?? "."))
        }
        lines.append("Restore again with “Use the backup's” to write them.")
        return lines.joined(separator: "\n")
    }
}
