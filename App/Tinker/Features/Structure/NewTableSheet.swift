import DBCore
import SwiftUI

/// Builds a table that does not exist yet.
///
/// It is the Structure tab's own panes with an empty definition behind them, so a new
/// table is described exactly the way an existing one is edited.
struct NewTableSheet: View {
    let connectionID: UUID
    let schema: SchemaRef
    let dialect: SQLDialect
    let environment: AppEnvironment
    let isProduction: Bool
    /// Called with the table once the server has it, so the caller can open it.
    let onCreated: (TableRef) -> Void
    let onCancel: () -> Void

    @State private var name = "new_table"
    @State private var controller: StructureController?

    @State private var isPreviewPresented = false

    var body: some View {
        VStack(spacing: 0) {
            // Header: what this is and where it goes, with the name right there.
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: Icon.table)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                VStack(alignment: .leading, spacing: 2) {
                    Text("New Table").font(.headline)
                    Text("in \(schema.id) · \(dialect.displayName)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: DesignTokens.Spacing.lg)
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Text("Name").foregroundStyle(.secondary)
                    TextField("table_name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 260)
                        .onChange(of: name) { _, newName in rename(to: newName) }
                }
                if isProduction {
                    Label("Production", systemImage: Icon.production)
                        .foregroundStyle(.red).font(.callout.weight(.semibold)).fixedSize()
                }
            }
            .padding(DesignTokens.Spacing.lg)
            Divider()

            if let controller {
                StructureView(
                    controller: controller,
                    isProduction: isProduction,
                    previewPresented: $isPreviewPresented,
                    showsActions: false
                )
                .onChange(of: controller.didCreate) { _, created in
                    if created { onCreated(controller.table) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            Divider()
            // Footer: the one row every sheet ends with.
            HStack(spacing: DesignTokens.Spacing.sm) {
                if let controller {
                    let count = controller.pendingStatements.count
                    Badge(
                        text: count == 0 ? "Nothing to create yet" : "\(count) statement\(count == 1 ? "" : "s")",
                        color: count == 0 ? .secondary : .orange
                    )
                    let columns = controller.edited?.columns.count ?? 0
                    Text("\(columns) column\(columns == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Discard Changes") { controller?.discardChanges() }
                    .disabled(!(controller?.hasPendingChanges ?? false))
                Button {
                    isPreviewPresented = true
                } label: {
                    Label("Create Table…", systemImage: Icon.source)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(
                    !(controller?.hasPendingChanges ?? false) || name.trimmingCharacters(in: .whitespaces).isEmpty
                )
                .help("Review the CREATE TABLE statement, then run it")
            }
            .padding(.horizontal, DesignTokens.Spacing.lg)
            .padding(.vertical, DesignTokens.Spacing.md)
            .background(.bar)
        }
        .frame(minWidth: 940, idealWidth: 1_040, minHeight: 540, idealHeight: 600)
        .onAppear {
            guard controller == nil else { return }
            controller = StructureController(
                table: TableRef(schema: schema, name: name),
                connectionID: connectionID,
                dialect: dialect,
                environment: environment,
                mode: .create
            )
        }
    }

    /// The name field drives the definition, so the generated `CREATE TABLE` follows it.
    private func rename(to newName: String) {
        guard let controller, var definition = controller.edited else { return }
        definition.ref = TableRef(schema: schema, name: newName)
        controller.edited = definition
    }
}
