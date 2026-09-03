import AppKit
import DBCore
import DBGrid

/// One grid cell.
///
/// A plain `NSView` that draws its own background and hosts one `NSTextField`, rather than
/// a stack of subviews: at 22 points a row and thousands of visible cells, every extra
/// view costs frame time (SPEC §12.1).
final class GridCellView: NSView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("DBStudio.GridCell")

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

        backgroundColor = switch changeState {
        case .edited: DesignTokens.Colors.editedCell
        case .inserted: DesignTokens.Colors.insertedRow
        case .deleted: DesignTokens.Colors.deletedRow
        case .unchanged: isSelected ? .selectedContentBackgroundColor.withAlphaComponent(0.35) : .clear
        }
        if changeState != .unchanged, isSelected {
            backgroundColor = backgroundColor.blended(withFraction: 0.3, of: .selectedContentBackgroundColor)
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
        needsDisplay = true
    }

    /// The text a cell shows: long values are cut here and shown in full in the inspector.
    static func displayText(for value: DBValue) -> String {
        switch value {
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
        // A one-pixel separator, drawn here rather than by a grid style so it stays
        // crisp at every backing-scale factor.
        NSColor.separatorColor.withAlphaComponent(0.5).setFill()
        NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()

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
