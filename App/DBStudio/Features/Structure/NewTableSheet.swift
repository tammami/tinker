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

    var body: some View {
        VStack(spacing: 0) {
            PaneBar(height: 44) {
                Image(systemName: Icon.table)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 28, height: 28)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                Text("New table in").font(.callout).foregroundStyle(.secondary)
                Text(schema.id).font(.callout.weight(.medium))
                TextField("name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 240)
                    .onChange(of: name) { _, newName in rename(to: newName) }
                Spacer()
                if isProduction {
                    Label("Production", systemImage: Icon.production).foregroundStyle(.red).font(.callout.weight(.semibold))
                }
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            Divider()

            if let controller {
                StructureView(controller: controller, isProduction: isProduction)
                    .onChange(of: controller.didCreate) { _, created in
                        if created { onCreated(controller.table) }
                    }
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 520)
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
