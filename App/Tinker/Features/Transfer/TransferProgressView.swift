import DBCore
import DBGrid
import SwiftUI

/// The bottom of every transfer sheet: a bar while it runs, what came of it after.
struct TransferProgressView: View {
    let controller: TransferController

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            switch controller.phase {
            case .idle:
                EmptyView()
            case .running:
                if let fraction = controller.fraction {
                    ProgressView(value: fraction)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                Text(controller.status.isEmpty ? "Working…" : controller.status)
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            case .finished:
                if let summary = controller.summary {
                    InlineBanner(kind: .success, message: summary, onDismiss: {})
                }
            case .failed:
                if let error = controller.errorText {
                    InlineBanner(
                        kind: .error, message: error, detail: controller.status.isEmpty ? nil : controller.status,
                        onDismiss: {})
                } else if let summary = controller.summary {
                    InlineBanner(kind: .warning, message: summary, onDismiss: {})
                }
            case .cancelled:
                InlineBanner(kind: .warning, message: controller.status, onDismiss: {})
            }
            if !controller.failures.isEmpty {
                failureList
            }
            if !controller.notes.isEmpty {
                notesList
            }
        }
    }

    /// What a cross-engine transfer could not carry, named so nothing is assumed to have crossed.
    private var notesList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Label("Left behind on the way across engines", systemImage: Icon.warning)
                .font(.caption.weight(.semibold)).foregroundStyle(.orange)
            ForEach(Array(controller.notes.enumerated()), id: \.offset) { _, note in
                Text(note).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    private var failureList: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            Text("Statements the server refused")
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            SimpleTable(
                columns: [
                    SimpleTable.Column(title: "Line", width: 60, isNumeric: true),
                    SimpleTable.Column(title: "Message"),
                    SimpleTable.Column(title: "Statement", width: 260),
                ],
                rows: controller.failures.map { failure in
                    [
                        failure.line.map(String.init) ?? String(failure.statementNumber), failure.message,
                        failure.excerpt,
                    ]
                }
            )
            .frame(height: min(CGFloat(controller.failures.count + 1) * DesignTokens.Metrics.gridRowHeight + 4, 160))
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius)
                    .strokeBorder(Color.primary.opacity(0.1)))
        }
    }
}

/// The table picker a dump or paste of a whole schema shows.
struct TransferTableList: View {
    let tables: [TableInfo]
    @Binding var selected: Set<String>
    @State private var filter = ""

    private var shown: [TableInfo] {
        filter.isEmpty ? tables : tables.filter { $0.name.localizedCaseInsensitiveContains(filter) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                TextField("Filter tables", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                Spacer()
                Button("All") { selected = Set(tables.map(\.name)) }.controlSize(.small)
                Button("None") { selected = [] }.controlSize(.small)
                Text("\(selected.count) of \(tables.count)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .padding(.horizontal, DesignTokens.Spacing.sm)
            .frame(height: DesignTokens.Metrics.gridHeaderHeight)
            .background(.bar)
            Divider()
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, table in
                        HStack(spacing: DesignTokens.Spacing.sm) {
                            Toggle(
                                isOn: Binding(
                                    get: { selected.contains(table.name) },
                                    set: { on in
                                        if on { selected.insert(table.name) } else { selected.remove(table.name) }
                                    })
                            ) {
                                Label {
                                    Text(table.name).lineLimit(1)
                                } icon: {
                                    Image(systemName: table.kind.symbolName)
                                        .foregroundStyle(.secondary)
                                        .frame(width: DesignTokens.Metrics.iconWidth)
                                }
                            }
                            .toggleStyle(.checkbox)
                            Spacer()
                            if let rows = table.approximateRowCount {
                                Text("~\(TransferFormat.count(rows))")
                                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                            }
                            if let size = table.sizeBytes {
                                Text(TransferFormat.bytes(size))
                                    .font(.caption).foregroundStyle(.tertiary).monospacedDigit()
                                    .frame(width: 70, alignment: .trailing)
                            }
                        }
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                        .frame(height: DesignTokens.Metrics.gridRowHeight)
                        .background(
                            index.isMultiple(of: 2)
                                ? Color.clear : Color(nsColor: .alternatingContentBackgroundColors[1]))
                    }
                }
            }
            .frame(height: 200)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius).strokeBorder(Color.primary.opacity(0.1)))
    }
}
