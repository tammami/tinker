import DBCore
import DBGrid
import SwiftUI
import UniformTypeIdentifiers

/// The right-side panel: the focused cell in full, or the whole row as a form.
public struct CellInspectorView: View {
    let columns: [ColumnMeta]
    let focusedColumn: Int
    let focusedRow: Int
    let rowValues: [DBValue]?
    let rowState: CellChangeState
    let isEditable: Bool
    let hasReference: (Int) -> Bool
    let onCommit: (Int, String) -> Void
    let onSetNull: (Int) -> Void
    let onFollow: (Int) -> Void
    /// Whether the grid would accept a write to this column. A query result may carry
    /// columns that belong to no writable table; they are shown, not offered for editing.
    var isColumnEditable: (Int) -> Bool = { _ in true }
    /// Whether a column takes part in a foreign key, so its value can be picked.
    var canPickReference: (Int) -> Bool = { _ in false }
    /// Opens the foreign-key picker for a column.
    var onPickReference: (Int) -> Void = { _ in }

    enum Pane: String, CaseIterable, Identifiable {
        case cell = "Cell"
        case row = "Row"
        var id: String { rawValue }
        var icon: String { self == .cell ? Icon.inspector : Icon.form }
    }

    @State private var pane: Pane = .cell

    private var column: ColumnMeta? {
        columns.indices.contains(focusedColumn) ? columns[focusedColumn] : nil
    }

    private var value: DBValue? {
        guard let rowValues, rowValues.indices.contains(focusedColumn) else { return nil }
        return rowValues[focusedColumn]
    }

    public var body: some View {
        VStack(spacing: 0) {
            PaneBar {
                Picker("Pane", selection: $pane) {
                    ForEach(Pane.allCases) { pane in
                        Label(pane.rawValue, systemImage: pane.icon).tag(pane)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                Spacer()
                if rowState != .unchanged {
                    Badge(text: rowState.label, color: rowState.color)
                }
            }
            Divider()
            switch pane {
            case .cell: cellPane
            case .row: rowPane
            }
        }
        .frame(width: DesignTokens.Metrics.inspectorWidth)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Cell

    @ViewBuilder
    private var cellPane: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
            if let column {
                HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(column.name).font(.headline).lineLimit(1)
                        HStack(spacing: DesignTokens.Spacing.xs) {
                            Text(column.nativeTypeName).font(.caption).foregroundStyle(.secondary)
                            if column.isPrimaryKey == true { Badge(text: "PK", color: .accentColor) }
                            if column.isNullable == false { Badge(text: "NOT NULL") }
                        }
                    }
                    Spacer()
                    if isEditable, isColumnEditable(focusedColumn), canPickReference(focusedColumn) {
                        Button {
                            onPickReference(focusedColumn)
                        } label: {
                            Label("Choose…", systemImage: Icon.lookup)
                        }
                        .controlSize(.small)
                        .help("Pick this value from the referenced table")
                    }
                    if hasReference(focusedColumn) {
                        Button {
                            onFollow(focusedColumn)
                        } label: {
                            Label("Go to", systemImage: Icon.goTo)
                        }
                        .controlSize(.small)
                        .help("Open the row this value refers to")
                    }
                }
                CellValueEditor(
                    columnName: column.name,
                    kind: column.kind,
                    value: value,
                    isEditable: isEditable && isColumnEditable(focusedColumn),
                    onCommit: { onCommit(focusedColumn, $0) },
                    onSetNull: { onSetNull(focusedColumn) }
                )
            } else {
                EmptyStateView(
                    icon: Icon.inspector, title: "No cell selected",
                    message: "Click a cell in the grid to see its full value here.")
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Row

    /// Every column of the focused row, stacked, each one editable in place.
    @ViewBuilder
    private var rowPane: some View {
        if let rowValues {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    Text("Row \(focusedRow + 1)").font(.headline)
                    ForEach(Array(columns.enumerated()), id: \.element.id) { index, column in
                        RowFormField(
                            column: column,
                            value: rowValues.indices.contains(index) ? rowValues[index] : .null,
                            isEditable: isEditable && isColumnEditable(index),
                            hasReference: hasReference(index),
                            canPick: canPickReference(index),
                            onCommit: { onCommit(index, $0) },
                            onSetNull: { onSetNull(index) },
                            onFollow: { onFollow(index) },
                            onPick: { onPickReference(index) }
                        )
                    }
                }
                .padding(DesignTokens.Spacing.md)
            }
        } else {
            EmptyStateView(
                icon: Icon.form, title: "No row selected",
                message: "Click a row in the grid to edit it as a form.")
        }
    }
}

