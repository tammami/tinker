import DBCore
import DBGrid
import DBSQL
import Foundation
import SwiftUI

/// Chooses the value of a foreign-key cell by searching the referenced table.
///
/// A person editing `orders.customer_id` knows the customer's name, not its id. The model
/// searches a *label* column of the referenced table (picked automatically, changeable and
/// remembered) alongside the key, on the server, fifty rows at a time — never the whole
/// table. Selecting a row yields the referenced key columns, which the grid writes back
/// through its ordinary edit path, so auto-commit and the production gate still apply.
@MainActor
@Observable
public final class ReferencePickerModel {
    public struct Row: Identifiable {
        public let id: Int
        /// The key value(s) of this row, keyed by referenced column name.
        let key: [String: DBValue]
        let keyText: String
        let label: String?
    }

    let key: ForeignKeyInfo
    /// The value the cell holds now, for the header line; nil when it is NULL.
    let currentText: String?
    let isNullable: Bool

    public private(set) var rows: [Row] = []
    public private(set) var columns: [ColumnInfo] = []
    public private(set) var labelChoices: [String] = []
    public var label: String?
    public var searchText = ""
    public private(set) var isLoading = false
    public private(set) var hasMore = false
    public private(set) var errorText: String?
    public var selectedID: Int?

    private let session: ConnectionSession
    private let dialect: SQLDialect
    private let onPersistLabel: (String?) -> Void
    private var searchGeneration = 0
    private var page = 0

    public init(
        session: ConnectionSession,
        key: ForeignKeyInfo,
        dialect: SQLDialect,
        storedLabel: String?,
        currentText: String?,
        isNullable: Bool,
        onPersistLabel: @escaping (String?) -> Void
    ) {
        self.session = session
        self.key = key
        self.dialect = dialect
        self.label = storedLabel
        self.currentText = currentText
        self.isNullable = isNullable
        self.onPersistLabel = onPersistLabel
    }

    var referencedTableName: String { key.referencedTable.name }

    /// Reads the referenced table's columns and settles on a label column, then searches.
    public func start() async {
        if columns.isEmpty {
            let lookup = ReferenceLookup(session: session, key: key, dialect: dialect)
            do {
                columns = try await lookup.columns()
            } catch {
                errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
                return
            }
            labelChoices = ReferenceLookup.labelChoices(among: columns, keyColumns: key.referencedColumns)
            if label == nil || !(labelChoices.contains(label ?? "")) {
                label = ReferenceLookup.labelColumn(among: columns, keyColumns: key.referencedColumns)
            }
        }
        await reload()
    }

    /// Runs the search from the first page. Every call bumps a generation so a slow earlier
    /// query cannot overwrite a newer one's rows.
    public func reload() async {
        page = 0
        searchGeneration += 1
        let generation = searchGeneration
        isLoading = true
        defer { if generation == searchGeneration { isLoading = false } }
        do {
            let lookup = ReferenceLookup(session: session, key: key, dialect: dialect)
            let result = try await lookup.search(searchText, label: label, page: 0)
            guard generation == searchGeneration else { return }
            rows = Self.rows(from: result, key: key, label: label)
            hasMore = result.hasMore
            errorText = nil
            if !rows.contains(where: { $0.id == selectedID }) { selectedID = rows.first?.id }
        } catch {
            guard generation == searchGeneration else { return }
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
            rows = []
            hasMore = false
        }
    }

    /// Appends the next page to the rows already shown.
    public func loadMore() async {
        guard hasMore, !isLoading else { return }
        page += 1
        isLoading = true
        defer { isLoading = false }
        do {
            let lookup = ReferenceLookup(session: session, key: key, dialect: dialect)
            let result = try await lookup.search(searchText, label: label, page: page)
            let more = Self.rows(from: result, key: key, label: label, startingAt: rows.count)
            rows.append(contentsOf: more)
            hasMore = result.hasMore
        } catch {
            errorText = (error as? DBError)?.errorDescription ?? String(describing: error)
            hasMore = false
        }
    }

    /// Remembers a new label column and searches again through it.
    public func changeLabel(to name: String?) async {
        label = name
        onPersistLabel(name)
        await reload()
    }

    /// The chosen row's key columns, keyed by referenced column name; nil when nothing is
    /// selected.
    public var chosenKey: [String: DBValue]? {
        rows.first { $0.id == selectedID }?.key
    }

