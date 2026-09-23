import AppKit
import DBCore
import SwiftUI

/// A `.think` file that has been opened and is waiting for a passphrase.
struct ConnectionRestoreRequest: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let file: ConnectionBackupFile
}

/// Seals every connection into a `.think` file.
///
/// The passphrase is asked for here rather than after the save panel, so nothing is
/// written until the person has one they can repeat.
struct BackUpConnectionsSheet: View {
    let connectionCount: Int
    /// Runs the save panel and writes the file, reporting where it went; nil when the
    /// panel was cancelled and nothing was written.
    let onBackUp: (String) async -> Result<String?, any Error>
    let onDismiss: () -> Void

    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var isWorking = false
    @State private var failure: String?
    @State private var summary: String?

    private var mismatched: Bool { !confirmation.isEmpty && confirmation != passphrase }
    private var canBackUp: Bool { !passphrase.isEmpty && passphrase == confirmation }

    var body: some View {
        SheetFrame(
            title: "Back Up Connections",
            icon: Icon.backup,
            subtitle: "\(connectionCount) connection\(connectionCount == 1 ? "" : "s") and the sidebar folders, "
                + "in one file you can restore on another Mac"
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if let summary {
                    InlineBanner(kind: .success, message: summary) {}
                } else {
                    FieldRow(label: "Passphrase") {
                        SecureField("Required", text: $passphrase)
                    }
                    FieldRow(label: "Repeat") {
                        SecureField("Type it again", text: $confirmation)
                    }
                    if mismatched {
                        InlineBanner(kind: .warning, message: "The two passphrases are not the same.") {}
                    }
                    if let failure {
                        InlineBanner(kind: .error, message: failure) { self.failure = nil }
                    }
                    InlineBanner(
                        kind: .info,
                        message: "Passwords and SSH passphrases are encrypted with this passphrase.",
                        detail: "Host names, ports and user names are written as they are, so the file can be read "
                            + "and compared. Keep the passphrase: without it the passwords cannot be recovered, by "
                            + "you or by us."
                    ) {}
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button(summary == nil ? "Cancel" : "Done", role: summary == nil ? .cancel : nil, action: onDismiss)
                .keyboardShortcut(.cancelAction)
                // Closing does not stop the work under way; it only hides what it did.
                .disabled(isWorking)
            if summary == nil {
                Button("Choose Location…") { backUp() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canBackUp || isWorking)
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    private func backUp() {
        isWorking = true
        failure = nil
        Task {
            switch await onBackUp(passphrase) {
            // A cancelled save panel wrote nothing; the sheet stays for another try.
            case let .success(message): if let message { summary = message }
            case let .failure(error):
                failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            isWorking = false
        }
    }
}

/// Puts a `.think` file back: what it holds, what would happen to what is already here,
/// and the passphrase that opens its passwords.
struct RestoreConnectionsSheet: View {
    let request: ConnectionRestoreRequest
    let existing: [ConnectionConfig]
    /// Runs the restore and reports what it did, or what stopped it.
    let onRestore: (String, ConnectionBackupCodec.MergePolicy) async -> Result<String, any Error>
    let onDismiss: () -> Void

    @State private var passphrase = ""
    @State private var policy: ConnectionBackupCodec.MergePolicy = .skip
    @State private var isWorking = false
    @State private var failure: String?
    @State private var summary: String?

    private var plan: ConnectionBackupCodec.MergePlan {
        ConnectionBackupCodec.plan(
            existing: existing, incoming: request.file.connections, policy: policy)
    }

    private var made: String {
        let when = request.file.createdAt.formatted(date: .abbreviated, time: .shortened)
        return "\(request.file.app) · \(when)"
    }

    var body: some View {
        SheetFrame(
            title: "Restore Connections",
            icon: Icon.restore,
            subtitle: request.url.lastPathComponent
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                if let summary {
                    InlineBanner(kind: .success, message: summary) {}
                } else {
                    FieldRow(label: "Backup") {
                        Text(made).foregroundStyle(.secondary)
                    }
                    FieldRow(label: "Holds") {
                        Text(
                            "\(request.file.connections.count) connection"
                                + "\(request.file.connections.count == 1 ? "" : "s")"
                                + ", \(request.file.groups.count) folder\(request.file.groups.count == 1 ? "" : "s")"
                        )
                    }
                    FieldRow(label: "Already here") {
                        Picker("", selection: $policy) {
                            Text("Keep mine").tag(ConnectionBackupCodec.MergePolicy.skip)
                            Text("Use the backup's").tag(ConnectionBackupCodec.MergePolicy.replace)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                    }
                    FieldRow(label: "Passphrase") {
                        SecureField("The one this backup was made with", text: $passphrase)
                    }
                    FieldRow(label: "Result") {
                        Text(plannedSummary).foregroundStyle(.secondary)
                    }
                    if let failure {
                        InlineBanner(kind: .error, message: failure) { self.failure = nil }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } footer: {
            if isWorking { ProgressView().controlSize(.small) }
            Spacer()
            Button(summary == nil ? "Cancel" : "Done", role: summary == nil ? .cancel : nil, action: onDismiss)
                .keyboardShortcut(.cancelAction)
                // Closing does not stop the work under way; it only hides what it did.
                .disabled(isWorking)
            if summary == nil {
                Button("Restore") { restore() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(passphrase.isEmpty || isWorking || plan.isEmpty)
            }
        }
        .interactiveDismissDisabled(isWorking)
    }

    /// What the buttons are about to do, in the same words the result will use.
    private var plannedSummary: String {
        let plan = plan
        if plan.isEmpty { return "Everything in this backup is already here" }
        var parts: [String] = []
        if !plan.added.isEmpty { parts.append("\(plan.added.count) added") }
        if !plan.replaced.isEmpty { parts.append("\(plan.replaced.count) replaced") }
        if !plan.skipped.isEmpty { parts.append("\(plan.skipped.count) left alone") }
        return parts.joined(separator: ", ")
    }

    private func restore() {
        isWorking = true
        failure = nil
        Task {
            switch await onRestore(passphrase, policy) {
            case let .success(message): summary = message
            case let .failure(error):
                failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            isWorking = false
        }
    }
}
