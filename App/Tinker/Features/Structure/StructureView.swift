import DBCore
import DBSQL
import SwiftUI

/// The Structure tab (SPEC §15b.1).
///
/// Read-only until Edit is pressed, so browsing a production schema cannot change it by a
/// stray keystroke, and nothing reaches the server without going through Preview.
public struct StructureView: View {
    @Bindable var controller: StructureController
    let isProduction: Bool

    @State private var pane: Pane = .columns
    @State private var ownPreviewPresented = false
    /// Set when Done opened the preview: a successful run then leaves editing.
    @State private var finishAfterRun = false
    /// A sheet that hosts the editor drives the preview from its own footer.
    private let externalPreview: Binding<Bool>?
    /// False hides Edit / Discard / Preview / Done, for a host that supplies its own.
    private let showsActions: Bool

    private var isPreviewPresented: Binding<Bool> {
        externalPreview ?? $ownPreviewPresented
    }

    enum Pane: String, CaseIterable, Identifiable {
        case columns = "Columns"
        case indexes = "Indexes"
        case foreignKeys = "Foreign Keys"
        case checks = "Checks"
        case triggers = "Triggers"
        case partitions = "Partitions"
        case table = "Table"

        var id: String { rawValue }
    }

    public init(
        controller: StructureController,
        isProduction: Bool = false,
        previewPresented: Binding<Bool>? = nil,
        showsActions: Bool = true
    ) {
        self.controller = controller
        self.isProduction = isProduction
        externalPreview = previewPresented
        self.showsActions = showsActions
    }

    public var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()

            if let error = controller.errorText {
                InlineBanner(kind: .error, message: error) { controller.clearError() }
                Divider()
            }
            if let status = controller.statusText {
                InlineBanner(kind: .success, message: status) { controller.clearStatus() }
                Divider()
            }

            if controller.edited == nil {
                EmptyStateView(
                    icon: Icon.structure,
                    title: controller.isLoading ? "Reading the structure…" : "No structure loaded"
                )
            } else {
                paneContent
            }
        }
        // Keyed on the table: SwiftUI reuses this view when the front tab changes, and an
        // unkeyed task would not run again, leaving the new tab reading "No structure
        // loaded" forever.
        // Collations are read by the column detail panel when it appears, not here.
        .task(id: controller.table.id) { await controller.load() }
        // A refresh reads the server again but never throws away what the user has typed.
        .refreshable { await controller.load(force: true, keepingEdits: true) }
        .sheet(isPresented: isPreviewPresented) {
            DDLPreviewView(
                statements: controller.pendingStatements,
                dialect: controller.dialect,
                isTransactional: controller.isTransactional,
                tableName: controller.table.name,
                isProduction: isProduction,
                onExecute: {
                    await controller.execute()
                    isPreviewPresented.wrappedValue = false
                    if finishAfterRun {
                        finishAfterRun = false
                        // Only when everything ran: a failed or partial run stays editable.
                        if !controller.hasPendingChanges, controller.errorText == nil {
                            controller.isEditing = false
                        }
                    }
                },
                onCancel: {
                    finishAfterRun = false
                    isPreviewPresented.wrappedValue = false
                }
            )
        }
    }

    // MARK: - Chrome

    private var toolbar: some View {
        PaneBar {
            // The pane picker gives way; the buttons keep their size and never wrap.
            Picker("Pane", selection: $pane) {
                ForEach(Pane.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 620)

            Spacer(minLength: DesignTokens.Spacing.sm)

            if showsActions {
                if controller.isEditing {
                    let count = controller.pendingStatements.count
                    if count > 0 {
                        Badge(text: "\(count) statement\(count == 1 ? "" : "s")", color: .orange)
                    } else {
                        Text("No changes").font(.caption).foregroundStyle(.secondary).lineLimit(1).fixedSize()
                    }

                    Button("Discard") { controller.discardChanges() }
                        .disabled(!controller.hasPendingChanges)
                        .fixedSize()

                    Button {
                        isPreviewPresented.wrappedValue = true
                    } label: {
                        Label("Preview…", systemImage: Icon.source)
                    }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(!controller.hasPendingChanges)
                    .buttonStyle(.borderedProminent)
                    .fixedSize()

                    // Done never drops work silently: with statements pending it shows
                    // them, and leaves editing only once they have run.
                    Button("Done") {
                        if controller.hasPendingChanges {
                            finishAfterRun = true
                            isPreviewPresented.wrappedValue = true
                        } else {
                            controller.isEditing = false
                        }
                    }
                    .help(
                        controller.hasPendingChanges
                            ? "Preview and run the changes, then stop editing" : "Stop editing"
                    )
                    .fixedSize()
                } else {
                    Button {
                        controller.isEditing = true
                    } label: {
                        Label("Edit", systemImage: Icon.edit)
                    }
                    .disabled(controller.edited == nil)
                    .fixedSize()
                }
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private var paneContent: some View {
        switch pane {
        case .columns:
            ColumnsPane(controller: controller)
        case .indexes:
            IndexesPane(controller: controller)
        case .foreignKeys:
            ForeignKeysPane(controller: controller)
        case .checks:
            ChecksPane(controller: controller)
        case .triggers:
            TriggersPane(controller: controller)
        case .partitions:
            PartitionsPane(controller: controller)
        case .table:
            TablePane(controller: controller)
        }
    }
}

// MARK: - Columns

/// The editable panes are built from rows rather than from `Table`.
///
/// SwiftUI's `Table` does not expose the controls inside its cells: they cannot be reached
/// by the accessibility system, which means VoiceOver cannot operate them and neither can
/// a UI test. A pane whose toggles cannot be clicked is not an editor, so these lay out
/// their own header and rows.
struct StructureGrid<Row: Identifiable, Content: View>: View {
    let headers: [(title: String, width: CGFloat?)]
    let rows: [Row]
    /// The row drawn in the accent colour, for panes that select.
    var selectedID: Row.ID? = nil
    let content: (Row, Int) -> Content

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, header in
                    Text(header.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: header.width, alignment: .leading)
                        .frame(maxWidth: header.width == nil ? .infinity : nil, alignment: .leading)
                        .padding(.horizontal, DesignTokens.Spacing.sm)
                }
            }
            .frame(height: DesignTokens.Metrics.gridHeaderHeight)
            .background(.bar)
            Divider()

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        content(row, index)
                            .padding(.vertical, 3)
                            .background(
                                row.id == selectedID
                                    ? Color.accentColor
                                    : index.isMultiple(of: 2)
                                        ? Color.clear
                                        : Color(nsColor: .alternatingContentBackgroundColors[1])
                            )
                        Divider()
                    }
                }
            }
        }
    }
}

