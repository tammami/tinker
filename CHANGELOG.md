# Changelog

All notable changes to Tinker are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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
