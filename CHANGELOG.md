# Changelog

All notable changes to Tinker are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [0.1.8] - 2026-09-18

### Added
- **A written edit can be taken back.** With auto-commit on, an edit reached the server
  before the hand left the keyboard and there was nothing left to undo. Every write now
  carries its own way back: the status line names the last one and offers Undo, ⌘Z takes
  it back once nothing is pending, and a popover lists what the tab has written, each
  entry with Put Back. The statements that restore the old values are worked out before
  the write runs — while the rows still hold what is about to be replaced — and they run
  under the same one-row check a commit does, so a row that changed again in the meantime
  is refused rather than overwritten. Query result grids have it too.
- **A date, time or timestamp cell opens its picker over the cell.** ↩, a double-click,
  ⌥↓ or the context menu; the server's own text sits above the calendar for anything the
  picker cannot spell, and the two routes end at the same spelling.

### Changed
- **The grid says what it is about to do.** The cell editor opens with the caret at the
  end rather than the whole value selected, ending an edit that changed nothing writes
  nothing, and emptying a cell that held a value is asked about once while auto-commit is
  on. An editable cell outlines itself under the pointer.
- **Add Row and Delete Row moved to the foot of the grid,** beside the row count they act
  on; the delete names its own damage ("Delete 3 Rows"). Auto-commit is now a pill that
  reads as the mode it is.
- **Charts tell their categories apart.** Bars and pie slices take a hue from an
  eight-colour palette chosen separately for light and dark surfaces and checked for
  colour-blind separation; a line, an area or a scatter keeps one colour, because it draws
  one series.
- **The query bar carries names only for what runs.** Run, Run Selected and Run All keep
  their labels; Explain, Beautify and Split are icons with their shortcut in the tooltip.
  The window toolbar drops the six unlabelled glyphs that repeated them.

### Fixed
- **A production connection no longer opens a transaction for a read.** `SELECT 1` on a
  production tab used to leave TRANSACTION OPEN, a Commit button for a statement that
  changed nothing, and a connection sitting idle in a transaction. A transaction now waits
  for a write, or for auto-commit being turned off deliberately.
- **Column dividers can be grabbed.** They are handles six points either side, they show
  themselves under the pointer, and the header drags the column itself. A press on a
  heading that moved is a drag, not a click, so a missed grab no longer re-sorts a table
  and fetches the page again — which is what made resizing feel broken in a table tab and
  fine in a query tab.

## [0.1.7] - 2026-09-17

### Changed
- **A new app icon:** the origami penguin, facing right, on an ice-blue plate. It carries
  all four macOS appearances — light, dark, clear and tinted — from the one piece of
  artwork.

### Fixed
- **MariaDB keeps its own badge when the connection is closed.** MySQL and MariaDB share a
  dialect and often a port, so the sidebar only knew which engine it was drawing once a
  session had connected — and it forgot again on quit. A closed MariaDB connection
  therefore showed MySQL's dolphin, which on a sidebar of closed connections means always.
  The connection now remembers what the server said it was. It is still the server's own
  word: neither the port nor the connection's name is treated as evidence, so a connection
  never yet opened shows the dolphin until it is opened once.

## [0.1.6] - 2026-09-17

### Added
- **Events, for MySQL and MariaDB.** Every database on a MySQL-family connection has an
  Events branch listing what the server has scheduled, with an editor for creating,
  altering, enabling and dropping them, and the server's own `SHOW CREATE EVENT` behind
  Source. Before saving, the editor reads the server's scheduler and says whether anything
  will actually run: off, which an account with the privilege can turn on from here, or
  DISABLED, which was fixed at server start and needs a restart. Turning it on uses `SET
  PERSIST` on MySQL 8.0 and later so it survives one, and says so plainly when the server
  will forget it instead. An edit that did not touch the schedule does not re-state it, so
  an event written in another time zone cannot be moved by a change to its comment, and a
  schedule already in the past is pointed out rather than saved in silence.
- **A Chart tab after Rows.** Any result with something to measure can be drawn as a bar,
  line, pie, scatter or area chart, with a category, an aggregate, and hovering that reads
  out the point under the pointer. A key is not a measurement: a primary key, a uuid, or a
  column named `id` or ending in `_id` is offered as a label and never as a value. When a
  chart is drawn from a page of a larger result it says "N of M rows", so a partial sum
  cannot read as the total.
