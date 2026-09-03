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
    /// `.all` runs the script, `.selection` the highlighted text, `.current` the statement
    /// under the cursor — or the selection when there is one, which is what ⌘↩ does.
    func editorDidRequestRun(_ scope: SQLRunScope, selection: Range<Int>?)
    func editorCompletionCandidates(prefix: String, statement: String) -> [CompletionCandidate]
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

    public init(text: String, detail: String? = nil, kind: Kind) {
        self.text = text
        self.detail = detail
        self.kind = kind
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
    public weak var delegate: (any SQLEditorDelegate)?

    public init(
        text: Binding<String>,
        dialect: SQLDialect,
        fontName: String = "SF Mono",
        fontSize: Double = 13,
        errorPosition: Int? = nil,
        isEditable: Bool = true,
        delegate: (any SQLEditorDelegate)? = nil
    ) {
        _text = text
        self.dialect = dialect
        self.fontName = fontName
        self.fontSize = fontSize
        self.errorPosition = errorPosition
        self.isEditable = isEditable
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
        textView.font = DesignTokens.Fonts.editor(name: fontName, size: fontSize)
        textView.isEditable = isEditable
        // The editor is the point of a query tab, so it takes focus as soon as it is on
        // screen rather than making the user click into it first.
        if isEditable, !coordinator.hasTakenFocus, let window = textView.window {
            coordinator.hasTakenFocus = true
            window.makeFirstResponder(textView)
        }
        if textView.string != text {
            let selected = textView.selectedRange()
            textView.string = text
            textView.setSelectedRange(NSRange(
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
    private var highlightTask: Task<Void, Never>?

    init(text: Binding<String>, dialect: SQLDialect, delegate: (any SQLEditorDelegate)?) {
        _text = text
        self.dialect = dialect
        self.delegate = delegate
    }

    private var caretObserver: (any NSObjectProtocol)?
    private var offerObserver: (any NSObjectProtocol)?

    /// Watches for the tab telling every editor to put its list away, and for a request
    /// to move the caret after text was inserted programmatically.
    func observeDismissRequests() {
        guard dismissObserver == nil else { return }
        dismissObserver = NotificationCenter.default.addObserver(
            forName: .dbstudioDismissCompletion, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.completion.dismiss() }
        }
        offerObserver = NotificationCenter.default.addObserver(
            forName: .dbstudioOfferCompletion, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let textView = self.textView, textView.window != nil else { return }
                textView.window?.makeFirstResponder(textView)
                textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))
                self.offerCompletions()
            }
        }
        caretObserver = NotificationCenter.default.addObserver(
            forName: .dbstudioMoveCaret, object: nil, queue: .main
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
        textView.needsDisplay = true
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
            let isWord = CharacterSet.alphanumerics.contains(scalar)
                || scalar == "_" || scalar == "." || scalar == "$"
            if !isWord { break }
            start -= 1
        }
        return NSRange(location: start, length: caret.location - start)
    }

    /// Shows the list, or hides it when there is nothing worth offering.
    func offerCompletions() {
        guard let textView, let delegate else { return completion.dismiss() }
        guard let range = completionPrefixRange(), range.length > 0 else {
            return completion.dismiss()
        }
        let text = textView.string as NSString
        let prefix = text.substring(with: range)
        // The statement under the cursor is what makes the columns alias-aware.
        let statement = StatementSplitter.split(textView.string, dialect: dialect)
            .first { $0.utf16Range.contains(range.location) }?.text ?? textView.string

        let candidates = delegate.editorCompletionCandidates(prefix: prefix, statement: statement)
        guard !candidates.isEmpty else { return completion.dismiss() }

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
        let replacement: String
        if let dot = typed.lastIndex(of: ".") {
            replacement = String(typed[typed.startIndex ... dot]) + candidate.text
        } else {
            replacement = candidate.text
        }
        guard textView.shouldChangeText(in: range, replacementString: replacement) else { return }
        textView.replaceCharacters(in: range, with: replacement)
        textView.didChangeText()
    }

    public func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView else { return }
        let range = textView.selectedRange()
        delegate?.editorDidChangeSelection(offset: range.location, length: range.length)
        textView.needsDisplay = true
        // The current line is marked in the gutter too, so it follows the caret.
        gutter?.needsDisplay = true
        highlightMatchingBracket()
        // Moving the caret off the word being completed makes the list about nothing.
        if completion.isVisible, (completionPrefixRange()?.length ?? 0) == 0 {
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
    func applyHighlighting() {
        guard let textView, let storage = textView.textStorage else { return }
        let source = textView.string
        let full = NSRange(location: 0, length: storage.length)
        let font = textView.font ?? DesignTokens.Fonts.editor()

        storage.beginEditing()
        storage.setAttributes([.font: font, .foregroundColor: NSColor.textColor], range: full)

        for token in SQLTokenizer.tokenize(source, dialect: dialect) {
            let range = NSRange(location: token.utf16Range.lowerBound, length: token.utf16Range.count)
            guard NSMaxRange(range) <= storage.length else { continue }
            switch token.kind {
            case .keyword:
                storage.addAttributes([
                    .foregroundColor: NSColor.systemPink,
                    .font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                ], range: range)
            case .string:
                storage.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range)
            case .comment:
                storage.addAttributes([
                    .foregroundColor: NSColor.systemGreen,
                    .font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask),
                ], range: range)
            case .number:
                storage.addAttribute(.foregroundColor, value: NSColor.systemBlue, range: range)
            case .parameter:
                storage.addAttribute(.foregroundColor, value: NSColor.systemPurple, range: range)
            case .quotedIdentifier:
                storage.addAttribute(.foregroundColor, value: NSColor.systemTeal, range: range)
            case .identifier, .punctuation, .whitespace:
                break
            }
        }

        // A red squiggle on the token the server complained about, cleared by the next edit.
        if let errorPosition, errorPosition > 0, errorPosition <= storage.length {
            let start = errorPosition - 1
            let token = SQLTokenizer.token(at: start, in: source, dialect: dialect)
            let range = token.map { NSRange(location: $0.utf16Range.lowerBound, length: $0.utf16Range.count) }
                ?? NSRange(location: start, length: 1)
            if NSMaxRange(range) <= storage.length {
                storage.addAttributes([
                    .underlineStyle: NSUnderlineStyle.thick.rawValue | NSUnderlineStyle.patternDot.rawValue,
                    .underlineColor: NSColor.systemRed,
                ], range: range)
            }
        }
        storage.endEditing()
        textView.needsDisplay = true
        gutter?.needsDisplay = true
    }

    /// Underlines the bracket matching the one next to the cursor.
    func highlightMatchingBracket() {
        guard let textView, let storage = textView.textStorage else { return }
        storage.removeAttribute(
            .backgroundColor, range: NSRange(location: 0, length: storage.length)
        )
        let units = Array(textView.string.utf16)
        let caret = textView.selectedRange().location
        guard caret > 0, caret <= units.count else { return }
        let index = caret - 1
        guard let scalar = Unicode.Scalar(units[index]) else { return }
        let openers: [Unicode.Scalar] = ["(", "[", "{"]
        let closers: [Unicode.Scalar] = [")", "]", "}"]
        var match: Int?
        if let position = openers.firstIndex(of: scalar) {
            var depth = 0
            for probe in index ..< units.count {
                guard let candidate = Unicode.Scalar(units[probe]) else { continue }
                if candidate == openers[position] { depth += 1 }
                if candidate == closers[position] {
                    depth -= 1
                    if depth == 0 { match = probe; break }
                }
            }
        } else if let position = closers.firstIndex(of: scalar) {
            var depth = 0
            for probe in stride(from: index, through: 0, by: -1) {
                guard let candidate = Unicode.Scalar(units[probe]) else { continue }
                if candidate == closers[position] { depth += 1 }
                if candidate == openers[position] {
                    depth -= 1
                    if depth == 0 { match = probe; break }
                }
            }
        }
        guard let match else { return }
        for position in [index, match] {
            storage.addAttribute(
                .backgroundColor,
                value: NSColor.selectedTextBackgroundColor,
                range: NSRange(location: position, length: 1)
            )
        }
    }
}


public extension Notification.Name {
    /// Posted when a query tab runs, so any open suggestion list closes.
    static let dbstudioDismissCompletion = Notification.Name("DBStudioDismissCompletion")
    /// Posted after text was inserted into the editor's model, with the new caret offset.
    static let dbstudioMoveCaret = Notification.Name("DBStudioMoveCaret")
    /// Asks the front editor to show its suggestion list, as ⌃Space does.
    static let dbstudioOfferCompletion = Notification.Name("DBStudioOfferCompletion")
}
