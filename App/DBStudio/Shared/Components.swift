import SwiftUI

// The building blocks every screen is assembled from. Each one fixes a height, an inset
// and a spacing from `DesignTokens`, so no view chooses its own and the chrome reads as
// one surface from the sidebar to the status line.

/// A horizontal bar of controls: fixed height, one inset, one spacing.
struct PaneBar<Content: View>: View {
    var height: CGFloat = DesignTokens.Metrics.barHeight
    var material: Material = .bar
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.sm) { content }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .background(material)
    }
}

/// The status line at the foot of a pane or window.
struct StatusBarView<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.md) { content }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .padding(.horizontal, DesignTokens.Spacing.md)
            .frame(height: DesignTokens.Metrics.statusHeight)
            .frame(maxWidth: .infinity)
            .background(.bar)
    }
}

/// The vertical rule between groups in a bar.
struct BarDivider: View {
    var body: some View {
        Divider().frame(height: 16)
    }
}

/// A button that is only an icon, the shape every secondary action in a bar takes.
struct IconButton: View {
    let icon: String
    let label: String
    var isDestructive = false
    let action: () -> Void

    var body: some View {
        Button(role: isDestructive ? .destructive : nil, action: action) {
            Label(label, systemImage: icon)
                .labelStyle(.iconOnly)
                .frame(width: 22, height: 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A small rounded label: a count, a state, a kind.
struct Badge: View {
    let text: String
    var color: Color = .secondary
    var isProminent = false

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .padding(.horizontal, DesignTokens.Spacing.xs + 1)
            .padding(.vertical, 1)
            .background(isProminent ? color : color.opacity(0.16))
            .foregroundStyle(isProminent ? .white : color)
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
    }
}

/// A keyboard shortcut drawn as a key cap, so hints look the same everywhere.
struct KeyCap: View {
    let keys: String

    var body: some View {
        Text(keys)
            .font(.caption2.monospaced())
            .padding(.horizontal, DesignTokens.Spacing.xs + 2)
            .padding(.vertical, DesignTokens.Spacing.xs - 1)
            .background(Color.primary.opacity(0.07))
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius)
                    .strokeBorder(Color.primary.opacity(0.12))
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.smallCornerRadius))
            .foregroundStyle(.secondary)
    }
}

/// One keyboard hint: a key cap and what it does.
struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.xs + 2) {
            KeyCap(keys: keys)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// The foot of a palette-style sheet: keyboard hints on the left, a count on the right.
///
/// Taller than a status line and inset like the sheet's own content, so the key caps sit
/// clear of the rounded corner rather than against it.
struct SheetHintBar<Trailing: View>: View {
    let hints: [(keys: String, label: String)]
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: DesignTokens.Spacing.lg) {
            ForEach(Array(hints.enumerated()), id: \.offset) { _, hint in
                KeyHint(keys: hint.keys, label: hint.label)
            }
            Spacer()
            trailing
                .font(.caption)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
        .padding(.horizontal, DesignTokens.Spacing.lg)
        .frame(height: DesignTokens.Metrics.barHeight)
        .background(.bar)
    }
}

/// What a banner is telling the user.
enum BannerKind {
    case error, warning, success, info

    var color: Color {
        switch self {
        case .error: .red
        case .warning: .orange
        case .success: .green
        case .info: .accentColor
        }
    }

    var icon: String {
        switch self {
        case .error: Icon.error
        case .warning: Icon.warning
        case .success: Icon.success
        case .info: Icon.info
        }
    }
}

/// The inline, non-modal message strip: server errors verbatim, warnings, confirmations.
struct InlineBanner: View {
    let kind: BannerKind
    let message: String
    var detail: String?
    var hint: String?
    var onCopy: (() -> Void)?
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignTokens.Spacing.sm) {
            Image(systemName: kind.icon)
                .foregroundStyle(kind.color)
                .frame(width: DesignTokens.Metrics.iconWidth)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xs) {
                Text(message)
                    .font(kind == .error ? .system(.callout, design: .monospaced) : .callout)
                    .textSelection(.enabled)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if let hint {
                    Text(hint).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Spacer(minLength: DesignTokens.Spacing.sm)
            if let onCopy {
                Button(action: onCopy) { Label("Copy", systemImage: Icon.copy) }
                    .controlSize(.small)
                    .help("Copy the message and the statement")
            }
            IconButton(icon: Icon.close, label: "Dismiss", action: onDismiss)
        }
        .padding(.horizontal, DesignTokens.Spacing.md)
        .padding(.vertical, DesignTokens.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(kind.color.opacity(0.09))
        .overlay(alignment: .leading) {
            Rectangle().fill(kind.color).frame(width: 3)
        }
    }
}

/// The inline error strip, kept under its old name for the views that already use it.
public struct ErrorBanner: View {
    let message: String
    var detail: String?
    var hint: String?
    var onCopy: (() -> Void)?
    let onDismiss: () -> Void

