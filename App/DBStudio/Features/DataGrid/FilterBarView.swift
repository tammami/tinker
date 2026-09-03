import DBCore
import DBSQL
import SwiftUI

/// The grid's filter bar: rows of column/operator/value, combined with AND, plus an
/// advanced mode showing the generated clause (SPEC §12.2).
public struct FilterBarView: View {
    let columns: [ColumnMeta]
    let dialect: SQLDialect
    @Binding var rules: [FilterRule]
    let onApply: ([FilterRule]) -> Void

    @State private var isAdvanced = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($rules) { $rule in
                HStack(spacing: 6) {
                    Picker("", selection: $rule.column) {
                        ForEach(columns, id: \.name) { column in
                            Text(column.name).tag(column.name)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)

                    Picker("", selection: $rule.op) {
                        ForEach(FilterOperator.allCases, id: \.self) { op in
                            Text(op.symbol).tag(op)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 110)

                    if rule.op.operandCount != 0 {
                        TextField(
                            rule.op == .inList ? "value, value, …" : "value",
                            text: valueBinding(for: $rule)
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                    }

                    Button {
                        rules.removeAll { $0.id == rule.id }
                        onApply(rules)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this condition")
                    Spacer()
                }
            }

            HStack(spacing: 10) {
                Button {
                    rules.append(FilterRule(
                        column: columns.first?.name ?? "", op: .equal, values: [.string("")]
                    ))
                } label: {
                    Label("Add Condition", systemImage: "plus")
                }
                .buttonStyle(.borderless)

                Button("Apply") { onApply(rules) }
                    .keyboardShortcut(.return, modifiers: [])
                Button("Clear") {
                    rules.removeAll()
                    onApply(rules)
                }
                Toggle("Advanced", isOn: $isAdvanced)
                    .toggleStyle(.checkbox)
                Spacer()
            }

            if isAdvanced {
                // The generated clause, so the user can see exactly what will run.
                Text(generatedClause)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .padding(8)
        .background(.bar)
    }

    var generatedClause: String {
        let compiled = FilterCompiler.compile(rules, dialect: dialect)
        guard let clause = compiled.whereClause else { return "No filter" }
        return "WHERE " + SQLLiteral.renderForDisplay(
            clause, parameters: compiled.parameters, dialect: dialect
        )
    }

    /// Filter values are edited as text and sent as parameters; the server coerces them.
    func valueBinding(for rule: Binding<FilterRule>) -> Binding<String> {
        Binding(
            get: {
                rule.wrappedValue.values.compactMap { $0.text }.joined(separator: ", ")
            },
            set: { text in
                if rule.wrappedValue.op == .inList {
                    rule.wrappedValue.values = text
                        .split(separator: ",")
                        .map { .string($0.trimmingCharacters(in: .whitespaces)) }
                } else if rule.wrappedValue.op == .between {
                    let parts = text.split(separator: ",", maxSplits: 1)
                    rule.wrappedValue.values = parts.map {
                        .string($0.trimmingCharacters(in: .whitespaces))
                    }
                } else {
                    rule.wrappedValue.values = [.string(text)]
                }
            }
        )
    }
}
