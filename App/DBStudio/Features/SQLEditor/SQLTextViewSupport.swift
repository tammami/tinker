import AppKit
import DBCore
import DBSQL

/// The text view itself: current-line highlight, comment toggling, auto-indent,
/// duplicate line, and the keys that run statements.
public final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditorCoordinator?

    /// Takes focus as soon as the editor is placed in a window, so a new query tab is
    /// ready to type into.
    ///
    /// Both steps are needed: `initialFirstResponder` covers the window becoming key
    /// later, and the deferred `makeFirstResponder` covers a tab opened in a window that
    /// is already key.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        window.initialFirstResponder = self
        Task { @MainActor in
            guard self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager, let container = textContainer else { return }
        let caret = selectedRange()
        guard caret.length == 0, caret.location <= string.utf16.count else { return }
        let lineRange = (string as NSString).lineRange(for: NSRange(location: caret.location, length: 0))
        let glyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
        var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        lineRect.origin.x = 0
        lineRect.size.width = bounds.width
        lineRect = lineRect.offsetBy(dx: textContainerInset.width, dy: textContainerInset.height)
        NSColor.selectedTextBackgroundColor.withAlphaComponent(0.18).setFill()
        lineRect.fill()
    }

    /// `⌘/` toggles line comments, `⌘D` duplicates the line, `⌘↩` runs (SPEC §10.2).
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        let characters = event.charactersIgnoringModifiers ?? ""
        switch characters {
        case "/":
            toggleLineComment()
            return true
        case "d":
            duplicateLine()
            return true
        case "\r":
            MainActor.assumeIsolated {
                coordinator?.delegate?.editorDidRequestRun(all: event.modifierFlags.contains(.shift))
            }
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    public override func insertNewline(_ sender: Any?) {
        super.insertNewline(sender)
        autoIndent()
    }

    /// Repeats the previous line's leading whitespace, and adds a level after an opener.
    func autoIndent() {
        let text = string as NSString
        let caret = selectedRange().location
        guard caret > 1 else { return }
        let previousLine = text.lineRange(for: NSRange(location: caret - 1, length: 0))
        let line = text.substring(with: previousLine)
        var indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("(") || trimmed.uppercased().hasSuffix("BEGIN") { indent += "    " }
        guard !indent.isEmpty else { return }
        insertText(indent, replacementRange: selectedRange())
    }

    /// Comments the selected lines, or uncomments them when they already are.
    func toggleLineComment() {
        let text = string as NSString
        let range = text.lineRange(for: selectedRange())
        let block = text.substring(with: range)
        let lines = block.components(separatedBy: "\n")
        let meaningful = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !meaningful.isEmpty && meaningful.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("--")
        }
        let updated = lines.map { line -> String in
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return line }
            if allCommented {
                guard let position = line.range(of: "--") else { return line }
                var stripped = line
                stripped.removeSubrange(position)
                if stripped.hasPrefix(" ") == false, stripped.first == " " { stripped.removeFirst() }
                return stripped
            }
            let indent = String(line.prefix { $0 == " " || $0 == "\t" })
            return indent + "-- " + line.dropFirst(indent.count)
        }.joined(separator: "\n")

        guard shouldChangeText(in: range, replacementString: updated) else { return }
        textStorage?.replaceCharacters(in: range, with: updated)
        didChangeText()
        setSelectedRange(NSRange(location: range.location, length: (updated as NSString).length))
    }

    func duplicateLine() {
        let text = string as NSString
        let range = text.lineRange(for: selectedRange())
        var block = text.substring(with: range)
        if !block.hasSuffix("\n") { block += "\n" }
        let insertion = NSRange(location: NSMaxRange(range), length: 0)
        guard shouldChangeText(in: insertion, replacementString: block) else { return }
        textStorage?.replaceCharacters(in: insertion, with: block)
        didChangeText()
    }
}

/// Draws line numbers beside the editor, with the current line emphasised.
public final class LineNumberGutter: NSRulerView {


    public init(textView: NSTextView) {
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    public override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? NSTextView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer
        else { return }

        NSColor.controlBackgroundColor.setFill()
        rect.fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.maxX - 0.5, y: rect.minY))
        border.line(to: NSPoint(x: bounds.maxX - 0.5, y: rect.maxY))
        border.stroke()

        let text = textView.string as NSString
        let visibleRect = scrollView?.contentView.bounds ?? .zero
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        let caretLineRange = text.lineRange(for: NSRange(location: min(textView.selectedRange().location, text.length), length: 0))

        var lineNumber = 1
        // Counting from the start keeps numbering correct without tracking line starts.
        text.enumerateSubstrings(
            in: NSRange(location: 0, length: characterRange.location),
            options: [.byLines, .substringNotRequired]
        ) { _, _, _, _ in lineNumber += 1 }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        var index = characterRange.location
        while index < NSMaxRange(characterRange) {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            var lineRect = layoutManager.boundingRect(forGlyphRange: lineGlyphRange, in: container)
            lineRect.origin.y += textView.textContainerInset.height - visibleRect.origin.y

            let isCurrent = NSEqualRanges(lineRange, caretLineRange)
            let label = "\(lineNumber)" as NSString
            let attributes: [NSAttributedString.Key: Any] = [
                .font: isCurrent ? NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold) : font,
                .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
            ]
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: NSPoint(x: ruleThickness - size.width - 8, y: lineRect.minY + (lineRect.height - size.height) / 2),
                withAttributes: attributes
            )
            lineNumber += 1
            index = NSMaxRange(lineRange)
            if lineRange.length == 0 { break }
        }
    }
}
