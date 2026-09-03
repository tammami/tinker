import DBCore
import DBSQL
import SwiftUI

/// The sheet that shows what a structure change will run, and the only route to Execute.
struct DDLPreviewView: View {
    let statements: [GeneratedDDL]
    let dialect: SQLDialect
    /// False on MySQL, where each statement commits as it runs.
    let isTransactional: Bool
    let tableName: String
    let isProduction: Bool
    let onExecute: () async -> Void
    let onCancel: () -> Void

    @State private var isExecuting = false
    @State private var productionDelayRemaining = 0.0

    /// A production connection makes the user wait a moment before they can execute, the
    /// same delay the data grid's commit sheet uses.
    private static let productionDelay = 1.5

    private var destructive: [GeneratedDDL] { statements.filter(\.isDestructive) }

    var body: some View {
        SheetFrame(
            title: "Review \(statements.count) statement\(statements.count == 1 ? "" : "s")",
            icon: Icon.structure,
            subtitle: isTransactional
                ? "They run in one transaction on \(tableName)."
                : "They run in order on \(tableName). MySQL commits each one as it runs.",
            width: DesignTokens.Metrics.wideSheetWidth
        ) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                statementList
                if !isTransactional {
                    InlineBanner(
                        kind: .warning,
                        message: "If one statement fails, the ones before it stay applied and cannot be rolled back.",
                        onDismiss: {}
                    )
                }
                if !destructive.isEmpty {
                    InlineBanner(
                        kind: .error,
                        message:
                            "\(destructive.count) statement\(destructive.count == 1 ? "" : "s") discard\(destructive.count == 1 ? "s" : "") data that cannot be recovered.",
                        onDismiss: {}
                    )
                }
            }
        } footer: {
            if isProduction {
                Label("Production", systemImage: Icon.production)
                    .foregroundStyle(.red)
                    .font(.callout.weight(.semibold))
            }
            Spacer()
            Button("Cancel", action: onCancel)
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
            .tint(destructive.isEmpty && !isProduction ? nil : .red)
            .disabled(isExecuting || statements.isEmpty || productionDelayRemaining > 0)
        }
        .task {
            guard isProduction else { return }
            productionDelayRemaining = Self.productionDelay
            while productionDelayRemaining > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                productionDelayRemaining -= 0.1
            }
        }
    }

    private var statementList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ForEach(Array(statements.enumerated()), id: \.element.id) { index, statement in
                    VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Badge(text: label(for: statement.kind), color: statement.isDestructive ? .red : .secondary)
                            if statement.isDestructive {
                                Image(systemName: Icon.warning).font(.caption2).foregroundStyle(.red)
                            }
                        }
                        Text(statement.sql)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(DesignTokens.Spacing.sm)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                }
            }
        }
        .frame(minHeight: 240, maxHeight: 420)
    }

    private var executeTitle: String {
        if isExecuting { return "Executing…" }
        if productionDelayRemaining > 0 {
            return "Execute (\(Int(productionDelayRemaining.rounded(.up))))"
        }
        return "Execute"
    }

    private func label(for kind: GeneratedDDL.Kind) -> String {
        switch kind {
        case .createTable: "Create table"
        case .dropTable: "Drop table"
        case .renameTable: "Rename table"
        case .addColumn: "Add column"
        case .alterColumn: "Alter column"
        case .renameColumn: "Rename column"
        case .dropColumn: "Drop column"
        case .addPrimaryKey: "Add primary key"
        case .dropPrimaryKey: "Drop primary key"
        case .createIndex: "Create index"
        case .dropIndex: "Drop index"
        case .renameIndex: "Rename index"
        case .addForeignKey: "Add foreign key"
        case .dropForeignKey: "Drop foreign key"
        case .addCheck: "Add check"
        case .dropCheck: "Drop check"
        case .createTrigger: "Create trigger"
        case .dropTrigger: "Drop trigger"
        case .comment: "Comment"
        case .tableOption: "Table option"
        case .partition: "Partition"
        }
    }
}
