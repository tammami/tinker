import DBCore
import DBSQL
import SwiftUI

/// The sheet that shows exactly what a commit will run before it runs (SPEC §12.3).
public struct CommitPreviewView: View {
    let preview: CommitPreview
    let onExecute: () async -> Void
    let onCancel: () -> Void

    @State private var isExecuting = false
    @State private var productionDelayRemaining = 0.0
    @State private var failure: String?

    /// A production connection makes the user wait a moment before they can execute.
    private static let productionDelay = 1.5

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Review \(preview.statements.count) statement\(preview.statements.count == 1 ? "" : "s")")
                        .font(.headline)
                    Text(preview.summary).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if preview.isProduction {
                    Label(preview.connectionName, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.red)
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(preview.statements.enumerated()), id: \.element.id) { index, statement in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(index + 1). \(statement.kind.rawValue.uppercased())")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(statement.displaySQL(dialect: preview.dialect))
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(6)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    }
                }
            }
            .frame(minHeight: 220, maxHeight: 420)

            if let failure {
                ErrorBanner(message: failure) { self.failure = nil }
            }

            HStack {
                Text("Everything runs in one transaction. Any statement that does not affect exactly one row rolls the whole thing back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(executeTitle) {
                    isExecuting = true
                    Task {
                        await onExecute()
                        isExecuting = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isExecuting || productionDelayRemaining > 0)
                .tint(preview.isProduction ? .red : nil)
            }
        }
        .padding(16)
        .frame(width: 640)
        .task {
            guard preview.isProduction else { return }
            productionDelayRemaining = Self.productionDelay
            // A short pause on production, so Execute is never hit by muscle memory.
            while productionDelayRemaining > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                productionDelayRemaining -= 0.1
            }
            productionDelayRemaining = 0
        }
    }

    var executeTitle: String {
        if productionDelayRemaining > 0 {
            return "Execute on \(preview.connectionName) (\(Int(productionDelayRemaining.rounded(.up))))"
        }
        return preview.isProduction ? "Execute on \(preview.connectionName)" : "Execute"
    }
}

/// The sheet used for truncate, drop and delete, which asks the user to type the name on
/// a production connection (SPEC §11.1).
public struct DestructiveConfirmationView: View {
    let confirmation: DestructiveConfirmation
    let onDismiss: () -> Void

    @State private var typed = ""

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(confirmation.title).font(.headline)
            Text(confirmation.message).font(.callout).foregroundStyle(.secondary)
            if let required = confirmation.requiredTypedName {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Type “\(required)” to confirm").font(.caption)
                    TextField("", text: $typed).textFieldStyle(.roundedBorder)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
                Button(confirmation.confirmTitle, role: .destructive) {
                    Task {
                        await confirmation.action()
                        onDismiss()
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(confirmation.requiredTypedName.map { $0 != typed } ?? false)
            }
        }
        .padding(16)
        .frame(width: 420)
    }
}