    private static func rows(
        from page: ReferenceLookup.Page, key: ForeignKeyInfo, label: String?, startingAt offset: Int = 0
    ) -> [Row] {
        let indexOf = Dictionary(uniqueKeysWithValues: page.columns.enumerated().map { ($1.name, $0) })
        return page.rows.enumerated().map { position, values in
            var keyValues: [String: DBValue] = [:]
            for column in key.referencedColumns {
                if let index = indexOf[column], values.indices.contains(index) { keyValues[column] = values[index] }
            }
            let keyText = key.referencedColumns.compactMap { keyValues[$0]?.text }.joined(separator: ", ")
            var labelText: String?
            if let label, let index = indexOf[label], values.indices.contains(index) {
                labelText = values[index].isNull ? nil : values[index].text
            }
            return Row(id: offset + position, key: keyValues, keyText: keyText, label: labelText)
        }
    }
}

/// The popover body: a search field, the matching rows, and Choose / Cancel.
public struct ReferencePickerView: View {
    @Bindable var model: ReferencePickerModel
    let onChoose: ([String: DBValue]) -> Void
    let onSetNull: () -> Void
    let onCancel: () -> Void

    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    public init(
        model: ReferencePickerModel,
        onChoose: @escaping ([String: DBValue]) -> Void,
        onSetNull: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.model = model
        self.onChoose = onChoose
        self.onSetNull = onSetNull
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 360, height: 440)
        .task { await model.start() }
    }

    private var header: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: Icon.search).foregroundStyle(.secondary)
                TextField("Search \(model.referencedTableName)", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onSubmit { choose() }
                    .onChange(of: model.searchText) { _, _ in scheduleSearch() }
                if !model.labelChoices.isEmpty {
                    Menu {
                        ForEach(model.labelChoices, id: \.self) { name in
                            Button {
                                Task { await model.changeLabel(to: name) }
                            } label: {
                                if model.label == name { Label(name, systemImage: "checkmark") } else { Text(name) }
                            }
                        }
                    } label: {
                        Image(systemName: Icon.settings)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Choose which column to search and show")
                }
            }
            if let current = model.currentText {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text("Current:").foregroundStyle(.tertiary)
                    Text(current).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .font(.caption)
            }
        }
        .padding(DesignTokens.Spacing.sm)
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var content: some View {
        if let error = model.errorText {
            InlineBanner(kind: .error, message: error) {}
            Spacer(minLength: 0)
        } else if model.rows.isEmpty, !model.isLoading {
            EmptyStateView(
                icon: Icon.lookup,
                title: model.searchText.isEmpty ? "No rows" : "No match",
                message: model.searchText.isEmpty ? nil : "Nothing in \(model.referencedTableName) matches."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.rows) { row in
                        rowView(row)
                        Divider()
                    }
                    if model.hasMore {
                        Button {
                            Task { await model.loadMore() }
                        } label: {
                            Text("Show 50 more…").font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.tint)
                        .padding(.vertical, DesignTokens.Spacing.sm)
                    }
                    if model.isLoading {
                        ProgressView().controlSize(.small).padding(DesignTokens.Spacing.sm)
                    }
                }
            }
        }
    }

    private func rowView(_ row: ReferencePickerModel.Row) -> some View {
        let isSelected = row.id == model.selectedID
        return HStack(spacing: DesignTokens.Spacing.sm) {
            Text(row.keyText)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(isSelected ? Color.white.opacity(0.85) : .secondary)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            Text(row.label ?? "—")
                .foregroundStyle(isSelected ? Color.white : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignTokens.Spacing.sm)
        .padding(.vertical, DesignTokens.Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.accentColor : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.selectedID = row.id
            choose()
        }
        .simultaneousGesture(TapGesture().onEnded { model.selectedID = row.id })
    }

    private var footer: some View {
        HStack(spacing: DesignTokens.Spacing.sm) {
            if model.isNullable {
                Button("Set NULL") {
                    onSetNull()
                }
                .controlSize(.small)
            }
            Spacer()
            Button("Cancel", role: .cancel) { onCancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.small)
            Button("Choose") { choose() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(model.chosenKey == nil)
        }
        .padding(DesignTokens.Spacing.sm)
    }

    /// Debounced: a keystroke schedules a search 200 ms out, and a newer keystroke cancels
    /// the pending one, so typing runs at most one query per pause.
    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            await model.reload()
        }
    }

    private func choose() {
        guard let key = model.chosenKey else { return }
        onChoose(key)
    }
}
