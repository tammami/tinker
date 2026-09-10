import Foundation

/// One page of the built-in help: a title in the sidebar, sections on the right.
struct HelpTopic: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let sections: [HelpSection]

    /// Everything the search field matches against.
    var searchText: String {
        ([title, summary] + sections.flatMap(\.searchText)).joined(separator: " ").lowercased()
    }
}

/// A heading with paragraphs, a shortcut table, or both.
struct HelpSection: Hashable {
    let heading: String?
    var paragraphs: [String] = []
    var shortcuts: [HelpShortcut] = []

    var searchText: [String] {
        [heading ?? ""] + paragraphs + shortcuts.flatMap { [$0.action, $0.keys] }
    }
}

/// A key combination and what it does, as shown in the Keyboard Shortcuts page.
struct HelpShortcut: Hashable {
    let keys: String
    let action: String
}

/// Where the help points outside the app. One place, so a moved repository is one edit.
enum HelpLinks {
    static let repository = URL(string: "https://github.com/tammami/tinker")
    static let issues = URL(string: "https://github.com/tammami/tinker/issues/new")
    static let releaseNotes = URL(string: "https://github.com/tammami/tinker/blob/main/CHANGELOG.md")
}

/// The help pages. Text lives here, not in views, so a page reads as one document and a
/// test can check that every menu shortcut is documented.
enum HelpContent {
    static let shortcutsTopicID = "shortcuts"

