import AppKit
import DBCore
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
    /// and writes it. Returns the sentence the sheet shows.
    func writeConnectionBackup(passphrase: String) async -> Result<String, any Error> {
        let connections = environment.connections
        let groups = environment.groups.map {
            ConnectionBackupFile.BackupGroup(path: $0.path, isExpanded: $0.isExpanded, sortOrder: $0.sortOrder)
        }
        var secrets: [ConnectionBackupFile.StoredSecret] = []
        for config in connections {
            for ref in ConnectionBackupCodec.secretRefs(of: config) {
                guard let value = try? await environment.secrets.secret(for: ref), !value.isEmpty else { continue }
                secrets.append(ConnectionBackupFile.StoredSecret(ref: ref, value: value))
            }
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [ConnectionBackupCodec.contentType]
        panel.nameFieldStringValue = ConnectionBackupCodec.suggestedFilename()
        panel.message = "Where should the backup go?"
        guard panel.runModal() == .OK, let url = panel.url else { return .success("") }
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
        do {
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
    /// then the connections, then their passwords into this Mac's Keychain.
    func restoreConnections(
        from request: ConnectionRestoreRequest,
        passphrase: String,
        policy: ConnectionBackupCodec.MergePolicy
    ) async -> Result<String, any Error> {
        let codec = ConnectionBackupCodec()
        let secrets: [ConnectionBackupFile.StoredSecret]
        do {
            secrets = try await codec.secrets(in: request.file, passphrase: passphrase)
        } catch {
            return .failure(error)
        }
        let plan = ConnectionBackupCodec.plan(
            existing: environment.connections, incoming: request.file.connections, policy: policy)
        for group in request.file.groups.sorted(by: { $0.sortOrder < $1.sortOrder }) where !group.path.isEmpty {
            await environment.restoreGroup(
                StoredGroup(path: group.path, isExpanded: group.isExpanded, sortOrder: group.sortOrder))
        }
        // Ids are kept, so every restored connection still points at the secret
        // references its own passwords were filed under — and only those are written,
        // exactly (`read` has refused anything pointing outside the file), and only for
        // the connections being restored: a kept one keeps its own passwords.
        let restoring = plan.added + plan.replaced
        let restoringIDs = Set(restoring.map(\.id.uuidString))
        let wanted = Set(restoring.flatMap(ConnectionBackupCodec.secretRefs(of:))).filter { ref in
            ref.account.split(separator: ".").first.map { restoringIDs.contains(String($0)) } ?? false
        }
        for config in plan.added + plan.replaced { await environment.save(config) }
        var restoredSecrets = 0
        var keychainFailure: (any Error)?
        for secret in secrets where wanted.contains(secret.ref) {
            do {
                try await environment.secrets.setSecret(secret.value, for: secret.ref)
                restoredSecrets += 1
            } catch {
                keychainFailure = keychainFailure ?? error
            }
        }
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
        if let keychainFailure { return .failure(keychainFailure) }
        var parts: [String] = []
        if !plan.added.isEmpty { parts.append("\(plan.added.count) added") }
        if !plan.replaced.isEmpty { parts.append("\(plan.replaced.count) replaced") }
        if !plan.skipped.isEmpty { parts.append("\(plan.skipped.count) left alone") }
        return .success(
            (parts.isEmpty ? "Nothing to restore" : "Restored: " + parts.joined(separator: ", "))
                + ", \(restoredSecrets) password\(restoredSecrets == 1 ? "" : "s") into your Keychain."
        )
    }
}
