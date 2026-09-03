import DBCore
import DBSQL
import SwiftUI

/// The grid's filter bar: a quick search across every column, and rows of
/// column/operator/value combined with AND, plus the generated clause on request.
public struct FilterBarView: View {
    let columns: [ColumnMeta]
    let dialect: SQLDialect
    @Binding var rules: [FilterRule]
    @Binding var quickSearch: String
    let onApply: ([FilterRule]) -> Void
    let onQuickSearch: (String) -> Void

    @State private var isShowingClause = false
    @FocusState private var isSearchFocused: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PaneBar {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Image(systemName: Icon.search).foregroundStyle(.secondary)
                    TextField("Search every column…", text: $quickSearch)
                        .textFieldStyle(.plain)
                        .focused($isSearchFocused)
                        .focusesOnSearchCommand($isSearchFocused)
                        .onSubmit { onQuickSearch(quickSearch) }
                        // Live: the rows follow the text as it is typed, the way a
                        // person expects a search box to behave.
                        .onChange(of: quickSearch) { _, new in onQuickSearch(new) }
                    if !quickSearch.isEmpty {
                        IconButton(icon: "xmark.circle.fill", label: "Clear search") {
                            quickSearch = ""
                            onQuickSearch("")
                        }
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.sm)
                .frame(width: 260, height: 24)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius)
                        .strokeBorder(isSearchFocused ? Color.accentColor : Color.primary.opacity(0.1))
                )

                BarDivider()

                Button {
                    rules.append(FilterRule(
                        column: columns.first?.name ?? "", op: .equal, values: [.string("")]
                    ))
                } label: {
                    Label("Add Condition", systemImage: Icon.add)
                }
                .buttonStyle(.borderless)
                .help("Add a column condition; conditions are combined with AND")

                if !rules.isEmpty {
                    Button("Apply") { onApply(rules) }
                        .help("Apply the conditions now; they also apply as you edit them")
                    Button("Clear") {
                        rules.removeAll()
                        onApply(rules)
                    }
                    .help("Remove every condition")
                }

                Spacer()

                if !rules.isEmpty {
                    Badge(text: "\(rules.count) condition\(rules.count == 1 ? "" : "s")", color: .accentColor)
                    Toggle(isOn: $isShowingClause) {
                        Label("SQL", systemImage: Icon.source)
                    }
                    .toggleStyle(.button)
                    .buttonStyle(.borderless)
                    .help("Show the WHERE clause these conditions produce")
                }
            }
            .controlSize(.small)

            if !rules.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                    ForEach($rules) { $rule in
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Picker("Column", selection: $rule.column) {
                                ForEach(columns, id: \.name) { column in
                                    Text(column.name).tag(column.name)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 170)
                            .onChange(of: rule.column) { _, _ in onApply(rules) }

                            Picker("Operator", selection: $rule.op) {
                                ForEach(FilterOperator.allCases.filter { $0 != .anyContains }, id: \.self) { op in
                                    Text(op.symbol).tag(op)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 120)
                            .onChange(of: rule.op) { _, _ in onApply(rules) }

                            if rule.op.operandCount != 0 {
                                TextField(
                                    rule.op == .inList ? "value, value, …"
                                        : rule.op == .between ? "low, high" : "value",
                                    text: valueBinding(for: $rule)
                                )
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 260)
                                .onSubmit { onApply(rules) }
                                .onChange(of: rule.values) { _, _ in onApply(rules) }
                            }

                            IconButton(icon: "minus.circle", label: "Remove this condition") {
                                rules.removeAll { $0.id == rule.id }
                                onApply(rules)
                            }
                            Spacer()
                        }
                        .controlSize(.small)
                    }

                    if isShowingClause {
                        // The generated clause, so the user can see exactly what will run.
                        Text(generatedClause)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(DesignTokens.Spacing.sm)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(nsColor: .textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                    }
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.sm)
                .background(.bar)
            }
        }
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
