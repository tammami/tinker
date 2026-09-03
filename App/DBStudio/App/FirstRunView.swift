import DBCore
import SwiftUI

/// Shown the first time DBStudio launches with no connections.
///
/// It states plainly what the app does with credentials and diagnostics, because those are
/// the two questions a database client should answer before it asks for a password.
public struct FirstRunView: View {
    let onAddConnection: () -> Void
    let onDismiss: () -> Void
    let onSetDiagnostics: (Bool) -> Void

    @State private var collectDiagnostics = false

    public var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: DesignTokens.Spacing.md) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 72, height: 72)
                Text("Welcome to \(Product.name)").font(.title2.weight(.semibold))
                Text("A native client for PostgreSQL and MySQL.")
                    .foregroundStyle(.secondary)
                Text(Product.credit).font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.top, DesignTokens.Spacing.xl)
            .padding(.bottom, DesignTokens.Spacing.lg)

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                point(
                    Icon.key, .blue, "Passwords live in your macOS Keychain",
                    "Never in \(Product.name)'s own files.")
                point(
                    Icon.shield, .green, "Every change is shown as SQL before it runs",
                    "Grid edits run in one transaction, and roll back if anything is off.")
                point(
                    Icon.production, .orange, "Mark a connection Production or Read-only",
                    "Production asks before every write. Read-only blocks them entirely.")
            }
            .padding(.horizontal, DesignTokens.Spacing.xl)

            Toggle(isOn: $collectDiagnostics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save diagnostic reports on this Mac")
                    Text("Written to Application Support and never sent anywhere.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: collectDiagnostics) { _, value in onSetDiagnostics(value) }
            .padding(DesignTokens.Spacing.xl)

            Divider()
            HStack {
                Button("Later", action: onDismiss)
                Spacer()
                Button {
                    onAddConnection()
                    onDismiss()
                } label: {
                    Label("Add a Connection…", systemImage: Icon.add)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
            .background(.bar)
        }
        .frame(width: 520)
    }

    private func point(_ icon: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
