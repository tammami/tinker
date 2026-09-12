import AppKit
import DBCore
import DBSQL
import SwiftUI

/// What the editor asks its tab to do.
@MainActor
public protocol SQLEditorDelegate: AnyObject {
    func editorDidChangeText(_ text: String)
    /// The caret, and how much is selected after it (0 when nothing is).
    func editorDidChangeSelection(offset: Int, length: Int)
    /// `.current` is Run: the highlighted text when there is some, else the statement under
    /// the cursor. `.selection` is only the highlighted text; `.all` the whole page.
    func editorDidRequestRun(_ scope: SQLRunScope, selection: Range<Int>?)
    /// Suggestions for the word at `caretOffset` (UTF-16, within `statement`); `prefix`
    /// is what is typed of it so far, and may be empty right after a space.
    func editorCompletionCandidates(prefix: String, statement: String, caretOffset: Int) -> [CompletionCandidate]
}

/// What a run command covers.
public enum SQLRunScope: Sendable {
    case current
    case selection
    case all
}

/// One autocomplete suggestion.
public struct CompletionCandidate: Identifiable, Hashable, Sendable {
    public enum Kind: String, Sendable {
        case keyword, table, column, function, schema
    }

    public let id = UUID()
    public let text: String
    public let detail: String?
    public let kind: Kind
    /// What goes into the editor when the candidate is chosen; `text` when nil. A function
    /// inserts `DATE()` while the list shows `DATE`.
    public let insertion: String?
    /// How far back from the end of the insertion the caret lands: 1 for `DATE()`, so the
    /// argument can be typed at once.
    public let caretShift: Int

    public init(text: String, detail: String? = nil, kind: Kind, insertion: String? = nil, caretShift: Int = 0) {
        self.text = text
        self.detail = detail
        self.kind = kind
        self.insertion = insertion
        self.caretShift = caretShift
    }

    /// A function from the catalog: shown with its signature, inserted with its parentheses.
    public init(function: SQLFunction) {
        self.init(
            text: function.name,
            detail: "\(function.signature)  ·  \(function.category.rawValue)",
            kind: .function,
            insertion: function.insertion,
            caretShift: function.takesNoParentheses ? 0 : 1
        )
    }

    public var symbolName: String {
        switch kind {
        case .keyword: "textformat.abc"
        case .table: "tablecells"
        case .column: "list.bullet"
        case .function: "function"
        case .schema: "square.stack.3d.up"
        }
    }
}

/// The SQL editor: an `NSTextView` with syntax highlighting,
/// current-line highlighting, bracket matching and autocomplete (SPEC §13.1).
public struct SQLEditorView: NSViewRepresentable {
    @Binding public var text: String
    public let dialect: SQLDialect
    public let fontName: String
    public let fontSize: Double
    /// Character offset of a server error, so the token can be marked.
    public let errorPosition: Int?
    /// False shows a definition with highlighting but takes no typing.
    public let isEditable: Bool
    /// Whether this editor's tab is in front. Tabs stay alive when hidden, so the editor
    /// takes focus when it comes to the front rather than only when it is created.
    public let isFront: Bool
    public weak var delegate: (any SQLEditorDelegate)?

    public init(
        text: Binding<String>,
        dialect: SQLDialect,
        fontName: String = "SF Mono",
        fontSize: Double = 13,
        errorPosition: Int? = nil,
        isEditable: Bool = true,
        isFront: Bool = true,
        delegate: (any SQLEditorDelegate)? = nil
    ) {
        _text = text
        self.dialect = dialect
        self.fontName = fontName
        self.fontSize = fontSize
        self.errorPosition = errorPosition
        self.isEditable = isEditable
        self.isFront = isFront
        self.delegate = delegate
    }

