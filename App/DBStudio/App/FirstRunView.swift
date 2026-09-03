import DBCore
import SwiftUI

/// Shown the first time DBStudio launches with no connections (SPEC §16 Phase 7).
///
/// It states plainly what the app does with credentials and diagnostics, because those are
/// the two questions a database client should answer before it asks for a password.
public struct FirstRunView: View {
    let onAddConnection: () -> Void
    let onDismiss: () -> Void
    let onSetDiagnostics: (Bool) -> Void

    @State private var collectDiagnostics = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Welcome to DBStudio").font(.title2.weight(.semibold))
                    Text("A native client for PostgreSQL and MySQL.")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Passwords are stored in your macOS Keychain, never in DBStudio's own files.")
                } icon: {
                    Image(systemName: "key.fill").foregroundStyle(.blue)
                }
                Label {
                    Text("Every change you make in the grid is shown to you as SQL before it runs, and runs in one transaction.")
                } icon: {
                    Image(systemName: "checkmark.shield").foregroundStyle(.green)
                }
                Label {
                    Text("Mark a connection as Production to get a confirmation on every write, or Read-only to block them entirely.")
                } icon: {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            .font(.callout)

            Toggle(isOn: $collectDiagnostics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save diagnostic reports on this Mac")
                    Text("Written to Application Support and never sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: collectDiagnostics) { _, value in onSetDiagnostics(value) }

            HStack {
                Spacer()
                Button("Later", action: onDismiss)
                Button("Add a Connection…") {
                    onAddConnection()
                    onDismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }
}