    static let topics: [HelpTopic] = [
        HelpTopic(
            id: "start", title: "Getting Started", icon: "sparkles",
            summary: "Add a connection, open a table, run a query.",
            sections: [
                HelpSection(
                    heading: "Add a connection",
                    paragraphs: [
                        "Choose Database › New Connection… (⌘⌥N) or press + at the bottom of the sidebar. Pick the engine — PostgreSQL, MySQL/MariaDB or SQLite — and fill in host, port, user and password. Test connects once and reports the server's own words if anything is wrong.",
                        "Passwords go to the macOS Keychain and nowhere else. The connection file on disk holds only a reference.",
                        "A SQLite database is a file: drop a .sqlite or .db file on the window, open it from Finder, or use File › Open SQLite Database… (⌘⌥O).",
                    ]),
                HelpSection(
                    heading: "Folders",
                    paragraphs: [
                        "Connections can be grouped into folders in the sidebar (Database › New Folder…, or drag a connection onto a folder). Two connections may share a name when they sit in different folders; every connection picker in the app shows the folder in front of the name — Office › MySQL — so they never look alike."
                    ]),
                HelpSection(
                    heading: "Open a table",
                    paragraphs: [
                        "Expand a connection in the sidebar to see its databases, schemas and tables. Double-click a table to open it in a tab, or press ⌘⇧O and type part of its name.",
                        "The grid pages on the server, one page in memory at a time, so a table with millions of rows opens as fast as a small one.",
                    ]),
                HelpSection(
                    heading: "Run a query",
                    paragraphs: [
                        "Press ⌘T for a query tab. The pop-ups in its toolbar choose the connection and the database (or schema) unqualified names resolve against.",
                        "⌘R runs the statement under the cursor or the highlighted block; ⌘⌃R runs only the selection; ⌘⌥R runs everything. ⌘. cancels on the server.",
                    ]),
            ]),
        HelpTopic(
            id: "connections", title: "Connections", icon: "server.rack",
            summary: "Production mode, read-only, SSH tunnels and TLS.",
            sections: [
                HelpSection(
                    heading: "Production",
                    paragraphs: [
                        "Mark a connection as production in its editor. It shows a red PROD badge in the sidebar and in pickers, never auto-commits, and asks you to type the connection's name before any write, import, paste or synchronization runs against it."
                    ]),
                HelpSection(
                    heading: "Read-only",
                    paragraphs: [
                        "A read-only connection is enforced on the server session, not only in the interface: the session is set read-only on every lease, so a stray UPDATE is refused by the server itself. Query › Toggle Read-Only (⌘⇧L) unlocks a tab on purpose."
                    ]),
                HelpSection(
                    heading: "SSH and TLS",
                    paragraphs: [
                        "Open the SSH section of the connection editor to reach a server through a bastion: password, key file (with passphrase) or an agent, with a host-key policy you choose. TLS is on by default for new connections; the transport actually negotiated is verified and shown as a lock in the status bar."
                    ]),
                HelpSection(
                    heading: "Colours and folders",
                    paragraphs: [
                        "Give a connection a colour and every tab on it carries a stripe of that colour. Folders keep dev, staging and production apart in the sidebar; drag a connection onto a folder to move it."
                    ]),
            ]),
        HelpTopic(
            id: "grid", title: "Browsing Data", icon: "tablecells",
            summary: "Paging, filters, sorting, the inspector and the map.",
            sections: [
                HelpSection(
                    heading: "Paging and sorting",
                    paragraphs: [
                        "The pager in the status bar moves through the table a page at a time; the page size is remembered per table. Click a column header to sort on the server; click again to reverse."
                    ]),
                HelpSection(
                    heading: "Filters",
                    paragraphs: [
                        "⌘⇧F shows the filter bar. Each condition compiles to a parameterised WHERE clause — nothing you type is pasted into SQL — and conditions join with AND or OR. The quick search field in the toolbar matches text across the visible columns."
                    ]),
                HelpSection(
                    heading: "Inspector",
                    paragraphs: [
                        "⌘⌥I opens the inspector for the selected cell: the full value, a hex dump for binary, pretty-printed JSON, a date picker for timestamps, and a map for geometry. Long values are never truncated there."
                    ]),
                HelpSection(
                    heading: "Foreign keys",
                    paragraphs: [
                        "A foreign-key cell shows what it points at beside the key, resolved once per page. Editing such a cell offers Choose from Referenced Table… (⌥↓), which searches the referenced table on the server."
                    ]),
                HelpSection(
                    heading: "Map",
                    paragraphs: [
                        "Table tabs and query results with a geometry column have a Map mode: PostGIS, MySQL spatial and WKT values are drawn on a real map, and selecting a row highlights its shape."
                    ]),
            ]),
        HelpTopic(
            id: "editing", title: "Editing Data", icon: "pencil",
            summary: "Every change is SQL you preview, in a transaction that checks itself.",
            sections: [
                HelpSection(
                    heading: "How writes work",
                    paragraphs: [
                        "Edit a cell in place, add a row with ⌘+, delete rows with ⌘−, set NULL with ⌘⌫. With auto-commit off, nothing reaches the server until you commit (⌘⇧S) and Rollback (⌘⇧R) discards everything pending; with it on, a delete asks before it runs.",
                        "Commit shows the exact statements first. Every UPDATE and DELETE targets the primary key with the row's original values and runs inside one transaction that verifies each statement touched exactly one row; otherwise the whole transaction rolls back and the server's message is shown verbatim.",
                    ]),
                HelpSection(
                    heading: "Auto-commit",
                    paragraphs: [
                        "The Auto-commit switch in the grid toolbar writes each edit as soon as you leave the cell (a new row when the selection leaves it). It is never on for a production connection."
                    ]),
                HelpSection(
                    heading: "Editable query results",
                    paragraphs: [
                        "A SELECT from one table whose primary key is in the result can be edited like the table itself. Columns that are expressions stay read-only."
                    ]),
                HelpSection(
                    heading: "Copy and paste",
                    paragraphs: [
                        "Edit › Copy As offers CSV, JSON, Markdown, aligned text, a WHERE-IN list and INSERT statements (⌘⌃C). Paste into Grid fills cells from the clipboard, column by column."
                    ]),
            ]),
        HelpTopic(
            id: "query", title: "SQL Editor", icon: "text.alignleft",
            summary: "Completion, Beautify, Explain, snippets and history.",
            sections: [
                HelpSection(
                    heading: "Completion",
                    paragraphs: [
                        "Completions appear as you type and know your aliases: after FROM users u, typing u. lists that table's columns. ⌥Esc shows them on demand. Sources follow the tab's connection and database."
                    ]),
                HelpSection(
                    heading: "Beautify and Explain",
                    paragraphs: [
                        "Query › Beautify SQL (⌘⇧I) formats the statement with one clause per line and keeps every token. Explain (⌘⇧E) shows the plan; Explain Analyze runs it."
                    ]),
                HelpSection(
                    heading: "Results",
                    paragraphs: [
                        "Each statement gets a result tab: Message, Result, Profile and Status. A SELECT pages on the server like a table. ⌘⌥← and ⌘⌥→ move between results."
                    ]),
                HelpSection(
                    heading: "Snippets and history",
                    paragraphs: [
                        "⌘⇧K opens snippets; a snippet with placeholders tabs through them. ⌘Y opens the history of every statement that ran, with its duration and outcome; literals are redacted before anything is stored."
                    ]),
                HelpSection(
                    heading: "Files",
                    paragraphs: [
                        "File › Open SQL File… (⌘O) opens a script in a new tab; Save Query… (⌘S) writes the tab out. A large dump opens streamed, statement by statement, and DELIMITER $$ blocks are handled."
                    ]),
            ]),
        HelpTopic(
            id: "structure", title: "Structure and Objects", icon: "square.grid.3x3",
            summary: "Columns, indexes, keys, the objects overview and the query builder.",
            sections: [
                HelpSection(
                    heading: "Structure editor",
                    paragraphs: [
                        "A table tab's Structure mode lists columns, indexes, foreign keys, checks and triggers. Add or change a column and Preview shows the ALTER statements before they run. The Source tab shows the CREATE statement as the server would write it."
                    ]),
                HelpSection(
                    heading: "Objects",
                    paragraphs: [
                        "Open a database or schema to see every object with its kind, estimated rows, size, engine, collation and owner. Estimates are labelled as estimates."
                    ]),
                HelpSection(
                    heading: "Query Builder",
                    paragraphs: [
                        "Database › Query Builder (⌘⇧B) draws tables on a canvas, joins them by dragging, and writes the SQL live. Save View turns the canvas into a view; a view made in the builder reopens there."
                    ]),
                HelpSection(
                    heading: "New table",
                    paragraphs: [
                        "Database › New Table… (⌘⇧N) opens a designer for the schema in front; the DDL is shown before it runs."
                    ]),
            ]),
        HelpTopic(
            id: "tools", title: "Tools", icon: "wrench.and.screwdriver",
            summary: "Dump, import, transfer, synchronization, export and CSV import.",
            sections: [
                HelpSection(
                    heading: "Dump and import",
                    paragraphs: [
                        "Tools › Dump Database… writes structure and data to a .sql or .sql.gz file, streamed so a large database never sits in memory. Tools › Import SQL File… runs a script the same way, in batched transactions, with COPY blocks on PostgreSQL."
                    ]),
                HelpSection(
                    heading: "Data Transfer",
                    paragraphs: [
                        "Tools › Data Transfer… (⌘⇧T) copies tables, views and functions from one database to another — across engines if needed — or to a file. The connection pickers name each connection with its folder, so Localhost › MySQL and Office › MySQL read apart."
                    ]),
                HelpSection(
                    heading: "Data and Structure Synchronization",
                    paragraphs: [
                        "Data Synchronization compares the target's rows against the source's by primary key and shows what would be inserted, updated and deleted before anything is applied. Structure Synchronization writes the DDL that would make the target's tables match; statements that discard data are listed commented out."
                    ]),
                HelpSection(
                    heading: "Copy and paste objects",
                    paragraphs: [
                        "Right-click a table, schema or database in the sidebar and choose Copy; Paste on another connection rebuilds it there, with keys and indexes."
                    ]),
                HelpSection(
                    heading: "Export and CSV import",
                    paragraphs: [
                        "File › Export Result… (⌘⌥E) writes CSV, JSON, NDJSON, SQL INSERTs or Excel, streamed to disk. Text exports guard against spreadsheet formula injection. File › Import from CSV… maps columns and previews the first rows before inserting."
                    ]),
                HelpSection(
                    heading: "Server",
                    paragraphs: [
                        "Database › Server Activity (⌘⇧A) lists sessions and lets you cancel or kill one. Users & Privileges (⌘⇧U) edits roles and grants; Maintenance runs VACUUM, ANALYZE, OPTIMIZE and friends."
                    ]),
            ]),
        HelpTopic(
            id: shortcutsTopicID, title: "Keyboard Shortcuts", icon: "keyboard",
            summary: "Every shortcut, grouped by menu.",
            sections: [
                HelpSection(
                    heading: "File and tabs",
                    shortcuts: [
                        HelpShortcut(keys: "⌘T", action: "New query tab"),
                        HelpShortcut(keys: "⌘N", action: "New window"),
                        HelpShortcut(keys: "⌘O", action: "Open SQL file"),
                        HelpShortcut(keys: "⌘⌥O", action: "Open SQLite database"),
                        HelpShortcut(keys: "⌘S", action: "Save query"),
                        HelpShortcut(keys: "⌘⌥E", action: "Export result"),
                        HelpShortcut(keys: "⌘W", action: "Close tab"),
                        HelpShortcut(keys: "⌘⇧]", action: "Next tab"),
                        HelpShortcut(keys: "⌘⇧[", action: "Previous tab"),
                        HelpShortcut(keys: "⌘1 … ⌘9", action: "Select a tab"),
                    ]),
                HelpSection(
                    heading: "Query",
                    shortcuts: [
                        HelpShortcut(
                            keys: "⌘R", action: "Run the statement under the cursor, or the highlighted block"),
                        HelpShortcut(keys: "⌘⌃R", action: "Run the selection only"),
                        HelpShortcut(keys: "⌘⌥R", action: "Run all"),
                        HelpShortcut(keys: "⌘.", action: "Cancel"),
                        HelpShortcut(keys: "⌘⇧E", action: "Explain"),
                        HelpShortcut(keys: "⌘⇧I", action: "Beautify SQL"),
                        HelpShortcut(keys: "⌥Esc", action: "Show completions"),
                        HelpShortcut(keys: "⌘⇧K", action: "Snippets"),
                        HelpShortcut(keys: "⌘Y", action: "History"),
                        HelpShortcut(keys: "⌘⇧L", action: "Toggle read-only"),
                        HelpShortcut(keys: "⌘⌥←", action: "Previous result"),
                        HelpShortcut(keys: "⌘⌥→", action: "Next result"),
                        HelpShortcut(keys: "⌘F", action: "Find (in the editor, or search the front tab)"),
                        HelpShortcut(keys: "⌘⌥F", action: "Find and replace"),
                    ]),
                HelpSection(
                    heading: "Data",
                    shortcuts: [
                        HelpShortcut(keys: "⌘⇧S", action: "Commit"),
                        HelpShortcut(keys: "⌘⇧R", action: "Rollback"),
                        HelpShortcut(keys: "⌘+", action: "Add row"),
                        HelpShortcut(keys: "⌘−", action: "Delete selected rows"),
                        HelpShortcut(keys: "⌘⌫", action: "Set NULL"),
                        HelpShortcut(keys: "⌘⇧W", action: "Close window"),
                        HelpShortcut(keys: "⌘⌃C", action: "Copy as INSERT"),
                        HelpShortcut(keys: "⌥↓", action: "Choose a foreign-key value from the referenced table"),
                        HelpShortcut(keys: "F5", action: "Refresh"),
                    ]),
                HelpSection(
                    heading: "Database and tools",
                    shortcuts: [
                        HelpShortcut(keys: "⌘K", action: "Command palette"),
                        HelpShortcut(keys: "⌘⇧O", action: "Quick open table"),
                        HelpShortcut(keys: "⌘⌥N", action: "New connection"),
                        HelpShortcut(keys: "⌘⇧N", action: "New table"),
                        HelpShortcut(keys: "⌘⇧B", action: "Query builder"),
                        HelpShortcut(keys: "⌘⇧A", action: "Server activity"),
                        HelpShortcut(keys: "⌘⇧U", action: "Users & privileges"),
                        HelpShortcut(keys: "⌘⇧T", action: "Data transfer"),
                    ]),
                HelpSection(
                    heading: "View",
                    shortcuts: [
                        HelpShortcut(keys: "⌘⌥S", action: "Toggle sidebar"),
                        HelpShortcut(keys: "⌘⌥I", action: "Toggle inspector"),
                        HelpShortcut(keys: "⌘⇧F", action: "Toggle filter bar"),
                        HelpShortcut(keys: "⌘,", action: "Settings"),
                        HelpShortcut(keys: "⌘?", action: "Tinker Help"),
                    ]),
            ]),
        HelpTopic(
            id: "updates", title: "Updates and Diagnostics", icon: "arrow.down.circle",
            summary: "How Tinker updates itself, and what it records when it crashes.",
            sections: [
                HelpSection(
                    heading: "Updates",
                    paragraphs: [
                        "Tinker › Check for Updates… asks the release feed for a newer build, shows what changed, downloads it and relaunches. Every update is signed; one that does not verify is refused.",
                        "Tinker never checks on its own unless you turn on Check for updates automatically in Settings › Diagnostics. Nothing else in the app reaches the network besides your database servers.",
                    ]),
                HelpSection(
                    heading: "Diagnostics",
                    paragraphs: [
                        "With Save diagnostic reports on, a crash writes a report to Application Support on this Mac: the app and system versions and a stack trace — never SQL, values or credentials. Reports are never sent anywhere; attach one to an issue if you want it looked at."
                    ]),
                HelpSection(
                    heading: "Getting help",
                    paragraphs: [
                        "Help › Report an Issue… opens the issue tracker. Help › Release Notes shows what changed in each version."
                    ]),
            ]),
    ]

    static func topic(id: String) -> HelpTopic? { topics.first { $0.id == id } }
}
