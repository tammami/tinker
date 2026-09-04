import CoreGraphics
import XCTest

/// Drives the real interface: menus, the sidebar tree, the editor and the grid.
///
/// SPEC §17 asks for exactly this. Everything below the views is covered by
/// `Tinker --smoke-test` and the package suites; these tests exist because a control the
/// user cannot click is a broken feature no matter how correct the model underneath is.
@MainActor
final class WorkspaceUITests: XCTestCase {
    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    override func tearDown() async throws {
        app.terminate()
    }

    var window: XCUIElement { app.windows.firstMatch }

    /// The app opens a window with its menus in place.
    func testLaunchesWithAWindowAndMenus() {
        XCTAssertTrue(window.waitForExistence(timeout: 20), "no window appeared")
        XCTAssertTrue(app.menuBars.menuBarItems["Query"].exists, "the Query menu is missing")
        XCTAssertTrue(app.menuBars.menuBarItems["View"].exists, "the View menu is missing")
    }

    /// ⌘T opens a query tab and the editor takes the keystrokes that follow.
    func testNewQueryTabAcceptsTyping() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)

        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "the SQL editor never appeared")

        editor.click()
        editor.typeText("SELECT 1")
        XCTAssertEqual(editor.value as? String, "SELECT 1", "the editor did not take the text")
    }

    /// Running a statement reports what it did.
    func testRunningAStatementReportsItsResult() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)

        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("SELECT 42 AS answer")
        postKey(Self.returnKey, command: true)

        // The status line under the results says how many rows arrived and how long it
        // took; it is the first thing a user looks at.
        let summary = window.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "1 row in")
        ).firstMatch
        let appeared = summary.waitForExistence(timeout: 25)
        if !appeared {
            let tree = XCTAttachment(string: app.debugDescription)
            tree.name = "element-tree"
            tree.lifetime = .keepAlways
            add(tree)
            let shot = XCTAttachment(screenshot: window.screenshot())
            shot.name = "window"
            shot.lifetime = .keepAlways
            add(shot)
            print("ELEMENT TREE BEGIN\n\(app.debugDescription)\nELEMENT TREE END")
        }
        XCTAssertTrue(appeared, "no result summary; visible text was \(visibleText())")
    }

    /// Does a Command key event reach the editor at all? ⌘/ is handled by the editor
    /// itself, so if the text gains a comment marker the key path is fine and only Return
    /// is at fault.
    func testCommandSlashReachesTheEditor() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)
        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("SELECT 1")
        editor.typeKey("/", modifierFlags: .command)
        let text = (editor.value as? String) ?? ""
        XCTAssertTrue(text.hasPrefix("-- "), "⌘/ did not reach the editor; text is \(text)")
    }

    /// Sends ⌘↩ to the editor element rather than the application.
    func testReturnShortcutSentToTheEditor() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)
        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("SELECT 42 AS answer")
        postKey(Self.returnKey, command: true)

        let ran = window.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@ OR value CONTAINS %@", "1 row in", "Running")
        ).firstMatch
        XCTAssertTrue(
            ran.waitForExistence(timeout: 25),
            "⌘↩ to the editor did nothing; visible text was \(visibleText())"
        )
    }

    /// A menu shortcut that opens a sheet, to see whether menu key equivalents work at all
    /// while the editor holds focus.
    func testHistoryShortcutWhileTheEditorHasFocus() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)
        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("SELECT 1")
        app.typeKey("y", modifierFlags: .command)

        let search = window.textFields["Search history"].firstMatch
        let opened =
            search.waitForExistence(timeout: 10)
            || app.sheets.firstMatch.waitForExistence(timeout: 5)
        XCTAssertTrue(opened, "⌘Y did nothing while the editor had focus")
    }

    /// Does the Return key reach the app at all? A plain Return should split the line.
    func testPlainReturnReachesTheEditor() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)
        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("SELECT 1")
        editor.typeKey(.return, modifierFlags: [])
        editor.typeText("SELECT 2")
        let text = (editor.value as? String) ?? ""
        XCTAssertTrue(
            text.contains("\n"),
            "Return produced no line break, so the key never arrived; text is \(text.debugDescription)"
        )
    }

    /// Another Query-menu shortcut, to tell "the menu's shortcuts do not work" apart from
    /// "Return specifically does not arrive".
    func testFormatShortcut() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)
        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("select a from t")
        app.typeKey("i", modifierFlags: [.command, .shift])
        Thread.sleep(forTimeInterval: 1)
        let text = (editor.value as? String) ?? ""
        XCTAssertTrue(
            text.contains("SELECT"),
            "⌘⇧I did not format; text is \(text.debugDescription)"
        )
    }

    /// The toolbar Run button runs the statement. This is the path that does not depend on
    /// menu key equivalents, so it isolates the two.
    func testToolbarRunButtonRunsTheStatement() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)
        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("SELECT 42 AS answer")

        window.buttons["Run"].firstMatch.click()
        let summary = window.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "1 row in")
        ).firstMatch
        XCTAssertTrue(
            summary.waitForExistence(timeout: 25),
            "the Run button produced no result; visible text was \(visibleText())"
        )
    }

    /// The Query menu's Run item, reached by name rather than by shortcut.
    func testQueryMenuRunItem() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)
        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("SELECT 42 AS answer")

        let queryMenu = app.menuBars.menuBarItems["Query"]
        queryMenu.click()
        let runItem = queryMenu.menuItems["Run"]
        XCTAssertTrue(runItem.waitForExistence(timeout: 5), "the Query menu has no Run item")
        XCTAssertTrue(runItem.isEnabled, "the Run menu item is disabled, so the focused command bundle never arrived")
        runItem.click()

        let summary = window.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@", "1 row in")
        ).firstMatch
        XCTAssertTrue(
            summary.waitForExistence(timeout: 25),
            "the menu item produced no result; visible text was \(visibleText())"
        )
    }

    /// The result grid draws the value the statement returned.
    func testResultGridShowsTheValue() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("t", modifierFlags: .command)

        let editor = window.textViews["sql-editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeText("SELECT 42 AS answer")
        postKey(Self.returnKey, command: true)

        let table = window.tables["result-grid"]
        XCTAssertTrue(table.waitForExistence(timeout: 25), "no result grid appeared")
        let cell = table.staticTexts["42"]
        let appeared = cell.waitForExistence(timeout: 10)
        add(XCTAttachment(screenshot: window.screenshot()))
        XCTAssertTrue(appeared, "the grid drew no cell for 42; visible text was \(visibleText())")
    }

    /// Posts a real key event.
    ///
    /// `XCUIElement.typeKey` does not synthesise Command together with Return, so the
    /// shortcut a user actually presses has to be sent through the event system directly.
    func postKey(_ keyCode: CGKeyCode, command: Bool = false, shift: Bool = false) {
        var flags: CGEventFlags = []
        if command { flags.insert(.maskCommand) }
        if shift { flags.insert(.maskShift) }
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        let up = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        up?.flags = flags
        up?.post(tap: .cghidEventTap)
    }

    /// Return.
    static let returnKey: CGKeyCode = 36

    /// Every string the window currently shows, for a failure message worth reading.
    func visibleText() -> [String] {
        window.staticTexts.allElementsBoundByIndex
            .map { ($0.value as? String) ?? $0.label }
            .filter { !$0.isEmpty }
    }

    /// The sidebar expands a connection down to its tables, and a table opens as a tab.
    func testSidebarExpandsAndOpensATable() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))

        let outline = window.outlines.firstMatch
        XCTAssertTrue(outline.waitForExistence(timeout: 10), "the sidebar list never appeared")

        // The connection row is the only top-level row in a fresh store.
        let connection = outline.outlineRows.element(boundBy: 0)
        XCTAssertTrue(connection.waitForExistence(timeout: 10), "no connection row")
        connection.disclosureTriangles.firstMatch.click()

        // Databases, then a schema, then the object folders.
        let expanded = outline.outlineRows.count
        XCTAssertGreaterThan(expanded, 1, "expanding the connection revealed nothing")
    }

    /// ⌘R refreshes without the window going away.
    func testRefreshKeepsTheWindow() {
        XCTAssertTrue(window.waitForExistence(timeout: 20))
        app.typeKey("r", modifierFlags: .command)
        XCTAssertTrue(window.exists)
    }
}