/// A cell that fills its column, so every row lines up under its heading.
private struct Cell<Content: View>: View {
    let width: CGFloat?
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, DesignTokens.Spacing.sm)
    }
}

struct ColumnsPane: View {
    @Bindable var controller: StructureController

    /// Key, Name, Type, Length, Decimals, Not null, Auto, Default, Comment.
    private let widths: [CGFloat?] = [30, 170, 140, 64, 68, 60, 46, 140, nil]

    private var selectedIndex: Int? { controller.selectedColumnIndex }
    /// The column whose text field has keyboard focus. A click inside a field goes to
    /// AppKit, not to the row's tap gesture, so the selection follows focus instead.
    @FocusState private var focusedColumn: UUID?

    private func move(_ index: Int, by offset: Int) {
        guard var columns = controller.edited?.columns,
            columns.indices.contains(index),
            columns.indices.contains(index + offset)
        else { return }
        columns.swapAt(index, index + offset)
        controller.edited?.columns = columns
    }

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(
                headers: [
                    ("Key", widths[0]), ("Name", widths[1]), ("Type", widths[2]),
                    ("Length", widths[3]), ("Decimals", widths[4]), ("Not null", widths[5]),
                    ("Auto", widths[6]), ("Default", widths[7]), ("Comment", widths[8]),
                ],
                rows: controller.edited?.columns ?? [],
                selectedID: controller.selectedColumnID
            ) { column, index in
                row(column, index)
            }
            // Arrow keys walk the rows once the grid has focus; a click gives it focus.
            .focusable()
            .focusEffectDisabled()
            .onMoveCommand { direction in
                switch direction {
                case .up: controller.moveSelection(by: -1)
                case .down: controller.moveSelection(by: 1)
                default: break
                }
            }
            .onChange(of: focusedColumn) { _, focused in
                if let focused { controller.selectedColumnID = focused }
            }