    public func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        // The whole editor is written against TextKit 1: the gutter measures lines with
        // `layoutManager`, the current-line highlight uses `boundingRect(forGlyphRange:)`,
        // and the highlighter edits `textStorage` directly. `NSTextView(frame:)` gives a
        // TextKit 2 view on current macOS, which lays the text out but draws none of it —
        // the gutter numbered the lines while the editor showed an empty page. Building
        // the TextKit 1 stack by hand is what keeps the view and the code that drives it
        // talking about the same thing.
        let contentSize = scrollView.contentSize
        let storage = NSTextStorage()
        let layoutManager = NSLayoutManager()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        )
        layoutManager.addTextContainer(container)
        let textView = SQLTextView(
            frame: NSRect(origin: .zero, size: contentSize), textContainer: container
        )
        textView.minSize = NSSize(width: 0, height: contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: contentSize.width, height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true

        textView.coordinator = context.coordinator
        textView.delegate = context.coordinator
        textView.isEditable = isEditable
        textView.isSelectable = true
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.allowsUndo = true
        // The system find bar: ⌘F, ⌘G and find-and-replace without a custom panel.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = DesignTokens.Fonts.editor(name: fontName, size: fontSize)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.setAccessibilityIdentifier("sql-editor")
        textView.string = text

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true

        // The line numbers live in the scroll view's own left inset: the content is
        // shifted by exactly the gutter's width, so the text can never be drawn under it.
        // Positioned by autoresizing rather than constraints — an `NSScrollView` tiles its
        // own subviews, and a constrained one drags the whole subtree into auto layout.
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(
            top: 0, left: SQLGutterView.width, bottom: 0, right: 0
        )
        let gutter = SQLGutterView(textView: textView, clipView: scrollView.contentView)
        gutter.frame = NSRect(
            x: 0, y: 0, width: SQLGutterView.width, height: scrollView.bounds.height
        )
        gutter.autoresizingMask = [.height]
        // Above the clip view, or the scrolled content draws over it.
        scrollView.addSubview(gutter, positioned: .above, relativeTo: scrollView.contentView)

        context.coordinator.gutter = gutter
        context.coordinator.textView = textView
        // A large document is highlighted around what is on screen; scrolling moves the
        // window, so it is re-done after a short pause once the scroll settles.
        gutter.onScroll = { [weak coordinator = context.coordinator] in
            guard let coordinator, coordinator.isLargeDocument else { return }
            coordinator.scheduleHighlighting()
        }
        context.coordinator.observeDismissRequests()
        context.coordinator.applyHighlighting()
        return scrollView
    }

    public func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.delegate = delegate
        coordinator.dialect = dialect
        coordinator.errorPosition = errorPosition
        guard let textView = coordinator.textView else { return }
        // The scroll view has no size when the gutter is created, so its height is set
        // here, once SwiftUI has laid the editor out.
        if let gutter = coordinator.gutter {
            gutter.frame = NSRect(
                x: 0, y: 0, width: SQLGutterView.width, height: scrollView.bounds.height
            )
            gutter.needsDisplay = true
        }
        // Only when it really changed: `NSTextView.font` writes the font over the whole
        // text storage, which invalidates the document's layout and drops the highlighter's
        // bold and italic runs. This runs on every keystroke — the binding above sees to
        // that — and setting the same font each time is what made the editor flicker.
        let wantedFont = DesignTokens.Fonts.editor(name: fontName, size: fontSize)
        if textView.font != wantedFont { textView.font = wantedFont }
        textView.isEditable = isEditable
        // The editor is the point of a query tab, so it takes focus as soon as it is on
        // screen, and again each time its tab comes back to the front.
        if isEditable, isFront, !coordinator.isFront, let window = textView.window {
            coordinator.isFront = true
            coordinator.hasTakenFocus = true
            window.makeFirstResponder(textView)
        } else if !isFront {
            coordinator.isFront = false
        }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(
                NSRange(
                    location: min(selected.location, text.utf16.count), length: 0
                ))
            coordinator.applyHighlighting()
        } else if coordinator.lastErrorPosition != errorPosition {
            coordinator.lastErrorPosition = errorPosition
            coordinator.applyHighlighting()
        }
    }

    public func makeCoordinator() -> SQLEditorCoordinator {
        SQLEditorCoordinator(text: $text, dialect: dialect, delegate: delegate)
    }

    /// A closed tab takes its editor's observers and its list with it.
    public static func dismantleNSView(_ nsView: NSScrollView, coordinator: SQLEditorCoordinator) {
        coordinator.stopObserving()
    }
}

