import DBCore
import DBSQL
import SwiftUI

/// The sheet that shows what a structure change will run, and the only route to Execute
/// (SPEC §15b.2).
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
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            statementList
            if !isTransactional { implicitCommitWarning }
            if !destructive.isEmpty { destructiveWarning }
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 460)
        .task {
            guard isProduction else { return }
            productionDelayRemaining = Self.productionDelay
            while productionDelayRemaining > 0 {
                try? await Task.sleep(for: .milliseconds(100))
                productionDelayRemaining -= 0.1
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Review \(statements.count) statement\(statements.count == 1 ? "" : "s")")
                .font(.headline)
            Text(
                isTransactional
                    ? "They run in one transaction on \(tableName)."
                    : "They run in order on \(tableName)."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var statementList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(statements.enumerated()), id: \.element.id) { index, statement in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 6) {
                            Text("\(index + 1)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.tertiary)
                            Text(label(for: statement.kind))
                                .font(.caption.weight(.medium))
                                .foregroundStyle(statement.isDestructive ? .red : .secondary)
                            if statement.isDestructive {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                            }
                        }
                        Text(statement.sql)
                            .font(.system(.callout, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color(nsColor: .textBackgroundColor))
                    )
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    /// MySQL cannot undo this, and the user has to be told before they run it, not after.
    private var implicitCommitWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(
                "MySQL commits each structure statement as it runs. If one fails, the "
                    + "statements before it stay applied and cannot be rolled back."
            )
            .font(.callout)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.12)))
    }

    private var destructiveWarning: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "trash.fill").foregroundStyle(.red)
            Text(
                "\(destructive.count) statement\(destructive.count == 1 ? "" : "s") "
                    + "discard\(destructive.count == 1 ? "es" : "") data that cannot be recovered."
            )
            .font(.callout)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.12)))
    }

    private var footer: some View {
        HStack {
            if isProduction {
                Label("Production", systemImage: "exclamationmark.octagon.fill")
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
            .disabled(isExecuting || statements.isEmpty || productionDelayRemaining > 0)
        }
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
