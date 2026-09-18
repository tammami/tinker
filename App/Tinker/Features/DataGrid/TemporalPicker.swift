import DBCore
import DBGrid
import Foundation
import SwiftUI

/// A calendar and clock for a date, time or timestamp cell, writing the server's text.
struct TemporalPickerView: View {
    let kind: DBValueKind
    let text: String
    let onApply: (String) -> Void

    @State private var date = Date()
    @State private var fraction = ""
    @State private var offset = ""

    private var components: DatePickerComponents {
        switch kind {
        case .date: [.date]
        case .time: [.hourAndMinute]
        default: [.date, .hourAndMinute]
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            DatePicker("", selection: $date, displayedComponents: components)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            HStack(spacing: DesignTokens.Spacing.sm) {
                if kind != .date {
                    DatePicker("", selection: $date, displayedComponents: [.hourAndMinute])
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                }
                Text(TemporalText.render(date, kind: kind, fraction: fraction, offset: offset))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Now") { date = Date() }.controlSize(.small)
                Button("Use") { onApply(TemporalText.render(date, kind: kind, fraction: fraction, offset: offset)) }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
            }
        }
        .onAppear { load() }
        .onChange(of: text) { _, _ in load() }
    }

    private func load() {
        if let parts = TemporalText.parse(text, kind: kind) {
            date = parts.date
            fraction = parts.fraction
            offset = parts.offset
        } else {
            date = Date()
        }
    }
}

/// The editor a date, time or timestamp cell opens in the grid: the server's own text on
/// top, the calendar or clock below it (SPEC §12.2).
///
/// The text field is the raw-text fallback — anything the picker cannot express is typed
/// here, and the picker follows what is typed, so both routes end at the same spelling.
struct CellTemporalEditorView: View {
    let kind: DBValueKind
    let columnName: String
    let onCommit: (String) -> Void
    let onCancel: () -> Void

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(
        kind: DBValueKind, columnName: String, text: String,
        onCommit: @escaping (String) -> Void, onCancel: @escaping () -> Void
    ) {
        self.kind = kind
        self.columnName = columnName
        self.onCommit = onCommit
        self.onCancel = onCancel
        _draft = State(initialValue: text)
    }

    /// The picker only fits a date, a time or both; a width per shape keeps the popover
    /// off the calendar's edges.
    static func width(for kind: DBValueKind) -> CGFloat {
        kind == .time ? 240 : 340
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignTokens.Spacing.sm) {
            HStack(spacing: DesignTokens.Spacing.xs) {
                Image(systemName: kind == .time ? "clock" : "calendar")
                    .foregroundStyle(.secondary)
                Text(columnName).font(.caption.weight(.semibold))
                Spacer()
            }
            // The text and the picker each commit their own value: what is typed goes in
            // verbatim, what is picked is rendered the way the server spells it.
            HStack(spacing: DesignTokens.Spacing.sm) {
                TextField("", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .focused($isFocused)
                    .onSubmit { onCommit(draft) }
                Button("Set") { onCommit(draft) }
                    .controlSize(.small)
            }
            TemporalPickerView(kind: kind, text: draft) { picked in
                draft = picked
                onCommit(picked)
            }
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(DesignTokens.Spacing.md)
        .frame(width: Self.width(for: kind))
        .onAppear { isFocused = true }
    }
}