    public init(
        message: String,
        detail: String? = nil,
        hint: String? = nil,
        onCopy: (() -> Void)? = nil,
        onDismiss: @escaping () -> Void
    ) {
        self.message = message
        self.detail = detail
        self.hint = hint
        self.onCopy = onCopy
        self.onDismiss = onDismiss
    }

    public var body: some View {
        InlineBanner(
            kind: .error, message: message, detail: detail, hint: hint,
            onCopy: onCopy, onDismiss: onDismiss
        )
    }
}

/// What a pane shows when it has nothing to show: a symbol, a sentence, and the one
/// thing the user can do next.
struct EmptyStateView<Actions: View>: View {
    let icon: String
    let title: String
    var message: String?
    /// True fills the pane and centres; false sizes to content so a caller can stack more below.
    var fills = true
    @ViewBuilder var actions: Actions

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 64, height: 64)
                .background(Color.primary.opacity(0.05))
                .clipShape(Circle())
            VStack(spacing: DesignTokens.Spacing.xs) {
                Text(title).font(.title3.weight(.semibold))
                if let message {
                    Text(message)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 380)
                }
            }
            HStack(spacing: DesignTokens.Spacing.sm) { actions }
                .padding(.top, DesignTokens.Spacing.xs)
        }
        .padding(DesignTokens.Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: fills ? .infinity : nil)
    }
}

extension EmptyStateView where Actions == EmptyView {
    init(icon: String, title: String, message: String? = nil) {
        self.init(icon: icon, title: title, message: message) { EmptyView() }
    }
}

/// The frame every sheet is built in: a titled header, the content, a button row.
///
/// Sheets are where a person decides something, so they all read the same way: what this
/// is at the top, the choice in the middle, and Cancel beside the action at the bottom.
struct SheetFrame<Content: View, Footer: View>: View {
    let title: String
    let icon: String
    var subtitle: String?
    var width: CGFloat = DesignTokens.Metrics.sheetWidth
    var contentInset: CGFloat = DesignTokens.Spacing.lg
    @ViewBuilder let content: Content
    @ViewBuilder let footer: Footer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignTokens.Spacing.md) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 32, height: 32)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: DesignTokens.Metrics.cornerRadius))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    if let subtitle {
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(DesignTokens.Spacing.lg)
            Divider()

            content
                .padding(contentInset)

            Divider()
            HStack(spacing: DesignTokens.Spacing.sm) { footer }
                .padding(.horizontal, DesignTokens.Spacing.lg)
                .padding(.vertical, DesignTokens.Spacing.md)
                .background(.bar)
        }
        .frame(width: width)
    }
}

/// A labelled row inside a sheet or inspector, with the label column fixed so values line up.
struct FieldRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 110
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.sm) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .trailing)
            content
        }
    }
}

/// A section heading inside a pane: small caps, secondary, evenly inset.
struct SectionHeading: View {
    let text: String
    var trailing: String?
    var inset: CGFloat = DesignTokens.Spacing.md

    var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)
            Spacer()
            if let trailing {
                Text(trailing).font(.caption2).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.horizontal, inset)
        .padding(.top, DesignTokens.Spacing.md)
        .padding(.bottom, DesignTokens.Spacing.xs)
    }
}

/// A lightweight, self-drawn table for small, static lists: headings, rows, alternating
/// backgrounds, one inset. Used where the full grid would be too heavy.
struct SimpleTable: View {
    struct Column: Identifiable {
        let id = UUID()
        let title: String
        var width: CGFloat?
        var isNumeric = false
    }

    let columns: [Column]
    let rows: [[String]]
    var monospaced = true

    var body: some View {
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                Section {
                    ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                        HStack(spacing: 0) {
                            ForEach(Array(columns.enumerated()), id: \.element.id) { position, column in
                                Text(position < row.count ? row[position] : "")
                                    .font(monospaced ? .system(.caption, design: .monospaced) : .caption)
                                    .lineLimit(1)
                                    .frame(width: column.width, alignment: column.isNumeric ? .trailing : .leading)
                                    .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
                                    .padding(.horizontal, DesignTokens.Spacing.sm)
                            }
                        }
                        .frame(height: DesignTokens.Metrics.gridRowHeight)
                        .background(
                            index.isMultiple(of: 2)
                                ? Color.clear
                                : Color(nsColor: .alternatingContentBackgroundColors[1])
                        )
                    }
                } header: {
                    HStack(spacing: 0) {
                        ForEach(columns) { column in
                            Text(column.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(width: column.width, alignment: column.isNumeric ? .trailing : .leading)
                                .frame(maxWidth: column.width == nil ? .infinity : nil, alignment: .leading)
                                .padding(.horizontal, DesignTokens.Spacing.sm)
                        }
                    }
                    .frame(height: DesignTokens.Metrics.gridHeaderHeight)
                    .background(.bar)
                    .overlay(alignment: .bottom) { Divider() }
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        }
    }
}

extension View {
    /// The standard hairline that separates stacked panes.
    func paneDivider() -> some View {
        overlay(alignment: .bottom) { Divider() }
    }
}
