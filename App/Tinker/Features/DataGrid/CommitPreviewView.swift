import DBCore
import DBSQL
import SwiftUI

/// The sheet that shows exactly what a commit will run before it runs.
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
        SheetFrame(
            title: "Review \(preview.statements.count) statement\(preview.statements.count == 1 ? "" : "s")",
            icon: Icon.commit,
            subtitle: preview.summary
                + " on \(preview.connectionName). Everything runs in one transaction; a statement that does not affect exactly one row rolls the whole thing back.",
            width: DesignTokens.Metrics.wideSheetWidth
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                ScrollView {
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                        ForEach(Array(preview.statements.enumerated()), id: \.element.id) { index, statement in
                            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                                HStack(spacing: DesignTokens.Spacing.sm) {
                                    Text("\(index + 1)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                                    Badge(
                                        text: statement.kind.rawValue.uppercased(),
                                        color: Self.color(for: statement.kind))
                                    Text(statement.table.name).font(.caption).foregroundStyle(.secondary)
                                }
                                Text(statement.displaySQL(dialect: preview.dialect))
                                    .font(.system(.caption, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(DesignTokens.Spacing.sm)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 420)

                if let failure {
                    InlineBanner(kind: .error, message: failure) { self.failure = nil }
                }
            }
        } footer: {
            if preview.isProduction {
                Label(preview.connectionName, systemImage: Icon.production)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.red)
            }
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
            .buttonStyle(.borderedProminent)
            .disabled(isExecuting || productionDelayRemaining > 0)
            .tint(preview.isProduction ? .red : nil)
        }
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

    static func color(for kind: GeneratedStatement.Kind) -> Color {
        switch kind {
        case .insert: .green
        case .update: .yellow
        case .delete: .red
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
/// a production connection.
public struct DestructiveConfirmationView: View {
    let confirmation: DestructiveConfirmation
    let onDismiss: () -> Void

    @State private var typed = ""
    @State private var isRunning = false

    private var isInformational: Bool { confirmation.confirmTitle == "OK" }

    public var body: some View {
        SheetFrame(
            title: confirmation.title,
            icon: isInformational ? Icon.info : Icon.warning,
            subtitle: confirmation.message,
            width: DesignTokens.Metrics.compactSheetWidth
        ) {
            if let required = confirmation.requiredTypedName {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    Text("Type “\(required)” to confirm").font(.caption).foregroundStyle(.secondary)
                    TextField("", text: $typed).textFieldStyle(.roundedBorder)
                }
            } else {
                EmptyView()
            }
        } footer: {
            Spacer()
            if !isInformational {
                Button("Cancel", role: .cancel, action: onDismiss)
                    .keyboardShortcut(.cancelAction)
            }
            Button(isRunning ? "Working…" : confirmation.confirmTitle, role: isInformational ? nil : .destructive) {
                isRunning = true
                Task {
                    await confirmation.action()
                    isRunning = false
                    onDismiss()
                }
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .tint(isInformational ? nil : .red)
            .disabled(isRunning || (confirmation.requiredTypedName.map { $0 != typed } ?? false))
        }
    }
}