            if let index = selectedIndex, let column = controller.edited?.columns[safe: index] {
                Divider()
                ColumnDetailPanel(controller: controller, index: index, column: column)
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Column",
                    removeTitle: "Remove the selected column",
                    onAdd: {
                        let column = ColumnDefinition(name: "new_column", type: defaultType)
                        controller.edited?.columns.append(column)
                        controller.selectedColumnID = column.id
                    },
                    onRemove: {
                        // The selected column goes; the one that takes its place is selected.
                        guard let index = selectedIndex ?? controller.edited?.columns.indices.last else { return }
                        controller.edited?.columns.remove(at: index)
                        let remaining = controller.edited?.columns ?? []
                        controller.selectedColumnID = remaining[safe: min(index, remaining.count - 1)]?.id
                    }
                ) {
                    // PostgreSQL has no syntax for moving a column, so the control is
                    // absent there rather than present and disabled.
                    if controller.dialect == .mysql {
                        BarDivider()
                        IconButton(icon: Icon.moveUp, label: "Move Up") {
                            if let index = selectedIndex { move(index, by: -1) }
                        }
                        .disabled((selectedIndex ?? 0) <= 0)

                        IconButton(icon: Icon.moveDown, label: "Move Down") {
                            if let index = selectedIndex { move(index, by: 1) }
                        }
                        .disabled(
                            selectedIndex == nil
                                || (selectedIndex ?? 0) >= (controller.edited?.columns.count ?? 0) - 1
                        )
                    }
                }
            }
        }
    }

    private var defaultType: String {
        controller.dialect == .mysql ? "varchar(255)" : "text"
    }

    private func row(_ column: ColumnDefinition, _ index: Int) -> some View {
        let isSelected = column.id == controller.selectedColumnID
        let spec = ColumnTypeSpec.parse(column.type)
        let choice = ColumnTypeCatalog.choice(named: spec.base, dialect: controller.dialect)
        return HStack(spacing: 0) {
            Cell(width: widths[0]) {
                Button {
                    controller.selectedColumnID = column.id
                    primaryKeyBinding(for: column.name).wrappedValue.toggle()
                } label: {
                    Image(systemName: Icon.key)
                        .foregroundStyle(
                            controller.edited?.primaryKey.contains(column.name) == true
                                ? (isSelected ? Color.white : Color.yellow)
                                : Color.clear
                        )
                        .frame(width: DesignTokens.Metrics.iconWidth)
                }
                .buttonStyle(.plain)
                .disabled(!controller.isEditing)
                .accessibilityLabel("\(column.name) primary key")
            }
            Cell(width: widths[1]) {
                field(index, column.id, \.name, placeholder: "name")
            }
            Cell(width: widths[2]) {
                typePicker(index, spec: spec)
            }
            Cell(width: widths[3]) {
                numberField(
                    index, column.id,
                    value: spec.length,
                    enabled: choice?.takesLength ?? true,
                    label: "\(column.name) length"
                ) { spec, value in
                    // The scale lives in the type text beside the precision; clearing the
                    // precision alone would lose it, so an empty length waits for a number.
                    guard value != nil || spec.decimals == nil else { return }
                    spec.length = value
                }
            }
            Cell(width: widths[4]) {
                numberField(
                    index, column.id,
                    value: spec.decimals,
                    enabled: choice?.takesDecimals ?? (spec.length != nil),
                    label: "\(column.name) decimals"
                ) { spec, value in spec.decimals = value }
            }
            Cell(width: widths[5]) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { !(controller.edited?.columns[safe: index]?.isNullable ?? true) },
                        set: {
                            controller.selectedColumnID = column.id
                            controller.edited?.columns[safe: index]?.isNullable = !$0
                        }
                    )
                )
                .labelsHidden()
                .disabled(!controller.isEditing)
                .accessibilityLabel("\(column.name) not null")
            }
            Cell(width: widths[6]) {
                Toggle(
                    "",
                    isOn: Binding(
                        get: { controller.edited?.columns[safe: index]?.isAutoIncrement ?? false },
                        set: {
                            controller.selectedColumnID = column.id
                            controller.edited?.columns[safe: index]?.isAutoIncrement = $0
                        }
                    )
                )
                .labelsHidden()
                .disabled(!controller.isEditing)
                .accessibilityLabel("\(column.name) auto increment")
            }
            Cell(width: widths[7]) {
                optionalField(index, column.id, \.defaultExpression, placeholder: "none")
            }
            Cell(width: widths[8]) {
                optionalField(index, column.id, \.comment, placeholder: "")
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .contentShape(Rectangle())
        // Simultaneous, so a click inside a field both focuses it and selects its row.
        .simultaneousGesture(TapGesture().onEnded { controller.selectedColumnID = column.id })
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    /// The base type from the dialect's list; a type the list does not carry stays as
    /// itself at the top, so nothing is ever rewritten just by being shown.
    @ViewBuilder
    private func typePicker(_ index: Int, spec: ColumnTypeSpec) -> some View {
        let choices = ColumnTypeCatalog.choices(for: controller.dialect)
        let base = spec.base.lowercased()
        let known = choices.contains { $0.name == base }
        BarPopUp(
            items: (known ? [] : [BarPopUp.Item(id: spec.base, title: spec.base)])
                + choices.map { BarPopUp.Item(id: $0.name, title: $0.name) },
            selection: Binding(
                get: { known ? base : spec.base },
                set: { newBase in
                    updateType(index) { spec in
                        guard spec.base.lowercased() != newBase.lowercased() else { return }
                        spec.base = newBase
                        let choice = ColumnTypeCatalog.choice(named: newBase, dialect: controller.dialect)
                        if let choice {
                            if !choice.takesLength { spec.length = nil }
                            if !choice.takesDecimals { spec.decimals = nil }
                        }
                        // A modifier belongs to the type it was read with: `unsigned` means
                        // nothing on a varchar, `without time zone` nothing on text. The
                        // new type starts with its own first choice, or none.
                        spec.suffix = choice?.suffixes.first ?? ""
                        spec.array = ""
                        if !spec.isEnumeration { spec.values = [] }
                    }
                }
            )
        )
        .disabled(!controller.isEditing)
        .accessibilityLabel("type")
    }

    private func numberField(
        _ index: Int, _ id: UUID, value: Int?, enabled: Bool, label: String,
        apply: @escaping (inout ColumnTypeSpec, Int?) -> Void
    ) -> some View {
        TextField(
            "",
            text: Binding(
                get: { value.map(String.init) ?? "" },
                set: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    guard trimmed.isEmpty || Int(trimmed) != nil else { return }
                    updateType(index) { spec in apply(&spec, Int(trimmed)) }
                }
            )
        )
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .monospacedDigit()
        .focused($focusedColumn, equals: id)
        .disabled(!controller.isEditing || !enabled)
        .accessibilityLabel(label)
    }

    /// Rewrites one column's type through its parts.
    private func updateType(_ index: Int, _ change: (inout ColumnTypeSpec) -> Void) {
        guard let column = controller.edited?.columns[safe: index] else { return }
        controller.selectedColumnID = column.id
        var spec = ColumnTypeSpec.parse(column.type)
        change(&spec)
        controller.edited?.columns[safe: index]?.type = spec.render(dialect: controller.dialect)
    }

    private func field(
        _ index: Int, _ id: UUID, _ path: WritableKeyPath<ColumnDefinition, String>, placeholder: String
    ) -> some View {
        TextField(
            placeholder,
            text: Binding(
                get: { controller.edited?.columns[safe: index]?[keyPath: path] ?? "" },
                set: { controller.edited?.columns[safe: index]?[keyPath: path] = $0 }
            )
        )
        .textFieldStyle(.plain)
        .focused($focusedColumn, equals: id)
        .disabled(!controller.isEditing)
    }

    private func optionalField(
        _ index: Int, _ id: UUID, _ path: WritableKeyPath<ColumnDefinition, String?>, placeholder: String
    ) -> some View {
        TextField(
            placeholder,
            text: Binding(
                get: { controller.edited?.columns[safe: index]?[keyPath: path] ?? "" },
                set: { controller.edited?.columns[safe: index]?[keyPath: path] = $0.isEmpty ? nil : $0 }
            )
        )
        .textFieldStyle(.plain)
        .focused($focusedColumn, equals: id)
        .disabled(!controller.isEditing)
    }

    /// Marking a column adds it to the key in the order it was marked, which is the order
    /// the key is written in.
    private func primaryKeyBinding(for name: String) -> Binding<Bool> {
        Binding(
            get: { controller.edited?.primaryKey.contains(name) ?? false },
            set: { isOn in
                guard var definition = controller.edited else { return }
                if isOn {
                    if !definition.primaryKey.contains(name) { definition.primaryKey.append(name) }
                } else {
                    definition.primaryKey.removeAll { $0 == name }
                }
                controller.edited = definition
            }
        )
    }
}

