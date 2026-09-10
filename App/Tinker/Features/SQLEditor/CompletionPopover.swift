import AppKit
import DBCore

/// The autocomplete list the editor shows while typing (SPEC §13.1).
///
/// An `NSTableView` in a borderless panel rather than SwiftUI: it has to appear beside the
/// caret without taking key focus, because the user is still typing into the editor and
/// every keystroke has to keep reaching it.
@MainActor
final class CompletionPopover: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()

    private(set) var candidates: [CompletionCandidate] = []
    /// What the list is completing, so accepting one can replace it.
    private(set) var prefix = ""
    private var onAccept: ((CompletionCandidate) -> Void)?

    var isVisible: Bool { panel.isVisible }

    static let rowHeight: CGFloat = 24
    static let verticalInset: CGFloat = 6
    static let width: CGFloat = 380

    /// The row the arrow keys have moved to.
    var selectedCandidate: CompletionCandidate? {
        let row = tableView.selectedRow
        return candidates.indices.contains(row) ? candidates[row] : nil
    }

    /// A panel that never takes the keyboard.
    ///
    /// If it did, every key — including Escape — would go to it instead of to the editor,
    /// and the list could not be dismissed or typed past.
    private final class NonKeyPanel: NSPanel {
        override var canBecomeKey: Bool { false }
        override var canBecomeMain: Bool { false }
    }

    override init() {
        panel = NonKeyPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        super.init()

        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear

        let container = NSVisualEffectView()
        container.material = .menu
        container.blendingMode = .behindWindow
        container.state = .active
        container.wantsLayer = true
        container.layer?.cornerRadius = 8
        container.layer?.masksToBounds = true

        tableView.headerView = nil
        // Plain style: the default inset style pads every row and pushes the first one
        // below the panel's edge, which is how a one-row list ended up half hidden.
        tableView.style = .plain
        tableView.rowHeight = Self.rowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 0)
        tableView.backgroundColor = .clear
        tableView.selectionHighlightStyle = .regular
        tableView.allowsEmptySelection = false
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(acceptDoubleClick)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("candidate"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsetsZero
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.verticalInset),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.verticalInset),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        panel.contentView = container
    }

    // MARK: - Showing

    /// Puts the list under the caret. Does nothing when there is nothing to offer.
    func show(
        candidates: [CompletionCandidate],
        prefix: String,
        below caretRect: NSRect,
        in textView: NSTextView,
        onAccept: @escaping (CompletionCandidate) -> Void
    ) {
        guard !candidates.isEmpty, let window = textView.window else { return dismiss() }
        self.candidates = candidates
        self.prefix = prefix
        self.onAccept = onAccept
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)

        let rows = min(candidates.count, 10)
        // The rows, plus the inset above and below them, is exactly the panel's height.
        let height = CGFloat(rows) * Self.rowHeight + Self.verticalInset * 2
        panel.setContentSize(NSSize(width: Self.width, height: height))
        panel.contentView?.layoutSubtreeIfNeeded()
        tableView.scrollRowToVisible(0)

        let onScreen = window.convertToScreen(textView.convert(caretRect, to: nil))
        var top = NSPoint(x: onScreen.minX, y: onScreen.minY - 4)
        // Flip above the caret when there is no room beneath it.
        if let screen = window.screen, top.y - height < screen.visibleFrame.minY {
            top.y = onScreen.maxY + 4 + height
        }
        panel.setFrameTopLeftPoint(top)

        if !panel.isVisible { window.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func dismiss() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        candidates = []
        onAccept = nil
    }

    // MARK: - Keyboard, driven by the text view

    func moveSelection(by offset: Int) {
        guard !candidates.isEmpty else { return }
        let row = max(0, min(candidates.count - 1, tableView.selectedRow + offset))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    func acceptSelection() {
        guard let candidate = selectedCandidate else { return }
        let accept = onAccept
        dismiss()
        accept?(candidate)
    }

    @objc private func acceptDoubleClick() { acceptSelection() }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { candidates.count }

    func tableView(
        _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
    ) -> NSView? {
        guard candidates.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("CompletionRow")
        let view =
            tableView.makeView(withIdentifier: identifier, owner: self) as? CompletionRowView
            ?? {
                let fresh = CompletionRowView()
                fresh.identifier = identifier
                return fresh
            }()
        view.configure(candidates[row], matching: prefix)
        return view
    }
}

/// One suggestion: its kind, the text with the typed letters picked out, and its detail.
private final class CompletionRowView: NSView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyDown
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = DesignTokens.Fonts.editor(size: 12)
        label.lineBreakMode = .byTruncatingTail
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 10)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .right
        detail.lineBreakMode = .byTruncatingHead

        addSubview(icon)
        addSubview(label)
        addSubview(detail)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            detail.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            detail.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            detail.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func configure(_ candidate: CompletionCandidate, matching prefix: String) {
        icon.image = NSImage(
            systemSymbolName: candidate.symbolName, accessibilityDescription: candidate.kind.rawValue
        )
        icon.contentTintColor = Self.tint(for: candidate.kind)
        label.attributedStringValue = Self.highlighted(candidate.text, matching: prefix)
        label.textColor = .labelColor
        detail.stringValue = candidate.detail ?? ""
    }

    /// Picks out the letters the user has typed in bold. Only the weight changes, so the
    /// text keeps the label colour and turns white with the selection like any other row.
    private static func highlighted(_ text: String, matching prefix: String) -> NSAttributedString {
        let font = DesignTokens.Fonts.editor(size: 12)
        let attributed = NSMutableAttributedString(string: text, attributes: [.font: font])
        // The letters are matched fuzzily, so each one the query landed on is marked:
        // `kel` bolds the `kel` of `aset_kelompok`, `ak` its `a` and `k`.
        let tail = prefix.split(separator: ".").last.map(String.init) ?? prefix
        guard !tail.isEmpty, let match = FuzzyMatch.match(tail, in: text) else { return attributed }
        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let characters = Array(text)
        for position in match.positions where characters.indices.contains(position) {
            let start = text.index(text.startIndex, offsetBy: position)
            let range = NSRange(start ..< text.index(after: start), in: text)
            attributed.addAttribute(.font, value: bold, range: range)
        }
        return attributed
    }

    private static func tint(for kind: CompletionCandidate.Kind) -> NSColor {
        switch kind {
        case .keyword: .systemPink
        case .table: .systemGreen
        case .column: .systemTeal
        case .function: .systemPurple
        case .schema: .systemOrange
        }
    }
}
