import AppKit
import DBCore
import DBSQL
import os

/// The text view itself: current-line highlight, comment toggling, auto-indent,
/// duplicate line, and the keys that run statements.
public final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditorCoordinator?

    /// Key handling is subtle enough that it is worth being able to watch it from
    /// `log stream --predicate 'subsystem == "com.thinkfree.Tinker"'`.
    static let keyLog = Logger(subsystem: "com.thinkfree.Tinker", category: "editor-keys")

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

    /// `⌘R` runs the statement at the cursor, `⌘⌥R` the page, `⌘/` toggles line comments and `⌘D` duplicates
    /// the line (SPEC §10.2).
    ///
    /// These are answered here rather than left to the Query menu because the window's
    /// view tree gets key equivalents *before* the main menu does, and `NSTextView`
    /// may swallow a key on its way past. Handling it here is what makes the shortcut work at
    /// all while the editor has focus.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Self.keyLog.info("performKeyEquivalent keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // ⌘R runs the statement at the cursor (or the highlighted block), ⌘⇧R only the
        // selection, ⌘⌥R the whole page. Answered here because the editor sees key
        // equivalents before the menu does; the menu carries the same three.
        if event.charactersIgnoringModifiers?.lowercased() == "r" {
            let scope: SQLRunScope =
                event.modifierFlags.contains(.option)
                ? .all : event.modifierFlags.contains(.shift) ? .selection : .current
            let selected = selectedRange()
            let selection: Range<Int>? = selected.length > 0 ? selected.location ..< NSMaxRange(selected) : nil
            MainActor.assumeIsolated {
                self.coordinator?.delegate?.editorDidRequestRun(scope, selection: selection)
            }
            return true
        }
        guard !event.modifierFlags.contains(.shift), !event.modifierFlags.contains(.option) else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers ?? "" {
        case "/":
            toggleLineComment()
            return true
        case "d":
            duplicateLine()
            return true
        default:
            return super.performKeyEquivalent(with: event)
        }
    }

    /// Escape reaches an `NSTextView` as `cancelOperation`, not as a plain `keyDown`, so
    /// the list has to be closed from both or it cannot be dismissed at all.
    public override func cancelOperation(_ sender: Any?) {
        if let coordinator, coordinator.completion.isVisible {
            coordinator.completion.dismiss()
            return
        }
        super.cancelOperation(sender)
    }

    /// Clicking into the text, or anywhere else, closes the list.
    public override func mouseDown(with event: NSEvent) {
        coordinator?.completion.dismiss()
        super.mouseDown(with: event)
    }

    public override func resignFirstResponder() -> Bool {
        coordinator?.completion.dismiss()
        return super.resignFirstResponder()
    }

    public override func keyDown(with event: NSEvent) {
        Self.keyLog.info("keyDown keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")

        // While the autocomplete list is up it takes the arrows, Return, Tab and Escape.
        // It never becomes key, so the keys arrive here and are forwarded by hand.
        if let coordinator, coordinator.completion.isVisible {
            switch event.keyCode {
            case 125: return coordinator.completion.moveSelection(by: 1)  // down
            case 126: return coordinator.completion.moveSelection(by: -1)  // up
            case 36, 48: return coordinator.completion.acceptSelection()  // return, tab
            case 53: return coordinator.completion.dismiss()  // escape
            default: break
            }
        }
        // ⌥Esc asks for the list without waiting for another character, as Xcode does;
        // ⌃Space belongs to macOS, which uses it to switch input sources.
        if event.keyCode == 53, event.modifierFlags.contains(.option) {
            coordinator?.offerCompletions()
            return
        }
        super.keyDown(with: event)
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
        let allCommented =
            !meaningful.isEmpty
            && meaningful.allSatisfy {
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

/// The line numbers beside the editor (SPEC §13.1).
///
/// A plain view laid out next to the scroll view, not an `NSRulerView`. Inside a SwiftUI
/// `NSViewRepresentable` a ruler never took the width it reserved and painted across the
/// text instead of beside it; here the layout is the container's and every coordinate is
/// this view's own.
public final class SQLGutterView: NSView {
    public static let width: CGFloat = 46

    weak var textView: NSTextView?
    weak var clipView: NSClipView?
    private var scrollObserver: (any NSObjectProtocol)?

    public override var isFlipped: Bool { true }

    init(textView: NSTextView, clipView: NSClipView) {
        self.textView = textView
        self.clipView = clipView
        super.init(frame: .zero)
        wantsLayer = true

        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clipView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.needsDisplay = true }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The observer goes when the view leaves the window. `deinit` cannot touch it: it is
    /// not isolated to the main actor and the token is not `Sendable`.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window == nil, let scrollObserver else { return }
        NotificationCenter.default.removeObserver(scrollObserver)
        self.scrollObserver = nil
    }

    public override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()
        NSColor.separatorColor.setStroke()
        let border = NSBezierPath()
        border.move(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.minY))
        border.line(to: NSPoint(x: bounds.maxX - 0.5, y: bounds.maxY))
        border.stroke()

        guard let textView,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer,
            let clipView
        else { return }

        let text = textView.string as NSString
        // What the scroll view is showing, in the text view's coordinates.
        let visible = clipView.documentVisibleRect
        let caretLine = text.lineRange(
            for: NSRange(location: min(textView.selectedRange().location, text.length), length: 0)
        )

        let regular = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        let bold = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .bold)
        var index = 0
        var lineNumber = 1

        while true {
            let lineRange = text.lineRange(for: NSRange(location: index, length: 0))
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange, actualCharacterRange: nil
            )
            var lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
            lineRect.origin.y += textView.textContainerInset.height
            // Into this view's coordinates: the same y, less however far it has scrolled.
            let y = lineRect.minY - visible.minY

            if y + lineRect.height >= 0, y <= bounds.height {
                let isCurrent = NSEqualRanges(lineRange, caretLine)
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: isCurrent ? bold : regular,
                    .foregroundColor: isCurrent ? NSColor.labelColor : NSColor.tertiaryLabelColor,
                ]
                let label = "\(lineNumber)" as NSString
                let size = label.size(withAttributes: attributes)
                label.draw(
                    at: NSPoint(
                        x: bounds.maxX - size.width - 8,
                        y: y + (lineRect.height - size.height) / 2
                    ),
                    withAttributes: attributes
                )
            }

            let next = NSMaxRange(lineRange)
            if lineRange.length == 0 || next >= text.length { break }
            index = next
            lineNumber += 1
            if y > bounds.height { break }
        }
    }
}