extension CellChangeState {
    var label: String {
        switch self {
        case .unchanged: ""
        case .edited: "EDITED"
        case .inserted: "NEW"
        case .deleted: "DELETED"
        }
    }

    var color: Color {
        switch self {
        case .unchanged: .secondary
        case .edited: .yellow
        case .inserted: .green
        case .deleted: .red
        }
    }
}

/// One column in the row form: label, the value, and the actions the value allows.
private struct RowFormField: View {
    let column: ColumnMeta
    let value: DBValue
    let isEditable: Bool
    let hasReference: Bool
    var canPick: Bool = false
    let onCommit: (String) -> Void
    let onSetNull: () -> Void
    let onFollow: () -> Void
    var onPick: () -> Void = {}

    @State private var draft = ""
    @State private var isNull = false
    @State private var isPickerShown = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Text(column.name).font(.caption.weight(.semibold))
                Text(column.nativeTypeName).font(.caption2).foregroundStyle(.tertiary)
                if column.isPrimaryKey == true { Badge(text: "PK", color: .accentColor) }
                Spacer()
                if isEditable, canPick {
                    IconButton(icon: Icon.lookup, label: "Choose from referenced table", action: onPick)
                }
                if hasReference {
                    IconButton(icon: Icon.goTo, label: "Go to referenced row", action: onFollow)
                }
                if isEditable, TemporalText.isTemporal(column.kind) {
                    IconButton(icon: column.kind == .time ? "clock" : "calendar", label: "Pick a value") {
                        isPickerShown.toggle()
                    }
                }
                if isEditable, !isNull, column.isNullable != false {
                    IconButton(icon: Icon.null, label: "Set NULL", action: onSetNull)
                }
            }
            switch value {
            case .bytes(let data):
                Text("\(data.count) bytes").font(.caption).foregroundStyle(.secondary)
            default:
                TextField(isNull ? "NULL" : "", text: $draft, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(1 ... 6)
                    .disabled(!isEditable)
                    .focused($isFocused)
                    .onSubmit { commitIfChanged() }
                    // Leaving the field commits it too. Return alone would mean a value
                    // typed and then clicked away from was dropped without a word.
                    .onChange(of: isFocused) { _, focused in if !focused { commitIfChanged() } }
                if isPickerShown, isEditable, TemporalText.isTemporal(column.kind) {
                    TemporalPickerView(kind: column.kind, text: draft) { picked in
                        draft = picked
                        isPickerShown = false
                        onCommit(picked)
                    }
                    .padding(DesignTokens.Spacing.sm)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                }
            }
        }
        .onAppear { load() }
        .onChange(of: value) { _, _ in load() }
    }

    private func load() {
        isNull = value.isNull
        draft = value.isNull ? "" : ClipboardFormatter.cellText(value)
    }

    private func commitIfChanged() {
        guard isEditable, CellInspectorView.isChanged(draft: draft, from: value) else { return }
        onCommit(draft)
    }
}

/// The editor for one value: text, pretty JSON, a hex dump, or NULL.
private struct CellValueEditor: View {
    let columnName: String
    let kind: DBValueKind
    let value: DBValue?
    let isEditable: Bool
    let onCommit: (String) -> Void
    let onSetNull: () -> Void

    @State private var draft = ""
    @State private var isExporting = false
    /// Open by default: a date cell is usually edited with the calendar, not by typing.
    @State private var isPickerShown = true

    var body: some View {
        switch value {
        case .none:
            Text("No cell selected").foregroundStyle(.secondary)

        case .null:
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Label("NULL", systemImage: Icon.null).italic().foregroundStyle(.tertiary)
                if isEditable {
                    Button("Replace with empty text") { onCommit("") }.controlSize(.small)
                }
            }

        case let .raw(typeName, nil, bytes?) where GeometryParser.isGeometryType(typeName):
            // Geometry: the well-known text, which is what can be read, copied and mapped.
            let feature = GeometryParser.parse(bytes: bytes, dialect: .postgresql)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                HStack(spacing: DesignTokens.Spacing.sm) {
                    Badge(text: feature?.shape.typeName ?? "GEOMETRY", color: .accentColor)
                    if let srid = feature?.srid { Badge(text: "SRID \(srid)") }
                    Text("\(bytes.count) bytes").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(feature?.shape.wkt ?? CellInspectorView.hexDump(bytes))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Spacing.sm)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                Text("Open the Map pane to see it drawn.").font(.caption).foregroundStyle(.tertiary)
            }

