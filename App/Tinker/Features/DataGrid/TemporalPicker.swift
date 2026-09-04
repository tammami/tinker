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
