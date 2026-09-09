# Changelog

All notable changes to Tinker are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

## [Unreleased]

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

### Changed
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