        case let .bytes(data):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                Text("\(data.count) bytes").font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    Text(CellInspectorView.hexDump(data))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                Button {
                    isExporting = true
                } label: {
                    Label("Save as File…", systemImage: Icon.save)
                }
                .controlSize(.small)
                .fileExporter(
                    isPresented: $isExporting,
                    document: BinaryDocument(data: data),
                    contentType: .data,
                    defaultFilename: columnName
                ) { _ in }
            }

        case let .json(text):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                ScrollView {
                    Text(CellInspectorView.prettyJSON(text))
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(DesignTokens.Spacing.sm)
                }
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                HStack {
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(CellInspectorView.prettyJSON(text), forType: .string)
                    } label: {
                        Label("Copy Formatted", systemImage: Icon.copy)
                    }
                    .controlSize(.small)
                    Spacer()
                    if isEditable {
                        Button("Set NULL", action: onSetNull).controlSize(.small)
                    }
                }
            }

        case let .some(other):
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
                if TemporalText.isTemporal(kind) {
                    // A date is typed or picked; either way the text below is what is sent.
                    HStack {
                        Toggle(isOn: $isPickerShown) {
                            Label(
                                kind == .time ? "Clock" : "Calendar", systemImage: kind == .time ? "clock" : "calendar")
                        }
                        .toggleStyle(.button)
                        .controlSize(.small)
                        .disabled(!isEditable)
                        Spacer()
                    }
                    if isPickerShown, isEditable {
                        TemporalPickerView(kind: kind, text: draft) { picked in
                            draft = picked
                            onCommit(picked)
                        }
                        .padding(DesignTokens.Spacing.sm)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                    }
                }
                TextEditor(text: $draft)
                    .font(.system(.body, design: .monospaced))
                    .disabled(!isEditable)
                    .frame(minHeight: TemporalText.isTemporal(kind) ? 60 : 140)
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius)
                            .strokeBorder(Color.primary.opacity(0.1))
                    )
                HStack {
                    Text("\(draft.count) character\(draft.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    Spacer()
                    if isEditable {
                        Button("Set NULL", action: onSetNull).controlSize(.small)
                        Button("Apply") { onCommit(draft) }
                            .controlSize(.small)
                            .buttonStyle(.borderedProminent)
                            .disabled(draft == ClipboardFormatter.cellText(other))
                    }
                }
            }
            .onAppear { draft = ClipboardFormatter.cellText(other) }
            .onChange(of: other) { _, new in draft = ClipboardFormatter.cellText(new) }
        }
    }
}

extension CellInspectorView {
    /// Whether a form field's draft differs from the value it was filled from, which is
    /// what decides whether leaving the field writes anything.
    ///
    /// The comparison has to be against the same text the field was filled with. An array
    /// and a geometry have no `DBValue.text` at all, so comparing with that reported every
    /// untouched field as changed — and with auto-commit on, sent an UPDATE for a row
    /// nobody had edited.
    static func isChanged(draft: String, from value: DBValue) -> Bool {
        draft != (value.isNull ? "" : ClipboardFormatter.cellText(value))
    }

    /// Sixteen bytes a line, offset, hex and printable text — the usual shape.
    static func hexDump(_ data: Data, limit: Int = 4_096) -> String {
        var lines: [String] = []
        let bytes = Array(data.prefix(limit))
        lines.reserveCapacity(bytes.count / 16 + 2)
        for offset in stride(from: 0, to: bytes.count, by: 16) {
            let chunk = bytes[offset ..< min(offset + 16, bytes.count)]
            let hex = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
            let text = String(chunk.map { $0 >= 32 && $0 < 127 ? Character(UnicodeScalar($0)) : "." })
            lines.append(String(format: "%08x  %-47s  %@", offset, (hex as NSString).utf8String ?? "", text))
        }
        if data.count > limit { lines.append("… \(data.count - limit) more bytes") }
        return lines.joined(separator: "\n")
    }

    static func prettyJSON(_ text: String) -> String {
        guard let data = text.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
            let pretty = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]
            )
        else { return text }
        return String(decoding: pretty, as: UTF8.self)
    }
}

/// Wraps raw bytes so the cell inspector can offer "Save as File…".
struct BinaryDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.data] }

    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
