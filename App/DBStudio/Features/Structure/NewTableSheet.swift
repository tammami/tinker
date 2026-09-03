import DBCore
import SwiftUI

/// Builds a table that does not exist yet (SPEC §15b.3).
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
            HStack(spacing: 8) {
                Text("New table in").font(.callout).foregroundStyle(.secondary)
                Text(schema.id).font(.callout.weight(.medium))
                TextField("name", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onChange(of: name) { _, newName in rename(to: newName) }
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
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
