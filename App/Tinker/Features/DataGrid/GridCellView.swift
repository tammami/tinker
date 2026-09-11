import AppKit
import DBCore
import DBGrid

/// One grid cell.
///
/// A plain `NSView` that draws its background, its focus ring and its text itself. It
/// used to host an `NSTextField` under three Auto Layout constraints; measured in a
/// window (`DataGridPerformanceTests`), creating and laying those out for the eight
/// hundred cells of one screen cost ten frames on a reload and nearly two on every
/// scroll stop. String drawing with cached attributes costs a fraction of one
/// (SPEC §12.1, §12.6; ADR-0047).
final class GridCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("Tinker.GridCell")
    /// The text's distance from the cell's edges; the header keeps the same one.
    static let horizontalInset: CGFloat = 6

    /// What the cell shows, ready to draw; nil when there is nothing to draw.
    private var text: NSAttributedString?
    /// The plain text, for accessibility and for the inline editor's starting value.
    private(set) var stringValue = ""
    private var backgroundColor: NSColor = .clear
    private var isFocusedCell = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // No layer of its own: the row view is layer-backed, and a layer per cell is one
        // more object to make and composite for each of the hundreds on screen.
        // The cell is a plain view, so it has to say what it is; without this the grid is
        // invisible to the accessibility system and to UI tests.
        setAccessibilityRole(.staticText)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    // MARK: Cached text attributes

    /// Built once: a paragraph style and a font per look, shared by every cell. Cells
    /// live on the main actor, so the shared objects do too.
    @MainActor
    private enum Style {
        static let font = DesignTokens.Fonts.grid
        static let italic = NSFontManager.shared.convert(DesignTokens.Fonts.grid, toHaveTrait: .italicFontMask)
        static let lineHeight: CGFloat = {
            let layout = NSLayoutManager()
            return ceil(layout.defaultLineHeight(for: font))
        }()

        static let leftParagraph = paragraph(.left)
        static let rightParagraph = paragraph(.right)
        static let naturalParagraph = paragraph(.natural)
        static let centerParagraph = paragraph(.center)

        static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
            let style = NSMutableParagraphStyle()
            style.alignment = alignment
            style.lineBreakMode = .byTruncatingTail
            return style
        }

        static func paragraph(for alignment: NSTextAlignment) -> NSParagraphStyle {
            switch alignment {
            case .left: leftParagraph
            case .right: rightParagraph
            case .center: centerParagraph
            default: naturalParagraph
            }
        }

        static func attributes(
            font: NSFont, color: NSColor, alignment: NSTextAlignment, strikethrough: Bool = false
        ) -> [NSAttributedString.Key: Any] {
            var attributes: [NSAttributedString.Key: Any] = [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph(for: alignment),
            ]
            if strikethrough { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            return attributes
        }
    }

    /// Fills in one cell. Called for every visible cell on every reload, so it does no
    /// allocation beyond the string it must show.
    func configure(
        value: DBValue?,
        changeState: CellChangeState,
        isSelected: Bool,
        isFocused: Bool,
        alignment: NSTextAlignment,
        label: String? = nil,
        columnName: String? = nil
    ) {
        isFocusedCell = isFocused
        // A value with a label beside it reads as text, whatever the column's type.
        let alignment = label == nil ? alignment : .left

        switch value {
        case .none:
            // The row is not loaded yet; a placeholder beats an empty cell that looks like NULL.
            stringValue = "…"
            text = NSAttributedString(
                string: stringValue,
                attributes: Style.attributes(font: Style.font, color: DesignTokens.Colors.nullText, alignment: alignment))
        case .null:
            stringValue = "NULL"
            text = NSAttributedString(
                string: stringValue,
                attributes: Style.attributes(font: Style.italic, color: DesignTokens.Colors.nullText, alignment: alignment))
        case let .bytes(data):
            stringValue = "<\(data.count) bytes>"
            text = NSAttributedString(
                string: stringValue,
                attributes: Style.attributes(font: Style.font, color: DesignTokens.Colors.binaryText, alignment: alignment))
        case let .some(other):
            stringValue = Self.displayText(for: other)
            if let label, changeState != .deleted {
                // "1 · Ada": the key the column holds, then what it points at, muted.
                let shown = NSMutableAttributedString(
                    string: stringValue,
                    attributes: Style.attributes(font: Style.font, color: .labelColor, alignment: alignment))
                shown.append(
                    NSAttributedString(
                        string: "  ·  \(label)",
                        attributes: Style.attributes(font: Style.font, color: .secondaryLabelColor, alignment: alignment)))
                text = shown
            } else {
                text = NSAttributedString(
                    string: stringValue,
                    attributes: Style.attributes(font: Style.font, color: .labelColor, alignment: alignment))
            }
        }

        backgroundColor =
            switch changeState {
            case .edited: DesignTokens.Colors.editedCell
            case .inserted: DesignTokens.Colors.insertedRow
            case .deleted: DesignTokens.Colors.deletedRow
            case .unchanged: isSelected ? .selectedContentBackgroundColor.withAlphaComponent(0.35) : .clear
            }
        if changeState != .unchanged, isSelected {
            backgroundColor =
                backgroundColor.blended(withFraction: 0.3, of: .selectedContentBackgroundColor)
                ?? backgroundColor
        }
        if changeState == .deleted {
            text = NSAttributedString(
                string: stringValue,
                attributes: Style.attributes(
                    font: Style.font, color: .secondaryLabelColor, alignment: alignment, strikethrough: true))
        }
        // What VoiceOver reads: the column, then the value — with NULL and "not loaded"
        // told apart from a text that happens to say "NULL" — then the cell's state.
        // Selection is painted by the cell, so the table view cannot report it; the cell
        // says so itself.
        let spokenValue: String
        switch value {
        case .none: spokenValue = "not loaded"
        case .null: spokenValue = "NULL, no value"
        case let .bytes(data): spokenValue = "\(data.count) bytes of binary data"
        case .some: spokenValue = stringValue
        }
        let state: String
        switch changeState {
        case .edited: state = ", edited"
        case .inserted: state = ", new row"
        case .deleted: state = ", marked for deletion"
        case .unchanged: state = ""
        }
        setAccessibilityLabel(columnName ?? "")
        setAccessibilityValue(spokenValue + state)
        setAccessibilitySelected(isSelected)
        setAccessibilityFocused(isFocused)
        needsDisplay = true
    }

    /// The text a cell shows: long values are cut here and shown in full in the inspector.
    static func displayText(for value: DBValue) -> String {
        switch value {
        case let .raw(typeName, nil, bytes?) where GeometryParser.isGeometryType(typeName):
            // A geometry arrives as bytes; its well-known text is what a person can read.
            return GeometryParser.parse(bytes: bytes, dialect: .postgresql)?.shape.summary ?? "<\(bytes.count) bytes>"
        case let .array(items):
            let joined = items.map { $0.text ?? "NULL" }.joined(separator: ", ")
            return truncate("{\(joined)}")
        case let .json(text):
            // JSON is shown on one line in the grid and pretty-printed in the inspector.
            return truncate(text.split(whereSeparator: \.isNewline).joined(separator: " "))
        default:
            return truncate(value.text ?? "")
        }
    }

    static func truncate(_ text: String) -> String {
        guard text.count > DesignTokens.Metrics.inCellTextLimit else {
            // A value with newlines would draw as one glyph-height line anyway; collapse
            // them so the user sees content rather than a stray box.
            return text.contains("\n") ? text.replacingOccurrences(of: "\n", with: "⏎") : text
        }
        return String(text.prefix(DesignTokens.Metrics.inCellTextLimit)) + "…"
    }

    override func draw(_ dirtyRect: NSRect) {
        if backgroundColor != .clear {
            backgroundColor.setFill()
            bounds.fill()
        }
        if isFocusedCell {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
        guard let text else { return }
        // One line, vertically centred, cut with an ellipsis at the trailing edge.
        let inset = Self.horizontalInset
        let rect = NSRect(
            x: inset, y: ((bounds.height - Style.lineHeight) / 2).rounded(),
            width: max(0, bounds.width - inset * 2), height: Style.lineHeight)
        text.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }
}

