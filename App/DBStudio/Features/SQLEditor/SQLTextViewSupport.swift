import AppKit
import DBCore
import DBSQL
import os

/// The text view itself: current-line highlight, comment toggling, auto-indent,
/// duplicate line, and the keys that run statements.
public final class SQLTextView: NSTextView {
    weak var coordinator: SQLEditorCoordinator?

    /// Key handling is subtle enough that it is worth being able to watch it from
    /// `log stream --predicate 'subsystem == "com.thinkfree.DBStudio"'`.
    static let keyLog = Logger(subsystem: "com.thinkfree.DBStudio", category: "editor-keys")

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

    /// `⌘↩` runs, `⌘⇧↩` runs everything, `⌘/` toggles line comments and `⌘D` duplicates
    /// the line (SPEC §10.2).
    ///
    /// These are answered here rather than left to the Query menu because the window's
    /// view tree gets key equivalents *before* the main menu does, and `NSTextView`
    /// swallows `⌘↩` on its way past. Handling it here is what makes the shortcut work at
    /// all while the editor has focus.
    public override func performKeyEquivalent(with event: NSEvent) -> Bool {
        Self.keyLog.info("performKeyEquivalent keyCode=\(event.keyCode) flags=\(event.modifierFlags.rawValue)")
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        // 36 is Return, 76 the keypad's Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            let all = event.modifierFlags.contains(.shift)
            MainActor.assumeIsolated {
                let hasCoordinator = self.coordinator != nil
                let hasDelegate = self.coordinator?.delegate != nil
                Self.keyLog.info("run shortcut: coordinator=\(hasCoordinator) delegate=\(hasDelegate)")
                self.coordinator?.delegate?.editorDidRequestRun(all: all)
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
            case 125: return coordinator.completion.moveSelection(by: 1)     // down
            case 126: return coordinator.completion.moveSelection(by: -1)    // up
            case 36, 48: return coordinator.completion.acceptSelection()     // return, tab
            case 53: return coordinator.completion.dismiss()                 // escape
            default: break
            }
        }
        // ⌃Space asks for the list without waiting for another character (SPEC §13.1).
        if event.keyCode == 49, event.modifierFlags.contains(.control) {
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
