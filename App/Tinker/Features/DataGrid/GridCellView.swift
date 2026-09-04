import AppKit
import DBCore
import DBGrid

/// One grid cell.
///
/// A plain `NSView` that draws its own background and hosts one `NSTextField`, rather than
/// a stack of subviews: at 22 points a row and thousands of visible cells, every extra
/// view costs frame time (SPEC §12.1).
final class GridCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("Tinker.GridCell")

    let textField = NSTextField(labelWithString: "")
    private var backgroundColor: NSColor = .clear
    private var isFocusedCell = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.lineBreakMode = .byTruncatingTail
        textField.cell?.usesSingleLineMode = true
        textField.font = DesignTokens.Fonts.grid
        textField.drawsBackground = false
        textField.isBordered = false
        textField.isEditable = false
        textField.isSelectable = false
        // The cell is a plain view, so it has to say what it is; without this the grid is
        // invisible to the accessibility system and to UI tests.
        setAccessibilityRole(.staticText)
        setAccessibilityElement(true)
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    /// Fills in one cell. Called for every visible cell on every reload, so it does no
    /// allocation beyond the string it must show.
    func configure(
        value: DBValue?,
        changeState: CellChangeState,
        isSelected: Bool,
        isFocused: Bool,
        alignment: NSTextAlignment
    ) {
        isFocusedCell = isFocused
        textField.alignment = alignment

        switch value {
        case .none:
            // The row is not loaded yet; a placeholder beats an empty cell that looks like NULL.
            textField.stringValue = "…"
            textField.textColor = DesignTokens.Colors.nullText
            textField.font = DesignTokens.Fonts.grid
        case .null:
            textField.stringValue = "NULL"
            textField.textColor = DesignTokens.Colors.nullText
            textField.font = NSFontManager.shared.convert(DesignTokens.Fonts.grid, toHaveTrait: .italicFontMask)
        case let .bytes(data):
            textField.stringValue = "<\(data.count) bytes>"
            textField.textColor = DesignTokens.Colors.binaryText
            textField.font = DesignTokens.Fonts.grid
        case let .some(other):
            textField.stringValue = Self.displayText(for: other)
            textField.textColor = .labelColor
            textField.font = DesignTokens.Fonts.grid
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
            textField.attributedStringValue = NSAttributedString(
                string: textField.stringValue,
                attributes: [
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .font: DesignTokens.Fonts.grid,
                    .foregroundColor: NSColor.secondaryLabelColor,
                ]
            )
        }
        setAccessibilityValue(textField.stringValue)
        setAccessibilityLabel(textField.stringValue)
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

    private let textField = NSTextField(labelWithString: "")
    private var isSelected = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.alignment = .right
        textField.font = DesignTokens.Fonts.grid
        textField.textColor = .secondaryLabelColor
        textField.drawsBackground = false
        textField.isBordered = false
        textField.isEditable = false
        textField.isSelectable = false
        setAccessibilityRole(.staticText)
        setAccessibilityElement(true)
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    func configure(row: Int, isSelected: Bool) {
        self.isSelected = isSelected
        textField.stringValue = String(row + 1)
        textField.textColor = isSelected ? .labelColor : .secondaryLabelColor
        setAccessibilityLabel("Row \(row + 1)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        (isSelected
            ? NSColor.controlAccentColor.withAlphaComponent(0.25)
            : NSColor.controlBackgroundColor).setFill()
        bounds.fill()
        // No trailing hairline: the rows carry no column rules, only the header does.
    }
}

/// A column header whose title keeps the same 6-point margin the cells below it use.
///
/// The default cell draws its text hard against the column edge, which with the body's
/// separators aligned to that same edge leaves the label touching the line.
final class GridHeaderCell: NSTableHeaderCell {
    /// Matches `GridCellView`'s text insets, so a heading sits directly above its values.
    static let horizontalInset: CGFloat = 6

    override func drawInterior(withFrame cellFrame: NSRect, in controlView: NSView) {
        super.drawInterior(
            withFrame: cellFrame.insetBy(dx: Self.horizontalInset, dy: 0), in: controlView
        )
    }

    override func titleRect(forBounds rect: NSRect) -> NSRect {
        super.titleRect(forBounds: rect.insetBy(dx: Self.horizontalInset, dy: 0))
    }
}