- **The editor can sit beside its results** instead of above them, from a setting.
- **Collation travels between MySQL servers.** A structure sync or transfer between two
  MySQL-family servers keeps each column's character set and collation instead of dropping
  them. The names are checked against the receiving server first, because MariaDB accepts
  MySQL's `utf8mb4_0900_ai_ci` while MySQL refuses MariaDB's `utf8mb4_uca1400_ai_ci`.
  Across engines it cannot come along at all, and that is now noted once per table naming
  both halves rather than once per text column.
- **The structure designer offers the types the server has**, including a PostgreSQL enum
  someone defined, read from the server rather than from a built-in list.
- **A new app icon**, and engine marks drawn to look like their engines — an elephant, a
  dolphin, a seal for MariaDB, a feather for SQLite — with MariaDB told apart from MySQL by
  the server's own flavour rather than by its port.

### Fixed
- **A row added by hand is editable in every column at once.** Each cell used to need its
  own double-click, and Tab moved the selection without opening anything.
- **A connection that will not leave its transaction is dropped rather than pooled.**
  Cancelling a run interrupts the statement, so the cleanup rollback failed and the
  connection went back into the pool still inside its transaction — where the next use of
  it would implicitly commit the abandoned work on MySQL, or join it on PostgreSQL.
- **Reformatting a selection leaves the selection over the new text**, so running it
  straight afterwards runs the statement that is there rather than a truncated one.
- **The selected tab no longer bleeds into the title bar.**

## [0.1.5] - 2026-09-14

### Added
- **Enum and SET columns are picked, not typed.** Editing an enum cell opens its values in a
  menu over the cell, with the current one ticked; a MySQL SET gets checkboxes and an Apply
  button. The inspector's Cell and Row panes offer the same controls. A value typed or
  pasted that is not one of the column's values is refused before anything is written, and
  the message names the values that are.
- **Rows paste straight in from a spreadsheet or a CSV.** ⌘V in the grid pastes. Lines with
  as many values as the table has columns — or under a first line naming the columns, in
  any order and without the auto-increment key — are added as new rows, each value in its
  own column; fewer values fill cells from the one selected, as before. Excel's quoted
  cells, line breaks inside a cell and CRLF line ends come through, and a comma inside one
  value does not split it. With auto-commit on the rows are written at once; on a
  production connection they wait for Commit like any other edit.

### Fixed
- **Pasting a table finishes.** Confirming the structure review brought the Paste sheet
  back empty instead of copying the rows, so a paste never completed. The review now opens
  over the sheet, and the paste runs to its result in the same place.
- **A MySQL paste lands in the chosen database** when the connection has no default
  database. It failed with "No database selected".
- **A pasted table no longer carries a foreign key to a table that is not there.** Pasting
  one table into another database copied its key to a parent the target did not have:
  MySQL then refused every new row in the copy, and PostgreSQL refused the paste. A key now
  comes along when its table is part of the paste or already exists on the target, and is
  otherwise left out and named under "Left out of the paste".
- **The structure review shows every statement in full**, in a box that scrolls, instead of
  the first few cut off in the subtitle.
- **Copied cells keep their tabs and line breaks.** They are quoted the way a spreadsheet
  quotes them rather than turned into spaces, so a copy pastes back whole.

## [0.1.4] - 2026-09-12

### Fixed
- **The sidebar no longer hangs off the left edge of the window.** At a narrow window the
  pane beside it asked for more room than there was, the split view took that room out of
  the sidebar, and the sidebar's content — which will not lay out below its own minimum —
  was drawn over the window's edge, so "database" read as "tabase". Four panes did it: the
  bar above every pane, the objects list, the server's sessions, users and settings, and the
  query builder, whose three panes wanted 1144 pt between them and so spilled the sidebar at
  every width the app allowed. Each of them now narrows and scrolls sideways instead.
- **The objects list starts at the Name column again.** It was wider than a narrow pane, and
  a vertical scroller centres what it cannot fit, which pushed the first column off the
  pane's leading edge.