// MARK: - Column detail

/// The selected column's settings that do not fit a grid cell: enum members, the default,
/// the character set and collation.
struct ColumnDetailPanel: View {
    @Bindable var controller: StructureController
    let index: Int
    let column: ColumnDefinition

    private var spec: ColumnTypeSpec { ColumnTypeSpec.parse(column.type) }
    private var isEditing: Bool { controller.isEditing }
    private var dialect: SQLDialect { controller.dialect }

    /// PostgreSQL enum columns name a type whose members live in the catalog.
    private var isPostgresEnum: Bool { dialect == .postgresql && column.enumLabels != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            if spec.isEnumeration || isPostgresEnum {
                FieldRow(label: "Enum Value") {
                    HStack(spacing: DesignTokens.Spacing.xs) {
                        TextField(
                            "'a','b'",
                            text: Binding(
                                get: { membersText },
                                set: { text in
                                    updateType { $0.values = ColumnTypeSpec.parseMembers(text) }
                                }
                            )
                        )
                        .disabled(!isEditing || isPostgresEnum)
                        .accessibilityLabel("enum values")
                        Button("…") { controller.isEnumEditorPresented = true }
                            .help("Edit the members one per row")
                            .accessibilityLabel("Edit enum values")
                    }
                }
                if isPostgresEnum {
                    FieldRow(label: "") {
                        Text("Members belong to the type \(spec.base); change them with ALTER TYPE.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let choice = ColumnTypeCatalog.choice(named: spec.base, dialect: dialect), !choice.suffixes.isEmpty {
                // `unsigned` on MySQL numbers, the time zone on PostgreSQL times: the words
                // the type takes after its length, offered rather than typed.
                FieldRow(label: "Modifier") {
                    BarPopUp(
                        items: choice.suffixes.map { BarPopUp.Item(id: $0, title: $0.isEmpty ? "none" : $0) },
                        selection: Binding(
                            get: { spec.suffix.lowercased() },
                            set: { value in updateType { $0.suffix = value } }
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .disabled(!isEditing)
                    .accessibilityLabel("type modifier")
                }
            }

            FieldRow(label: "Default Value") {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    TextField(
                        "none",
                        text: Binding(
                            get: { column.defaultExpression ?? "" },
                            set: { controller.edited?.columns[safe: index]?.defaultExpression = $0.isEmpty ? nil : $0 }
                        )
                    )
                    .disabled(!isEditing)
                    .accessibilityLabel("default value")
                    Menu {
                        Button("No default") { setDefault(nil) }
                        Button("NULL") { setDefault("NULL") }
                        Button("Empty string") { setDefault("''") }
                        Button("CURRENT_TIMESTAMP") { setDefault("CURRENT_TIMESTAMP") }
                    } label: {
                        Image(systemName: Icon.chevronDown)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .disabled(!isEditing)
                    .accessibilityLabel("default value choices")
                }
            }

            if dialect == .mysql {
                FieldRow(label: "Character Set") {
                    BarPopUp(
                        items: [BarPopUp.Item(id: "", title: "default")]
                            + controller.characterSets.map { BarPopUp.Item(id: $0, title: $0) },
                        selection: Binding(
                            get: { column.characterSet ?? "" },
                            set: { value in
                                controller.edited?.columns[safe: index]?.characterSet = value.isEmpty ? nil : value
                                // A collation of another character set cannot stay.
                                if let collation = column.collation,
                                    !collation.hasPrefix(value), !value.isEmpty
                                {
                                    controller.edited?.columns[safe: index]?.collation = nil
                                }
                            }
                        )
                    )
                    .frame(maxWidth: .infinity)
                    .disabled(!isEditing)
                    .accessibilityLabel("character set")
                }
            }

            FieldRow(label: "Collation") {
                BarPopUp(
                    items: [BarPopUp.Item(id: "", title: "default")]
                        + collationChoices.map { BarPopUp.Item(id: $0.name, title: $0.name) },
                    selection: Binding(
                        get: { column.collation ?? "" },
                        set: { controller.edited?.columns[safe: index]?.collation = $0.isEmpty ? nil : $0 }
                    )
                )
                .frame(maxWidth: .infinity)
                .disabled(!isEditing)
                .accessibilityLabel("collation")
            }
        }
        .controlSize(.small)
        .padding(DesignTokens.Spacing.lg)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
        .task(id: controller.table.id) { await controller.loadCollationsIfNeeded() }
        .sheet(isPresented: $controller.isEnumEditorPresented) {
            EnumValuesSheet(
                values: isPostgresEnum ? (column.enumLabels ?? []) : spec.values,
                typeName: spec.base,
                readOnlyNote: isPostgresEnum
                    ? "Members of a PostgreSQL type are changed with ALTER TYPE, not here."
                    : isEditing ? nil : "Press Edit on the Structure tab to change the members.",
                onSave: { values in updateType { $0.values = values } }
            )
        }
    }

    private var membersText: String {
        if isPostgresEnum {
            return (column.enumLabels ?? []).map { SQLLiteral.quoteString($0, dialect: dialect) }.joined(separator: ",")
        }
        return spec.membersText(dialect: dialect)
    }

    /// The collations of the chosen character set, or all of them when none is chosen.
    private var collationChoices: [CollationInfo] {
        guard let set = column.characterSet, !set.isEmpty else { return controller.collations }
        return controller.collations.filter { $0.characterSet == set }
    }

    private func setDefault(_ value: String?) {
        controller.edited?.columns[safe: index]?.defaultExpression = value
    }

    private func updateType(_ change: (inout ColumnTypeSpec) -> Void) {
        var spec = spec
        change(&spec)
        controller.edited?.columns[safe: index]?.type = spec.render(dialect: dialect)
    }
}

/// The members of an enum or set, one per row, the way Navicat edits them.
struct EnumValuesSheet: View {
    @State var values: [String]
    let typeName: String
    /// Why the members cannot be changed here, or nil when they can.
    let readOnlyNote: String?
    let onSave: ([String]) -> Void

    private var isReadOnly: Bool { readOnlyNote != nil }

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Int?
    @FocusState private var focusedRow: Int?

    var body: some View {
        SheetFrame(
            title: "\(typeName.capitalized) Values",
            icon: Icon.column,
            subtitle: readOnlyNote ?? "One member per row, in the order they are stored.",
            width: DesignTokens.Metrics.sheetWidth,
            contentInset: 0
        ) {
            VStack(spacing: 0) {
                HStack {
                    Text("Values")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .frame(height: DesignTokens.Metrics.gridHeaderHeight)
                .background(.bar)
                Divider()
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(values.indices, id: \.self) { index in
                            let isSelected = selected == index
                            TextField(
                                "value",
                                text: Binding(
                                    get: { values[safe: index] ?? "" },
                                    set: { if values.indices.contains(index) { values[index] = $0 } }
                                )
                            )
                            .textFieldStyle(.plain)
                            .focused($focusedRow, equals: index)
                            .disabled(isReadOnly)
                            .padding(.horizontal, DesignTokens.Spacing.md)
                            .padding(.vertical, DesignTokens.Spacing.xs)
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .background(isSelected ? Color.accentColor : Color.clear)
                            .contentShape(Rectangle())
                            .simultaneousGesture(TapGesture().onEnded { selected = index })
                            Divider()
                        }
                    }
                }
                .frame(minHeight: 220, maxHeight: 320)
                Divider()
                HStack(spacing: DesignTokens.Spacing.xs) {
                    IconButton(icon: Icon.add, label: "Add value") {
                        values.append("")
                        selected = values.count - 1
                        focusedRow = selected
                    }
                    IconButton(icon: Icon.remove, label: "Remove value") {
                        guard let selected, values.indices.contains(selected) else { return }
                        values.remove(at: selected)
                        self.selected = values.isEmpty ? nil : min(selected, values.count - 1)
                    }
                    .disabled(selected == nil)
                    Spacer()
                }
                .disabled(isReadOnly)
                .padding(.horizontal, DesignTokens.Spacing.md)
                .padding(.vertical, DesignTokens.Spacing.xs)
            }
        } footer: {
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("OK") {
                onSave(values.filter { !$0.isEmpty })
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .disabled(isReadOnly)
        }
    }
}

// MARK: - Indexes

struct IndexesPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [200, nil, 110, 60, 200]

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(
                headers: [
                    ("Name", widths[0]), ("Columns", widths[1]), ("Method", widths[2]),
                    ("Unique", widths[3]), ("Where", widths[4]),
                ],
                rows: controller.edited?.indexes ?? []
            ) { index, position in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        TextField(
                            "name",
                            text: Binding(
                                get: { controller.edited?.indexes[safe: position]?.name ?? "" },
                                set: { controller.edited?.indexes[safe: position]?.name = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField(
                            "column, column",
                            text: Binding(
                                get: {
                                    (controller.edited?.indexes[safe: position]?.columns ?? [])
                                        .map(\.name).joined(separator: ", ")
                                },
                                set: { text in
                                    controller.edited?.indexes[safe: position]?.columns =
                                        text
                                        .split(separator: ",")
                                        .map { IndexColumn(name: $0.trimmingCharacters(in: .whitespaces)) }
                                        .filter { !$0.name.isEmpty }
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[2]) {
                        Picker(
                            "",
                            selection: Binding(
                                get: {
                                    controller.edited?.indexes[safe: position]?.method
                                        ?? methods.first ?? "btree"
                                },
                                set: { controller.edited?.indexes[safe: position]?.method = $0 }
                            )
                        ) {
                            ForEach(methods, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(index.name) method")
                    }
                    Cell(width: widths[3]) {
                        Toggle(
                            "",
                            isOn: Binding(
                                get: { controller.edited?.indexes[safe: position]?.isUnique ?? false },
                                set: { controller.edited?.indexes[safe: position]?.isUnique = $0 }
                            )
                        )
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(index.name) unique")
                    }
                    Cell(width: widths[4]) {
                        TextField(
                            "predicate",
                            text: Binding(
                                get: { controller.edited?.indexes[safe: position]?.predicate ?? "" },
                                set: {
                                    controller.edited?.indexes[safe: position]?.predicate =
                                        $0.isEmpty ? nil : $0
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        // A partial index is PostgreSQL's and SQLite's; MySQL has no equivalent.
                        .disabled(!controller.isEditing || controller.dialect == .mysql)
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Index",
                    onAdd: {
                        let count = (controller.edited?.indexes.count ?? 0) + 1
                        controller.edited?.indexes.append(
                            IndexDefinition(
                                name: "\(controller.table.name)_idx_\(count)",
                                columns: [],
                                method: methods.first
                            ))
                    },
                    onRemove: {
                        guard controller.edited?.indexes.isEmpty == false else { return }
                        controller.edited?.indexes.removeLast()
                    }
                )
            }
        }
    }

    /// What each engine actually offers, rather than a list with half of it disabled.
    private var methods: [String] {
        switch controller.dialect {
        case .postgresql: ["btree", "hash", "gin", "gist", "brin", "spgist"]
        case .mysql: ["btree", "hash", "fulltext", "spatial"]
        // Every SQLite index is a b-tree; there is nothing to choose.
        case .sqlite: ["btree"]
        }
    }
}

// MARK: - Foreign keys

struct ForeignKeysPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [170, 150, 150, 150, 130, 130]

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(
                headers: [
                    ("Name", widths[0]), ("Columns", widths[1]), ("References", widths[2]),
                    ("Ref columns", widths[3]), ("On update", widths[4]), ("On delete", widths[5]),
                ],
                rows: controller.edited?.foreignKeys ?? []
            ) { key, position in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        TextField(
                            "name",
                            text: Binding(
                                get: { controller.edited?.foreignKeys[safe: position]?.name ?? "" },
                                set: { controller.edited?.foreignKeys[safe: position]?.name = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField(
                            "column",
                            text: Binding(
                                get: {
                                    (controller.edited?.foreignKeys[safe: position]?.columns ?? [])
                                        .joined(separator: ", ")
                                },
                                set: {
                                    controller.edited?.foreignKeys[safe: position]?.columns =
                                        Self.splitNames($0)
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[2]) {
                        TextField(
                            "table",
                            text: Binding(
                                get: {
                                    controller.edited?.foreignKeys[safe: position]?
                                        .referencedTable.name ?? ""
                                },
                                set: { name in
                                    guard
                                        let old = controller.edited?.foreignKeys[safe: position]?
                                            .referencedTable
                                    else { return }
                                    controller.edited?.foreignKeys[safe: position]?.referencedTable =
                                        TableRef(database: old.database, schema: old.schema, name: name)
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[3]) {
                        TextField(
                            "column",
                            text: Binding(
                                get: {
                                    (controller.edited?.foreignKeys[safe: position]?
                                        .referencedColumns ?? []).joined(separator: ", ")
                                },
                                set: {
                                    controller.edited?.foreignKeys[safe: position]?
                                        .referencedColumns = Self.splitNames($0)
                                }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[4]) {
                        actionPicker(position, keyName: key.name, isUpdate: true)
                    }
                    Cell(width: widths[5]) {
                        actionPicker(position, keyName: key.name, isUpdate: false)
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Foreign Key",
                    onAdd: {
                        let table = controller.table
                        let count = (controller.edited?.foreignKeys.count ?? 0) + 1
                        controller.edited?.foreignKeys.append(
                            ForeignKeyDefinition(
                                name: "\(table.name)_fk_\(count)",
                                columns: [],
                                referencedTable: table,
                                referencedColumns: []
                            ))
                    },
                    onRemove: {
                        guard controller.edited?.foreignKeys.isEmpty == false else { return }
                        controller.edited?.foreignKeys.removeLast()
                    }
                )
            }
        }
    }

    private func actionPicker(_ position: Int, keyName: String, isUpdate: Bool) -> some View {
        Picker(
            "",
            selection: Binding(
                get: {
                    let key = controller.edited?.foreignKeys[safe: position]
                    return (isUpdate ? key?.onUpdate : key?.onDelete) ?? .noAction
                },
                set: { action in
                    if isUpdate {
                        controller.edited?.foreignKeys[safe: position]?.onUpdate = action
                    } else {
                        controller.edited?.foreignKeys[safe: position]?.onDelete = action
                    }
                }
            )
        ) {
            ForEach(ForeignKeyAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
        }
        .labelsHidden()
        .disabled(!controller.isEditing)
        .accessibilityLabel("\(keyName) on \(isUpdate ? "update" : "delete")")
    }

    static func splitNames(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Checks

struct ChecksPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [220, nil]

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(
                headers: [("Name", widths[0]), ("Expression", widths[1])],
                rows: controller.edited?.checks ?? []
            ) { _, position in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        TextField(
                            "name",
                            text: Binding(
                                get: { controller.edited?.checks[safe: position]?.name ?? "" },
                                set: { controller.edited?.checks[safe: position]?.name = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        TextField(
                            "expression",
                            text: Binding(
                                get: { controller.edited?.checks[safe: position]?.expression ?? "" },
                                set: { controller.edited?.checks[safe: position]?.expression = $0 }
                            )
                        )
                        .textFieldStyle(.plain)
                        .disabled(!controller.isEditing)
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Check",
                    onAdd: {
                        let count = (controller.edited?.checks.count ?? 0) + 1
                        controller.edited?.checks.append(
                            CheckDefinition(
                                name: "\(controller.table.name)_check_\(count)", expression: ""
                            ))
                    },
                    onRemove: {
                        guard controller.edited?.checks.isEmpty == false else { return }
                        controller.edited?.checks.removeLast()
                    }
                )
            }
        }
    }
}

// MARK: - Triggers

struct TriggersPane: View {
    @Bindable var controller: StructureController

    private var isPostgres: Bool { controller.dialect == .postgresql }

    private var widths: [CGFloat?] {
        isPostgres ? [170, 110, 150, 120, 170, nil] : [170, 110, 110, nil]
    }

    var body: some View {
        VStack(spacing: 0) {
            StructureGrid(headers: headers, rows: controller.edited?.triggers ?? []) { trigger, position in
                HStack(spacing: 0) {
                    Cell(width: widths[0]) {
                        TextField("name", text: text(position, \.name))
                            .textFieldStyle(.plain)
                            .disabled(!controller.isEditing)
                    }
                    Cell(width: widths[1]) {
                        Picker("", selection: value(position, \.timing, .before)) {
                            ForEach(timings, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .disabled(!controller.isEditing)
                        .accessibilityLabel("\(trigger.name) timing")
                    }
                    Cell(width: widths[2]) { eventsField(position) }

                    if isPostgres {
                        Cell(width: widths[3]) {
                            Picker("", selection: value(position, \.isRowLevel, true)) {
                                Text("ROW").tag(true)
                                Text("STATEMENT").tag(false)
                            }
                            .labelsHidden()
                            .disabled(!controller.isEditing)
                            .accessibilityLabel("\(trigger.name) level")
                        }
                        Cell(width: widths[4]) {
                            TextField("when", text: optionalText(position, \.condition))
                                .textFieldStyle(.plain)
                                .disabled(!controller.isEditing)
                        }
                        Cell(width: widths[5]) {
                            TextField("schema.function()", text: optionalText(position, \.functionCall))
                                .textFieldStyle(.plain)
                                .disabled(!controller.isEditing)
                        }
                    } else {
                        Cell(width: widths[3]) {
                            TextField("body", text: optionalText(position, \.body))
                                .textFieldStyle(.plain)
                                .disabled(!controller.isEditing)
                        }
                    }
                }
            }

            if controller.isEditing {
                PaneFooter(
                    addTitle: "Add Trigger",
                    onAdd: {
                        let count = (controller.edited?.triggers.count ?? 0) + 1
                        controller.edited?.triggers.append(
                            TriggerInfo(
                                name: "\(controller.table.name)_trg_\(count)",
                                timing: .before,
                                events: [.update],
                                body: isPostgres ? nil : "SET NEW.id = NEW.id",
                                functionCall: isPostgres ? "" : nil
                            ))
                    },
                    onRemove: {
                        guard controller.edited?.triggers.isEmpty == false else { return }
                        controller.edited?.triggers.removeLast()
                    }
                )
            }
        }
    }

    private var headers: [(title: String, width: CGFloat?)] {
        isPostgres
            ? [
                ("Name", widths[0]), ("Timing", widths[1]), ("Events", widths[2]),
                ("Level", widths[3]), ("When", widths[4]), ("Function", widths[5]),
            ]
            : [
                ("Name", widths[0]), ("Timing", widths[1]), ("Event", widths[2]),
                ("Body", widths[3]),
            ]
    }

    /// `INSTEAD OF` is PostgreSQL's and applies to views, so MySQL is not offered it.
    private var timings: [TriggerTiming] {
        isPostgres ? [.before, .after, .insteadOf] : [.before, .after]
    }

    /// A PostgreSQL trigger can fire on several events; MySQL's fires on exactly one, so
    /// anything past the first is dropped rather than written into SQL the server rejects.
    private func eventsField(_ position: Int) -> some View {
        TextField(
            isPostgres ? "INSERT, UPDATE" : "UPDATE",
            text: Binding(
                get: {
                    (controller.edited?.triggers[safe: position]?.events ?? [])
                        .map(\.rawValue).joined(separator: ", ")
                },
                set: { text in
                    let events = text.split(separator: ",").compactMap {
                        TriggerEvent(rawValue: $0.trimmingCharacters(in: .whitespaces).uppercased())
                    }
                    controller.edited?.triggers[safe: position]?.events =
                        isPostgres ? events : Array(events.prefix(1))
                }
            )
        )
        .textFieldStyle(.plain)
        .disabled(!controller.isEditing)
    }

    private func text(_ position: Int, _ path: WritableKeyPath<TriggerInfo, String>) -> Binding<String> {
        Binding(
            get: { controller.edited?.triggers[safe: position]?[keyPath: path] ?? "" },
            set: { controller.edited?.triggers[safe: position]?[keyPath: path] = $0 }
        )
    }

    private func optionalText(
        _ position: Int, _ path: WritableKeyPath<TriggerInfo, String?>
    ) -> Binding<String> {
        Binding(
            get: { controller.edited?.triggers[safe: position]?[keyPath: path] ?? "" },
            set: { controller.edited?.triggers[safe: position]?[keyPath: path] = $0.isEmpty ? nil : $0 }
        )
    }

    private func value<T>(
        _ position: Int, _ path: WritableKeyPath<TriggerInfo, T>, _ fallback: T
    ) -> Binding<T> {
        Binding(
            get: { controller.edited?.triggers[safe: position]?[keyPath: path] ?? fallback },
            set: { controller.edited?.triggers[safe: position]?[keyPath: path] = $0 }
        )
    }
}

// MARK: - Partitions

struct PartitionsPane: View {
    @Bindable var controller: StructureController

    private let widths: [CGFloat?] = [220, nil, 110]

    var body: some View {
        if let partitioning = controller.edited?.partitioning {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    Label(partitioning.strategy.rawValue, systemImage: Icon.partition)
                        .font(.callout.weight(.medium))
                    Text(partitioning.key).font(.system(.callout, design: .monospaced))
                    Spacer()
                    // Changing either means rebuilding the table, which is a migration
                    // rather than an edit (SPEC §15b.1).
                    Text("Strategy and key are fixed")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, DesignTokens.Spacing.md)
                .frame(height: DesignTokens.Metrics.barHeight)
                Divider()

                StructureGrid(
                    headers: [("Partition", widths[0]), ("Bound", widths[1]), ("Rows", widths[2])],
                    rows: partitioning.partitions
                ) { partition, position in
                    HStack(spacing: 0) {
                        Cell(width: widths[0]) {
                            TextField(
                                "name",
                                text: Binding(
                                    get: { self.partition(position)?.name ?? "" },
                                    set: { self.setPartition(position, name: $0, bound: nil) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .disabled(!controller.isEditing)
                        }
                        Cell(width: widths[1]) {
                            TextField(
                                boundPlaceholder,
                                text: Binding(
                                    get: { self.partition(position)?.bound ?? "" },
                                    set: { self.setPartition(position, name: nil, bound: $0) }
                                )
                            )
                            .textFieldStyle(.plain)
                            .disabled(!controller.isEditing)
                        }
                        Cell(width: widths[2]) {
                            Text(partition.approximateRowCount.map { "~\($0)" } ?? "—")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if controller.isEditing {
                    PaneFooter(
                        addTitle: "Add Partition",
                        onAdd: {
                            let count = partitioning.partitions.count + 1
                            appendPartition(
                                PartitionInfo(
                                    name: "\(controller.table.name)_p\(count)",
                                    bound: boundPlaceholder
                                ))
                        },
                        onRemove: { removeLastPartition() }
                    )
                }
            }
        } else {
            EmptyStateView(
                icon: Icon.partition,
                title: "Not partitioned",
                message: "Partitioning is declared when the table is created."
            )
        }
    }

    /// Each engine spells a bound its own way, so the placeholder shows the right shape.
    private var boundPlaceholder: String {
        controller.dialect == .postgresql ? "FOR VALUES FROM (0) TO (10)" : "VALUES LESS THAN (10)"
    }

    private func partition(_ position: Int) -> PartitionInfo? {
        controller.edited?.partitioning?.partitions[safe: position]
    }

    private func setPartition(_ position: Int, name: String?, bound: String?) {
        guard let partitioning = controller.edited?.partitioning,
            let existing = partitioning.partitions[safe: position]
        else { return }
        var partitions = partitioning.partitions
        partitions[position] = PartitionInfo(
            name: name ?? existing.name,
            bound: bound ?? existing.bound,
            approximateRowCount: existing.approximateRowCount
        )
        controller.edited?.partitioning = PartitioningInfo(
            strategy: partitioning.strategy, key: partitioning.key,
            partitions: partitions, partitionCount: partitioning.partitionCount
        )
    }

    private func appendPartition(_ partition: PartitionInfo) {
        guard let partitioning = controller.edited?.partitioning else { return }
        controller.edited?.partitioning = PartitioningInfo(
            strategy: partitioning.strategy, key: partitioning.key,
            partitions: partitioning.partitions + [partition],
            partitionCount: partitioning.partitionCount
        )
    }

    private func removeLastPartition() {
        guard let partitioning = controller.edited?.partitioning,
            !partitioning.partitions.isEmpty
        else { return }
        controller.edited?.partitioning = PartitioningInfo(
            strategy: partitioning.strategy, key: partitioning.key,
            partitions: partitioning.partitions.dropLast(),
            partitionCount: partitioning.partitionCount
        )
    }
}

// MARK: - Table

struct TablePane: View {
    @Bindable var controller: StructureController

    var body: some View {
        Form {
            Section("Table") {
                TextField(
                    "Name",
                    text: Binding(
                        get: { controller.edited?.ref.name ?? "" },
                        set: { name in
                            guard var definition = controller.edited else { return }
                            let old = definition.ref
                            definition.ref = TableRef(
                                database: old.database, schema: old.schema, name: name
                            )
                            controller.edited = definition
                        }
                    )
                )
                .disabled(!controller.isEditing)

                TextField(
                    "Comment",
                    text: Binding(
                        get: { controller.edited?.comment ?? "" },
                        set: { controller.edited?.comment = $0.isEmpty ? nil : $0 }
                    )
                )
                .disabled(!controller.isEditing)
            }

            if controller.dialect == .mysql {
                Section("Storage") {
                    TextField("Engine", text: optionBinding(\.engine))
                        .disabled(!controller.isEditing)
                    TextField("Character set", text: optionBinding(\.characterSet))
                        .disabled(!controller.isEditing)
                    TextField("Collation", text: optionBinding(\.collation))
                        .disabled(!controller.isEditing)
                }
            } else {
                Section("Storage") {
                    TextField("Tablespace", text: optionBinding(\.tablespace))
                        .disabled(!controller.isEditing)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func optionBinding(_ path: WritableKeyPath<TableOptions, String?>) -> Binding<String> {
        Binding(
            get: { controller.edited?.options[keyPath: path] ?? "" },
            set: { controller.edited?.options[keyPath: path] = $0.isEmpty ? nil : $0 }
        )
    }
}

// MARK: - Shared

/// Add and remove, the two buttons every pane needs.
struct PaneFooter<Extra: View>: View {
    let addTitle: String
    var removeTitle = "Remove the last row"
    let onAdd: () -> Void
    let onRemove: () -> Void
    @ViewBuilder var extra: Extra

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            PaneBar {
                Button(action: onAdd) { Label(addTitle, systemImage: Icon.add) }
                IconButton(icon: Icon.remove, label: removeTitle, action: onRemove)
                extra
                Spacer()
            }
            .controlSize(.small)
        }
    }
}

extension PaneFooter where Extra == EmptyView {
    init(addTitle: String, onAdd: @escaping () -> Void, onRemove: @escaping () -> Void) {
        self.init(addTitle: addTitle, onAdd: onAdd, onRemove: onRemove) { EmptyView() }
    }
}

/// Indexing that returns nil rather than trapping, so a row that vanished while the user
/// was editing it cannot crash the pane.
extension Array {
    subscript(safe index: Int) -> Element? {
        get { indices.contains(index) ? self[index] : nil }
        set {
            guard indices.contains(index), let newValue else { return }
            self[index] = newValue
        }
    }
}