extension DBValueKind {
    /// Numbers read better right-aligned; everything else stays left.
    var cellAlignment: NSTextAlignment {
        switch self {
        case .int, .uint, .double, .decimal: .right
        default: .natural
        }
    }
}

/// The row gutter: the number down the left edge that a whole-row selection is clicked on.
///
/// It is a header, not data, so it draws like one and never takes part in editing or in
/// the column widths the grid remembers.
final class GridRowNumberView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("Tinker.GridRowNumber")

    @MainActor private static let selectedAttributes: [NSAttributedString.Key: Any] = attributes(color: .labelColor)
    @MainActor private static let plainAttributes: [NSAttributedString.Key: Any] = attributes(color: .secondaryLabelColor)
    @MainActor private static let lineHeight: CGFloat = ceil(NSLayoutManager().defaultLineHeight(for: DesignTokens.Fonts.grid))

    private static func attributes(color: NSColor) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .right
        paragraph.lineBreakMode = .byClipping
        return [.font: DesignTokens.Fonts.grid, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    private var text: NSAttributedString?
    private var isSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.staticText)
        setAccessibilityElement(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(row: Int, isSelected: Bool) {
        self.isSelected = isSelected
        text = NSAttributedString(
            string: String(row + 1), attributes: isSelected ? Self.selectedAttributes : Self.plainAttributes)
        setAccessibilityLabel("Row \(row + 1)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.25)
            : NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        // No trailing hairline: the rows carry no column rules, only the header does.
        guard let text else { return }
        let rect = NSRect(
            x: 4, y: ((bounds.height - Self.lineHeight) / 2).rounded(),
            width: max(0, bounds.width - 10), height: Self.lineHeight)
        text.draw(with: rect, options: [.usesLineFragmentOrigin])
    }
}

/// A column header whose title keeps the same 6-point margin the cells below it use.
///
/// The default cell draws its text hard against the column edge, which with the body's
/// separators aligned to that same edge leaves the label touching the line.
final class GridHeaderCell: NSTableHeaderCell {
    /// Matches `GridCellView`'s text insets, so a heading sits directly above its values.
    static let horizontalInset = GridCellView.horizontalInset

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(
            withFrame: cellFrame.insetBy(dx: Self.horizontalInset, dy: 0), in: controlView
        )
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect.insetBy(dx: Self.horizontalInset, dy: 0))
    }
}