### Changed
- **The window can be made narrower: 800 pt instead of 960.** Enough to tile it to half a
  laptop screen, which is what a minimum width is for.
- **The inspector belongs to the tab, not the workspace.** Opening it to read a row of a
  table used to open it beside every query result too, where nothing in the query tab could
  close it again. Each tab keeps its own, and the query bar has its own switch for it.
- **A bar with more controls than fit scrolls sideways.** It used to squeeze the labels
  until they wrapped; now they keep their width, and nothing — a transaction's Commit and
  Rollback included — is lost off the edge.

## [0.1.3] - 2026-09-12

### Added
- **A new version tells you the way everything else on macOS does.** An update found on the
  daily schedule arrives as a notification instead of Sparkle's window opening over your
  work; click it to see what changed and install it. A check you start yourself still opens
  the window straight away. Permission to notify is asked for when you turn the
  automatic-check switch on, and never before.
- **"Choose from referenced table" in the inspector's Row pane.** A foreign key could be
  picked from a list in the Cell pane but not in the form beside it.

### Fixed
- **Typing in the SQL editor no longer makes the text flicker.** Every keystroke repainted
  the whole editor twice: the view's font was written over the entire document on each
  change, which laid the page out again and dropped the highlighter's bold and italic runs,
  and the highlighting pass reset every attribute before colouring them back. The font is
  now written only when it changed, the pass writes only what is not already right, and the
  caret's line band is invalidated instead of the page. Measured while typing a character
  every 0.9 s: 383 points of the editor repainted per keystroke before, 112 after.
- **An edit in the Row pane is saved when you leave the field.** It committed only on
  Return, so a value typed and then clicked away from was dropped without a word.
- **No more UPDATE for a row nobody edited.** The Row pane decided a field had changed by
  comparing against a rendering the field was never filled from, so every untouched array or
  geometry column read back as edited — and with auto-commit on, that was written to the
  server.
- **A column the grid will not write is no longer offered for typing.** A query result's
  computed column looked editable and refused only once Return was pressed.
- **Profile and Status start at the top left.** Both floated in the middle of their pane
  when the table was smaller than the space it had.

### Removed
- **The Text pane.** It rendered a whole result into a single text view, which hung the app
  on anything large; the grid is what results are for.

## [0.1.2] - 2026-09-11

### Changed
- **The review's fixes (ADR-0040 to ADR-0045).** The connection pool no longer hands out a
  connection that is still being reset, or waits for ever when every connection is busy; a
  lost connection is reconnected on the next use, or, when a transaction was open, waits for
  Reconnect in the sidebar. Results stream under back-pressure on PostgreSQL and SQLite, so
  a slow read of a million rows is a few batches in memory. Idle connections are kept alive
  and a dead one is replaced before a tab needs it.
- **Keys back on the spec.** ⌘⌫ sets NULL (it deleted rows), ⌘− deletes rows, ⌘+ adds a
  row, ⌘⇧R rolls back (it ran the selection; that is ⌘⌃R now), ⌘⇧W closes the window. A
  delete under auto-commit asks first; sort, filter, paging, Refresh, closing a tab and
  quitting ask before discarding uncommitted edits or an open transaction.
- **Values the server reads back as the same value.** PostgreSQL `money` (`12.34`, not
  `1234`), `float4` (`0.1`, not `0.10000000149011612`), MySQL `BIT` (bound as its bytes),
  MySQL zero dates (their text, not NULL), SQLite `affectedRows` (the statement's own rows,
  not its cascades). A `statement_timeout` shows the server's message instead of "Cancelled".
- **Measured, not eyeballed.** The grid's first page and paging memory are measured with
  `XCTMetric` and signposts; backends are terminated mid-query in tests; dumps read every
  table under one snapshot. The editor stays responsive on a ten-megabyte script; export
  writes off the main thread.
- **Operable.** The app logs to the unified log under `com.thinkfree.Tinker`; Settings ›
  Diagnostics › Copy Diagnostics assembles a bug report. `dbcli` reads passwords from the
  environment. `Scripts/ci.sh --strict` refuses a green run that skipped anything; the
  smoke test only ever uses a `tinker_test` connection. The release build number is the
  project's, and a release needs its CHANGELOG section.
