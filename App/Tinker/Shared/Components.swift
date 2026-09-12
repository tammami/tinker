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
            .lineLimit(1)
            .fixedSize()
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

    /// A combination is spaced out — `⌘ ⇧ U` — so each key reads on its own; a single
    /// key or a word such as `esc` stays as it is.
    private var spaced: String {
        let modifiers: Set<Character> = ["⌘", "⇧", "⌥", "⌃"]
        guard keys.contains(where: { modifiers.contains($0) }), keys.count > 1 else { return keys }
        return keys.map(String.init).joined(separator: " ")
    }

    var body: some View {
        Text(spaced)
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
                .font(.system(size: DesignTokens.Typography.hero, weight: .regular))
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
        // The viewport's own size is the content's minimum, so a table smaller than the
        // pane sits at the top left instead of being centred in the empty space — a
        // scroll view sizes its content to the content's own ideal and centres the rest.
        GeometryReader { viewport in
            ScrollView([.vertical, .horizontal]) {
                table
                    .frame(
                        minWidth: viewport.size.width, minHeight: viewport.size.height,
                        alignment: .topLeading)
            }
        }
    }

    private var table: some View {
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
        .frame(minWidth: 0, alignment: .topLeading)
    }
}

extension View {
    /// The standard hairline that separates stacked panes.
    func paneDivider() -> some View {
        overlay(alignment: .bottom) { Divider() }
    }
}

extension View {
    /// Focuses `binding` when ⌘F asks for the front tab's search field.
    func focusesOnSearchCommand(_ binding: FocusState<Bool>.Binding) -> some View {
        onReceive(NotificationCenter.default.publisher(for: .tinkerFocusSearch)) { _ in
            binding.wrappedValue = true
        }
    }
}

/// A pop-up of fixed width for a bar.
///
/// SwiftUI's menu picker takes the width of its widest item and sits centred in whatever
/// frame it is given, so two pickers side by side get gaps that depend on the names in
/// them. This one fills the width it is offered and truncates a long title instead, so
/// the bar keeps its layout whatever the connection or database is called.
struct BarPopUp<ID: Hashable>: NSViewRepresentable {
    struct Item: Equatable {
        let id: ID
        let title: String
        var icon: String? = nil
    }

