import DBGrid
import SwiftUI

/// What this tab has written, newest first, and a way back from each one (ADR-0060).
///
/// With auto-commit on, a written edit leaves no other trace: the buffer is empty, the
/// grid shows the new value, and nothing says what the old one was. This list is where
/// "I did not mean that" is answered.
struct WriteLogPopover: View {
    @Bindable var controller: TableTabController

    private static let time: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Writes in this tab").font(.headline)
                Spacer()
                Text("newest first").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(DesignTokens.Spacing.md)

            Divider()

            if controller.writeLog.records.isEmpty {
                Text("Nothing written yet.")
                    .foregroundStyle(.secondary)
                    .padding(DesignTokens.Spacing.md)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(controller.writeLog.records) { record in
                            row(record)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .frame(width: 340)
    }

    @ViewBuilder
    private func row(_ record: WriteRecord) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: DesignTokens.Spacing.xs) {
                    Text(record.summary).font(.callout)
                    if record.isReverted { Badge(text: "PUT BACK", color: .secondary) }
                }
                Text(Self.time.string(from: record.at))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
                if let reason = record.blockedReason, !record.isReverted {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if record.canRevert {
                Button("Put Back") { controller.revert(record) }
                    .controlSize(.small)
                    .disabled(controller.isWriting)
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
    }
}