/// Keeps the text view, the highlighting and the completion popover in step.
@MainActor
public final class SQLEditorCoordinator: NSObject, NSTextViewDelegate {
    @Binding var text: String
    var dialect: SQLDialect
    weak var delegate: (any SQLEditorDelegate)?
    weak var textView: SQLTextView?
    var errorPosition: Int?
    var lastErrorPosition: Int?
    /// The autocomplete list. One per editor, reused rather than rebuilt per keystroke.
    let completion = CompletionPopover()
    /// Closed when the tab runs a statement, which is the end of typing.
    private var dismissObserver: (any NSObjectProtocol)?
    weak var gutter: SQLGutterView?
    var hasTakenFocus = false
    var isFront = false
    private var highlightTask: Task<Void, Never>?

    init(text: Binding<String>, dialect: SQLDialect, delegate: (any SQLEditorDelegate)?) {
        _text = text
        self.dialect = dialect
        self.delegate = delegate
    }

    private var caretObserver: (any NSObjectProtocol)?
    private var offerObserver: (any NSObjectProtocol)?
    private var refreshObserver: (any NSObjectProtocol)?
    /// Where the word the list is about starts, so a caret that leaves it closes the list.
    private var offeredLocation: Int?
    /// Where the user pressed Escape on the list, so columns arriving a moment later do
    /// not bring it back at the same spot.
    private var suppressedLocation: Int?

    /// Removes every observer and puts the list away; called when the editor goes.
    func stopObserving() {
        for observer in [dismissObserver, offerObserver, refreshObserver, caretObserver] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        dismissObserver = nil
        offerObserver = nil
        refreshObserver = nil
        caretObserver = nil
        highlightTask?.cancel()
        completion.dismiss()
    }

    /// The user closed the list on purpose; it stays closed while the caret is here.
    func dismissByUser() {
        suppressedLocation = completionPrefixRange()?.location
        completion.dismiss()
    }