    let items: [Item]
    @Binding var selection: ID
    @Environment(\.controlSize) private var controlSize

    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }

    func makeNSView(context: Context) -> NSPopUpButton {
        let popUp = NSPopUpButton(frame: .zero, pullsDown: false)
        popUp.target = context.coordinator
        popUp.action = #selector(Coordinator.didSelect(_:))
        popUp.menu?.delegate = context.coordinator
        context.coordinator.popUp = popUp
        popUp.cell?.lineBreakMode = .byTruncatingTail
        popUp.setContentHuggingPriority(.defaultLow, for: .horizontal)
        popUp.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return popUp
    }

    func updateNSView(_ popUp: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        let size = Self.appKitSize(controlSize)
        if popUp.controlSize != size {
            popUp.controlSize = size
            popUp.font = NSFont.systemFont(ofSize: NSFont.systemFontSize(for: size))
        }
        // Items that arrive while the menu is open (a database list loading) wait until it
        // closes; rebuilding under the pointer would let the click land on the wrong row.
        if context.coordinator.isMenuOpen {
            context.coordinator.pending = (items, selection)
            return
        }
        Self.apply(items: items, selection: selection, to: popUp, coordinator: context.coordinator, size: size)
    }

    static func apply(
        items: [Item], selection: ID, to popUp: NSPopUpButton, coordinator: Coordinator, size: NSControl.ControlSize
    ) {
        if coordinator.items != items {
            coordinator.items = items
            popUp.removeAllItems()
            for item in items {
                let menuItem = NSMenuItem(title: item.title, action: nil, keyEquivalent: "")
                // The row carries its own id, so a click means that item whatever the index.
                menuItem.representedObject = item.id
                if let icon = item.icon {
                    menuItem.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: NSFont.systemFontSize(for: size), weight: .regular))
                }
                popUp.menu?.addItem(menuItem)
            }
        }
        if let index = items.firstIndex(where: { $0.id == selection }) {
            if popUp.indexOfSelectedItem != index { popUp.selectItem(at: index) }
        } else {
            popUp.select(nil)
        }
    }

    private static func appKitSize(_ size: ControlSize) -> NSControl.ControlSize {
        switch size {
        case .mini: .mini
        case .small: .small
        case .large, .extraLarge: .large
        default: .regular
        }
    }

    /// The width is the bar's to decide, when it names one; the height is the control's own.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSPopUpButton, context: Context) -> CGSize? {
        let own = nsView.intrinsicContentSize
        let width = proposal.width.map { $0.isFinite ? $0 : own.width } ?? own.width
        return CGSize(width: width, height: own.height)
    }

    @MainActor
    final class Coordinator: NSObject, NSMenuDelegate {
        var selection: Binding<ID>
        var items: [Item] = []
        /// True while the pop-up's menu is on screen.
        var isMenuOpen = false
        /// Items and selection that arrived while the menu was open, applied when it closes.
        var pending: ([Item], ID)?

        init(selection: Binding<ID>) { self.selection = selection }

        @objc func didSelect(_ sender: NSPopUpButton) {
            guard let id = sender.selectedItem?.representedObject as? ID else { return }
            selection.wrappedValue = id
        }

        func menuWillOpen(_ menu: NSMenu) { isMenuOpen = true }

        func menuDidClose(_ menu: NSMenu) {
            isMenuOpen = false
            guard let (items, selection) = pending, let popUp else {
                pending = nil
                return
            }
            pending = nil
            // The click's selection has already been reported; apply the newer list now.
            BarPopUp.apply(items: items, selection: selection, to: popUp, coordinator: self, size: popUp.controlSize)
        }

        /// The control this coordinator drives, for applying a list that arrived mid-click.
        weak var popUp: NSPopUpButton?
    }
}

/// Runs `action` each time the window holding this view becomes the key window.
///
/// SwiftUI has no notion of which window a view sits in; this borrows AppKit's, through
/// a view that learns its window and listens for it alone.
struct WindowKeyObserver: NSViewRepresentable {
    let onBecomeKey: () -> Void

    func makeNSView(context: Context) -> ObservingView {
        let view = ObservingView()
        view.onBecomeKey = onBecomeKey
        return view
    }

    func updateNSView(_ view: ObservingView, context: Context) {
        view.onBecomeKey = onBecomeKey
    }

    static func dismantleNSView(_ view: ObservingView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObservingView: NSView {
        var onBecomeKey: (() -> Void)?
        private var observer: (any NSObjectProtocol)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.onBecomeKey?() }
            }
        }

        /// Drops the observer; called when the view leaves its window or is torn down.
        func stopObserving() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
        }
    }
}

extension View {
    /// Calls `action` whenever the window this view is in becomes key.
    func onWindowBecomeKey(_ action: @escaping () -> Void) -> some View {
        background(WindowKeyObserver(onBecomeKey: action).frame(width: 0, height: 0))
    }
}

/// The footer piece every production write carries: the connection's name in red and,
/// for an action that takes something away or changes the schema, a field its name has
/// to be typed into before the button enables — the promise the connection editor makes.
struct ProductionGate: View {
    let connectionName: String
    let requiresTypedName: Bool
    @Binding var typed: String

    var body: some View {
        Label(connectionName, systemImage: Icon.production)
            .foregroundStyle(.red)
            .font(.callout.weight(.semibold))
        if requiresTypedName {
            TextField("Type \(connectionName) to confirm", text: $typed)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .help("This is a production connection; type its name to enable the action")
        }
    }

    /// True when the gate lets the action through: not production, no name needed, or
    /// the name typed exactly.
    static func passes(productionName: String?, requiresTypedName: Bool, typed: String) -> Bool {
        guard let productionName, requiresTypedName else { return true }
        return typed == productionName
    }
}