- **Nothing left deferred (ADR-0047).** Pending edits follow their row across a sort,
  a page move or a refresh, and so does undo; the grid no longer asks to discard them
  first. MySQL results stream under back-pressure like the other engines. A cancel can
  no longer land on the statement that came next. Pasting objects to another server
  shows the CREATE, ALTER and DROP statements it rebuilt and asks before running them.
  A batch that returns several result sets shows each one, with a picker. At the memory
  cap the banner offers Load more, Export the rest… and Stop. A PostgreSQL `time with
  time zone` crosses to MySQL or SQLite as text instead of failing. The grid draws its
  cells itself: a scroll stop on a wide result costs a third of what it did, and a
  refresh a fifth; both are now measured in the real table view by app-hosted tests. A
  MySQL connection killed under a statement over TLS is reported as lost, so the session
  replaces it instead of showing an SSL error.

## [0.1.1] - 2026-09-11

### Added
- **Help that exists.** Help › Tinker Help (⌘?) opens a window of built-in pages — getting
  started, connections, browsing and editing data, the SQL editor, structure, tools, every
  keyboard shortcut, updates and diagnostics — with a search field. The Help menu also
  offers Keyboard Shortcuts, Release Notes, Report an Issue… and Tinker on GitHub.
- **Updates that work.** Check for Updates… is live: the project carries the release feed
  (the latest GitHub release's `appcast.xml`) and the Sparkle public key, `Scripts/release.sh`
  signs each DMG and writes the appcast, and `--publish` creates the GitHub release that
  carries them. Settings › Diagnostics shows the running version and offers automatic daily
  checks, off by default. The Sparkle keys were set in the project as `INFOPLIST_KEY_*`
  settings, which Xcode only honours for keys it knows, so no build ever carried them; they
  live in `App/Info.plist` now.
- **Connection pickers name the folder.** Every place that lists connections — the query
  tab's pop-up, Dump, Import SQL File, Data Transfer, Data and Structure Synchronization,
  Paste, Structure Sync, the command palette — shows `Localhost › MySQL` rather than
  `MySQL`, adds `user@host` when two still read the same, and marks production with `PROD`.
- **Foreign keys read like names.** A foreign-key cell shows what it points at beside the
  key — `1 · Ada` — resolved one batched query per page and cached. Editing such a cell
  offers **Choose from Referenced Table…** (context menu, `⌥↓`, or Choose… in the
  Inspector): a popover that searches the referenced table by a label column on the server,
  fifty rows at a time, with the current value shown, NULL when allowed, and a remembered
  choice of label column. The chosen key goes through the ordinary edit path, so auto-commit
  and the production gate apply.
- **Views reopen in the Query Builder.** Creating a view from the builder remembers its
  canvas; **Open in Query Builder** on the view's Source tab brings it back for editing when
  the server's definition is unchanged, and **Save View** replaces it in place. A view made
  elsewhere is read back from its definition for the subset the canvas can draw (joins,
  aggregates, conditions, grouping, ordering, limits); anything beyond that — a subquery, an
  expression, nested condition groups — is named on the Source tab rather than approximated.

### Fixed
- **MySQL `tinyint(1)` no longer turns 2 into `true`.** The column is a boolean by convention
  only; 0 and 1 still read as false and true, and any other value keeps its number, on screen
  and when typed into the cell. The connection's "Treat tinyint(1) as boolean" switch turns
  the convention off entirely.
- **Structure: Done no longer loses a pending change.** Done only left editing, so a column
  added without pressing Preview stayed as an invisible pending edit that the next re-read
  of the table replaced. Done now shows the pending statements and leaves editing once they
  have run; a re-read keeps unsaved edits and says so only when the server's definition
  really changed.
- **Structure: the highlighted row is the one being edited.** A click inside a cell's text
  field never reached the row's tap gesture, so the highlight and the detail panel stayed on
  the previous row. The selection now follows the focused field, and changing a type,
  checkbox or key marks its row as well.
- **SSH key files work against current servers.** An RSA key was signed only as `ssh-rsa`
  (SHA-1), which OpenSSH 8.8 and later refuse, so every `id_rsa` failed with "SSH
  authentication failed". Keys are now offered as `rsa-sha2-512`, then `rsa-sha2-256`, then
  `ssh-rsa` for servers that know nothing newer, and the message names what was refused.
- Key files in the older PEM formats (`BEGIN RSA PRIVATE KEY`, `BEGIN EC PRIVATE KEY`,
  PKCS#8), with or without a passphrase, and ECDSA keys are read; before, the first was not
  recognised and the last was refused. Files Tinker cannot read say why and how to convert
  them (`ssh-keygen -p`).

### Added
- **SQLite.** A database file is a connection: drop a `.sqlite`, `.sqlite3`, `.db` or `.db3`
  file on the window, open it from Finder, or choose File › Open SQLite Database… (⌥⌘O),
  and it is connected, expanded and ready. The connection editor gains a file mode with
  Choose… and New…. Tables, structure, queries, the query builder, export, dump, import,
  data transfer and synchronisation work the same as on a server.
- The driver runs on the `libsqlite3` macOS ships, with one dedicated thread per open file,
  cancellation through `sqlite3_interrupt`, statement timeouts, and `lower()`/`upper()` that
  fold more than ASCII, so a quick search for `ÖRL` finds `wörld`.
- Foreign keys are enforced by default on SQLite connections, and Read-only is held by the
  file itself through `PRAGMA query_only`.
- Structure changes SQLite's `ALTER TABLE` cannot express are applied the way SQLite's own
  documentation prescribes, by rebuilding the table inside one transaction; the preview shows
  every statement.
- Dumps and imports carry SQLite trigger bodies whole, and turn foreign-key checks off and on
  around the data.
- `dbcli` accepts `sqlite:///path/to/file.db`.
- The test suite runs against a temporary SQLite database on every invocation, with no
  server and no configuration.

- **Data Transfer, Data Synchronization and Structure Synchronization work across
  engines.** Any connection can be the source or the target: MySQL to PostgreSQL,
  PostgreSQL to SQLite, and every other pairing. Tables are rebuilt in the target's own
  types with their keys, indexes and defaults; rows travel in the target's literals; a
  MySQL `int` compares equal to a PostgreSQL `integer` when structures are compared. What
  cannot cross — views, routines, triggers and check constraints, which are written in the
  source's SQL — stays behind and is listed by name when the transfer finishes.
- **The SQL editor completes functions.** Type `DA` and the list offers `DATE`,
  `DATE_FORMAT`, `DAY`, `DAYNAME`… with their signatures and categories, in the engine's
  own spelling; choosing one inserts `DATE()` with the cursor inside the parentheses. The
  catalog covers 281 MySQL, 291 PostgreSQL and 128 SQLite functions, and known functions
  are coloured in the editor.

### Changed
- A query tab on a production connection never auto-commits: the checkbox is replaced by a
  "manual commit" mark, and every write waits in a transaction for Commit or Rollback.
- Engine-specific panes say what an engine lacks instead of showing an empty page: SQLite
  has no users, sessions, stored routines or profiler, and the app says so.
- The status bar shows "Local file" for a database opened in-process, where a server
  connection shows whether its wire is encrypted.

## [0.1.0] — 2026-09-08

The first release. Apple silicon only, macOS 14 or later.

### Added
- PostgreSQL and MySQL/MariaDB connections, with TLS modes, SSH tunnels with password,
  key-file and jump-host authentication, and passwords kept in the Keychain.
- A data grid that pages on the server, edits in place, previews every change as SQL and
  commits it in one transaction with primary-key `WHERE` clauses that verify exactly one
  row was touched.
- A SQL editor with highlighting, alias-aware completion, a formatter, statement-at-cursor
  execution, cancellation that reaches the server, and result panes for message, rows,
  profile and status.
- Production and read-only modes enforced on the server session, with typed-name
  confirmations for destructive actions.
- Objects overview, structure editor with structure sync, visual query builder, cell
  inspector with a map for geometry, and a server view for sessions, users and settings.
- Export to CSV, JSON, NDJSON, SQL and Excel; dump, import and transfer between databases,
  all streamed without holding the data in memory.

[Unreleased]: https://github.com/tammami/Tinker/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/tammami/Tinker/releases/tag/v0.1.0