    /// Watches for the tab telling every editor to put its list away, and for a request
    /// to move the caret after text was inserted programmatically.
    func observeDismissRequests() {
        guard dismissObserver == nil else { return }
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .tinkerDismissCompletion, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.completion.dismiss() }
        }
        offerObserver = NotificationCenter.default.addObserver(
            forName: .tinkerOfferCompletion, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView, textView.window != nil else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
                self.offerCompletions()
            }
        }
        refreshObserver = NotificationCenter.default.addObserver(
            forName: .tinkerRefreshCompletion, object: nil, queue: .main
        ) { [weak self] _ in
            // Columns or tables arrived for the statement being typed: the list, if it is
            // up or was wanted here, now has them. One the user closed stays closed.
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView, textView.window?.firstResponder === textView
                else { return }
                let here = self.completionPrefixRange()?.location
                guard here != nil, here != self.suppressedLocation else { return }
                guard self.completion.isVisible || here == self.offeredLocation || self.offeredLocation == nil
                else { return }
                self.offerCompletions()
            }
        }
        caretObserver = NotificationCenter.default.addObserver(
            forName: .tinkerMoveCaret, object: nil, queue: .main
        ) { [weak self] notification in
            // Read outside the isolated block: the notification is not Sendable.
            let offset = notification.userInfo?["offset"] as? Int
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView, textView.window?.isKeyWindow == true,
                    let offset
                else { return }
                let clamped = min(max(0, offset), textView.string.utf16.count)
                textView.setSelectedRange(NSRange(location: clamped, length: 0))
                textView.scrollRangeToVisible(NSRange(location: clamped, length: 0))
            }
        }
    }

    public func textDidChange(_ notification: Notification) {
        guard let textView else { return }
        text = textView.string
        delegate?.editorDidChangeText(textView.string)
        // Only the caret's own line band, not the page: the text system already repaints
        // the glyphs that changed.
        textView.invalidateCurrentLine()
        gutter?.needsDisplay = true
        scheduleHighlighting()
        offerCompletions()
    }

    /// Closes the list and forgets it, for when the editor goes away entirely.
    func dismissCompletion() { completion.dismiss() }

    // MARK: - Autocomplete (SPEC §13.1)

    /// The word being typed, which is what the list completes and what accepting replaces.
    /// A dot is part of it, so `u.` offers that alias's columns.
    func completionPrefixRange() -> NSRange? {
        guard let textView else { return nil }
        let text = textView.string as NSString
        let caret = textView.selectedRange()
        guard caret.length == 0, caret.location <= text.length else { return nil }
        var start = caret.location
        while start > 0 {
            let character = text.character(at: start - 1)
            guard let scalar = Unicode.Scalar(character) else { break }
            let isWord =
                CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "." || scalar == "$"
            if !isWord { break }
            start -= 1
        }
        return NSRange(location: start, length: caret.location - start)
    }

    /// Shows the list, or hides it when there is nothing worth offering.
    ///
    /// Nothing typed yet is still worth asking about: after `FROM ` the tables are the
    /// answer, after `SELECT ` the columns; the tab decides from the statement.
    func offerCompletions() {
        guard let textView, let delegate else { return completion.dismiss() }
        guard let range = completionPrefixRange() else { return completion.dismiss() }
        let text = textView.string as NSString
        let prefix = text.substring(with: range)
        // The statement under the cursor is what makes the columns alias-aware.
        let statements = StatementSplitter.split(textView.string, dialect: dialect)
        let statement = statements.first {
            $0.utf16Range.contains(range.location) || $0.utf16Range.upperBound == range.location
        }
        let statementText = statement?.text ?? textView.string
        let caretOffset = range.location + range.length - (statement?.utf16Range.lowerBound ?? 0)

        let candidates = delegate.editorCompletionCandidates(
            prefix: prefix, statement: statementText, caretOffset: caretOffset)
        // The word is already complete: nothing to add.
        guard !candidates.isEmpty,
            !(candidates.count == 1 && candidates[0].text.caseInsensitiveCompare(prefix) == .orderedSame)
        else { return completion.dismiss() }
        // Typing on from where the list was closed is a new ask.
        if suppressedLocation == range.location, prefix.isEmpty { return completion.dismiss() }
        if suppressedLocation != range.location { suppressedLocation = nil }
        offeredLocation = range.location

        let caretRect = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let local = textView.convert(
            textView.window?.convertFromScreen(caretRect) ?? .zero, from: nil
        )
        completion.show(
            candidates: candidates, prefix: prefix, below: local, in: textView
        ) { [weak self] candidate in
            self?.accept(candidate, replacing: range)
        }
    }

    /// Puts the chosen text in place of what was typed.
    private func accept(_ candidate: CompletionCandidate, replacing range: NSRange) {
        guard let textView else { return }
        // A qualified prefix keeps its qualifier: `u.na` becomes `u.name`, not `name`.
        let typed = (textView.string as NSString).substring(with: range)
        let inserted = candidate.insertion ?? candidate.text
        let replacement: String
        if let dot = typed.lastIndex(of: ".") {
            replacement = String(typed[typed.startIndex ... dot]) + inserted
        } else {
            replacement = inserted
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
        if candidate.caretShift > 0 {
            // `DATE()` with the caret between the parentheses, ready for the argument.
            let end = range.location + (replacement as NSString).length
            textView.setSelectedRange(NSRange(location: max(range.location, end - candidate.caretShift), length: 0))
        }
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView else { return }
        let range = textView.selectedRange()
        delegate?.editorDidChangeSelection(offset: range.location, length: range.length)
        textView.invalidateCurrentLine()
        // The current line is marked in the gutter too, so it follows the caret.
        gutter?.needsDisplay = true
        highlightMatchingBracket()
        // Moving the caret off the word being completed makes the list about nothing.
        if completion.isVisible, completionPrefixRange()?.location != offeredLocation {
            completion.dismiss()
        }
    }

    /// Highlighting runs after a short pause so typing never waits on it.
    func scheduleHighlighting() {
        highlightTask?.cancel()
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.applyHighlighting()
        }
    }

    /// Colours keywords, strings, comments, numbers and placeholders, and marks the
    /// statement under the cursor plus any reported error position.
    /// Documents up to this many UTF-16 units are highlighted whole on every change; a
    /// pasted dump beyond it is highlighted around what is on screen and re-done as it
    /// scrolls, so a keystroke never re-tokenizes ten megabytes.
    static let fullHighlightLimit = 200_000
    /// How far past the visible text the window reaches, so a scroll of a page or two
    /// shows coloured text before the next pass catches up.
    private static let highlightPadding = 20_000

    /// True when the document is highlighted in windows rather than whole.
    var isLargeDocument: Bool { (textView?.textStorage?.length ?? 0) > Self.fullHighlightLimit }

    /// The range to highlight now: everything, or a window around the visible text.
    private func highlightWindow() -> NSRange {
        guard let textView, let storage = textView.textStorage else { return NSRange(location: 0, length: 0) }
        let full = NSRange(location: 0, length: storage.length)
        guard isLargeDocument,
            let layoutManager = textView.layoutManager,
            let container = textView.textContainer,
            let clipView = textView.enclosingScrollView?.contentView
        else { return full }
        var visible = clipView.documentVisibleRect
        visible.origin.y -= textView.textContainerInset.height
        let glyphs = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        let characters = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let start = max(0, characters.location - Self.highlightPadding)
        let end = min(storage.length, NSMaxRange(characters) + Self.highlightPadding)
        return NSRange(location: start, length: max(0, end - start))
    }

    func applyHighlighting() {
        guard let textView, let storage = textView.textStorage else { return }
        let window = highlightWindow()
        let font = textView.font ?? DesignTokens.Fonts.editor()
        // Tokens come from the window's own text; a window that opens inside a string or
        // a comment colours that one span wrongly until the next pass, which is the price
        // of not scanning the whole file on every keystroke.
        let source =
            window.length == storage.length ? textView.string : (textView.string as NSString).substring(with: window)

        let bold = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        let italic = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        let tokens = SQLTokenizer.tokenize(source, dialect: dialect)
        let functionNames = SQLFunctionCatalog.names(for: dialect)

        // How every stretch of the window should look, gaps between tokens included, so
        // the pass below can write only what is not already right.
        var wanted: [Style] = []
        var cursor = window.location
        for (index, token) in tokens.enumerated() {
            let range = NSRange(location: window.location + token.utf16Range.lowerBound, length: token.utf16Range.count)
            guard NSMaxRange(range) <= storage.length, range.location >= cursor else { continue }
            if range.location > cursor {
                wanted.append(Style(range: NSRange(location: cursor, length: range.location - cursor),
                                    color: .textColor, font: font))
            }
            cursor = NSMaxRange(range)
            switch token.kind {
            case .identifier where functionNames.contains(token.text.lowercased()):
                // A known function is one the engine documents, followed by its parentheses.
                let next = tokens[(index + 1)...].first { $0.kind != .whitespace }
                let isCall = next?.text == "("
                wanted.append(Style(range: range, color: isCall ? .systemIndigo : .textColor, font: font))
            case .keyword:
                wanted.append(Style(range: range, color: .systemPink, font: bold))
            case .string:
                wanted.append(Style(range: range, color: .systemRed, font: font))
            case .comment:
                wanted.append(Style(range: range, color: .systemGreen, font: italic))
            case .number:
                wanted.append(Style(range: range, color: .systemBlue, font: font))
            case .parameter:
                wanted.append(Style(range: range, color: .systemPurple, font: font))
            case .quotedIdentifier:
                wanted.append(Style(range: range, color: .systemTeal, font: font))
            case .identifier, .punctuation, .whitespace:
                wanted.append(Style(range: range, color: .textColor, font: font))
            }
        }
        if cursor < NSMaxRange(window) {
            wanted.append(Style(range: NSRange(location: cursor, length: NSMaxRange(window) - cursor),
                                color: .textColor, font: font))
        }

        storage.beginEditing()
        write(wanted, to: storage)

        // A red squiggle on the token the server complained about, cleared by the next edit.
        if let errorPosition, errorPosition > 0, errorPosition <= storage.length {
            let start = errorPosition - 1
            // Absolute offset, so the whole text, not the window.
            let token = SQLTokenizer.token(at: start, in: textView.string, dialect: dialect)
            let range =
                token.map { NSRange(location: $0.utf16Range.lowerBound, length: $0.utf16Range.count) }
                ?? NSRange(location: start, length: 1)
            if NSMaxRange(range) <= storage.length {
                storage.addAttributes(
                    [
                        .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                        .underlineColor: NSColor.systemRed,
                    ], range: range)
            }
        }
        storage.endEditing()
        // No blanket redraw: the attribute changes above already invalidate the runs they
        // touched, and repainting the page on every pass is what flickered.
        gutter?.needsDisplay = true
    }

    /// How one stretch of the document should be drawn.
    private struct Style {
        let range: NSRange
        let color: NSColor
        let font: NSFont
    }

    /// Writes only the attributes that are not already what they should be.
    ///
    /// Writing an attribute invalidates its range for display whether or not the value
    /// changed, and a font invalidates layout as well. Colouring the whole document on
    /// every keystroke therefore repainted the whole editor — that was the flicker. After
    /// an ordinary keystroke almost every stretch already looks right, so this writes
    /// little or nothing.
    private func write(_ styles: [Style], to storage: NSTextStorage) {
        for style in styles {
            // Collected first: the attributes must not be changed while they are enumerated.
            var wrong: [(range: NSRange, color: Bool, font: Bool, underline: Bool)] = []
            storage.enumerateAttributes(in: style.range, options: []) { existing, subrange, _ in
                let color = existing[.foregroundColor] as? NSColor != style.color
                let font = existing[.font] as? NSFont != style.font
                let underline = existing[.underlineStyle] != nil
                if color || font || underline {
                    wrong.append((subrange, color, font, underline))
                }
            }
            for piece in wrong {
                if piece.color { storage.addAttribute(.foregroundColor, value: style.color, range: piece.range) }
                if piece.font { storage.addAttribute(.font, value: style.font, range: piece.range) }
                if piece.underline {
                    storage.removeAttribute(.underlineStyle, range: piece.range)
                    storage.removeAttribute(.underlineColor, range: piece.range)
                }
            }
        }
    }

    /// Underlines the bracket matching the one next to the cursor.
    /// How far from the caret a matching bracket is looked for. Beyond it the pair is
    /// not marked, which costs nothing a person would notice; scanning a whole dump on
    /// every caret move did.
    private static let bracketScanLimit = 20_000

    /// The two cells last marked, so only they are cleared — not the whole document.
    private var markedBracketRanges: [NSRange] = []

    func highlightMatchingBracket() {
        guard let textView, let storage = textView.textStorage else { return }
        for range in markedBracketRanges where NSMaxRange(range) <= storage.length {
            storage.removeAttribute(.backgroundColor, range: range)
        }
        markedBracketRanges = []
        // `NSString` reads the buffer in place; `Array(string.utf16)` copied it on every
        // selection change.
        let text = textView.string as NSString
        let caret = textView.selectedRange().location
        guard caret > 0, caret <= text.length else { return }
        let index = caret - 1
        let scalar = text.character(at: index)
        let openers: [unichar] = [0x28, 0x5B, 0x7B]  // ( [ {
        let closers: [unichar] = [0x29, 0x5D, 0x7D]  // ) ] }
        var match: Int?
        if let position = openers.firstIndex(of: scalar) {
            var depth = 0
            let end = min(text.length, index + Self.bracketScanLimit)
            for probe in index ..< end {
                let candidate = text.character(at: probe)
                if candidate == openers[position] { depth += 1 }
                if candidate == closers[position] {
                    depth -= 1
                    if depth == 0 { match = probe; break }
                }
            }
        } else if let position = closers.firstIndex(of: scalar) {
            var depth = 0
            let start = max(0, index - Self.bracketScanLimit)
            for probe in stride(from: index, through: start, by: -1) {
                let candidate = text.character(at: probe)
                if candidate == closers[position] { depth += 1 }
                if candidate == openers[position] {
                    depth -= 1
                    if depth == 0 { match = probe; break }
                }
            }
        }
        guard let match else { return }
        for position in [index, match] {
            let range = NSRange(location: position, length: 1)
            storage.addAttribute(.backgroundColor, value: NSColor.selectedTextBackgroundColor, range: range)
            markedBracketRanges.append(range)
        }
    }
}

public extension Notification.Name {
    /// Posted when a query tab runs, so any open suggestion list closes.
    static let tinkerDismissCompletion = Notification.Name("TinkerDismissCompletion")
    /// Posted after text was inserted into the editor's model, with the new caret offset.
    static let tinkerMoveCaret = Notification.Name("TinkerMoveCaret")
    /// Asks the front editor to show its suggestion list, as ⌥Esc does.
    static let tinkerOfferCompletion = Notification.Name("TinkerOfferCompletion")
    /// Posted when tables or columns for the statement being typed have been read.
    static let tinkerRefreshCompletion = Notification.Name("TinkerRefreshCompletion")
    /// ⌘F outside the editor: whichever search field is on screen takes focus.
    static let tinkerFocusSearch = Notification.Name("TinkerFocusSearch")
}
