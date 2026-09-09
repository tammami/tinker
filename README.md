# Tinker

**A native macOS client for PostgreSQL, MySQL and SQLite that treats your data like production data. Because it is.**

![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-1d1d1f?style=flat-square&logo=apple&logoColor=white)
![Architecture](https://img.shields.io/badge/arch-Apple%20Silicon-1d1d1f?style=flat-square)
![Swift](https://img.shields.io/badge/Swift-6%20%C2%B7%20strict%20concurrency-F05138?style=flat-square&logo=swift&logoColor=white)
![UI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-0A84FF?style=flat-square)
![Engines](https://img.shields.io/badge/engines-PostgreSQL%20%C2%B7%20MySQL%20%C2%B7%20MariaDB%20%C2%B7%20SQLite-336791?style=flat-square)
![Tests](https://img.shields.io/badge/tests-300%2B%20%C2%B7%20integration%20against%20real%20servers-2ea44f?style=flat-square)
![License](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-8250df?style=flat-square)

Tinker is built for the developer who lives in a database all day: dev in the morning, staging after lunch, production over SSH at 5 p.m. It is fast enough to page through a million rows without flinching, honest enough to show you the server's exact words when something goes wrong, and careful enough that every write is a transaction you previewed first.

No Electron. No web view. A real Mac app, with real menus, real windows, and a data grid that is an `NSTableView` because nothing else keeps up.

---

## Why Tinker

Most database clients optimise for the demo: a pretty grid, a few hundred rows, a happy path. Tinker optimises for the day you `UPDATE` the wrong row on production.

| Principle | What it means in practice |
|---|---|
| **Never lose data** | Every grid edit becomes SQL you can read before it runs. Every generated `UPDATE` and `DELETE` targets the primary key with the original values and runs inside a transaction that verifies exactly one row was touched. |
| **Never degrade** | Results stream. Tables page on the server. A 1,000,000-row table opens in under half a second and scrolls at 60 fps with the main thread never blocked for more than a frame. |
| **Feel like a Mac app** | Multiple windows, tabs, ⌘-shortcuts for everything, dark mode, native text editing, Keychain-backed secrets. |
| **Be honest** | Server errors are shown verbatim, with the offending token highlighted. No rewriting, no summarising, no silent retries. |

---

## Highlights

### Connections that respect the environment
- **Production and read-only modes** are enforced on the server session, not just in the UI. A production connection never auto-commits and asks before a query tab writes.
- **SSH tunnels** with password, key file and jump-host auth, pure Swift over NIO.
- **TLS by default** for new connections. The negotiated transport is verified and shown in the status bar.
- Passwords live in the Keychain and nowhere else. A test greps the store file to prove it.
- **SQLite is a file, so it opens like one.** Drop a `.sqlite` or `.db` file on the window, open it from Finder, or pick it from the File menu, and it is a connection: tables, structure, queries, export and dump, the same as any server. Foreign keys are enforced by default, read-only holds on the file itself, and `lower()`/`upper()` fold more than ASCII.

### A data grid that scales
- AppKit `NSTableView`, server-side paging, one page in memory at a time.
- Inline editing with typed editors per column, `NULL` handling, composite and UUID primary keys.
- Filters that compile to parameterised SQL, joined with AND or OR, with sorting that stays on the server.
- Cell inspector with hex dump, pretty-printed JSON, and geometry rendered on a real map.
- Values that carry precision, such as `decimal` and `timestamp`, keep the server's text end to end. They are never routed through `Double` or `Date`.

### A SQL editor that understands your dialect
- AppKit `NSTextView` with syntax highlighting, autocomplete that knows your aliases, a line-number gutter and a formatter that keeps every token.
- Runs the statement at the cursor, the selection, or the whole buffer. Handles `DELIMITER $$` procedures in a 2,000-statement dump.
- Per-tab connection and database. `SELECT * FROM t` resolves against the tab's session.
- Cancellation that reaches the server and returns within a second, leaving the connection reusable.
- Result panes for Message, Result, Profile and Status, plus a history of every statement that ran.

### Tools for the whole database
- **Objects overview** per database or schema: kind, estimated rows, size, engine, collation, owner. Estimates are labelled as estimates.
- **Structure editor** for columns, types, defaults and enum members, with structure sync between databases.
- **Visual query builder** with drag-and-drop tables and live filters.
- **Export** to CSV, JSON, NDJSON, SQL `INSERT` and Excel, streamed to disk without materialising the file in memory. Text exports guard against spreadsheet formula injection.
- **Dump, import and transfer** between databases without ever holding them in memory.
- **Server view** for sessions, users, settings and object definitions.

---

## Architecture

Tinker is a Swift Package Manager workspace with a strictly downward dependency graph. The app depends on the packages. The packages depend on `DBCore`. `DBCore` depends on Foundation and `swift-log`, and nothing else. `Scripts/ci.sh` lints the `import` statements to keep it that way.

```
App/Tinker            SwiftUI shell, AppKit grid and editor, menus, commands
│
├── DBGrid            Grid model, edit tracking, paging, DML generation
├── DBSQL             Statement splitter, tokenizer, quoting, formatter, filter compiler
├── DBPostgres        SQLDriver over postgres-nio (PostgresClient, binary results)
├── DBMySQL           SQLDriver over mysql-nio (prepared-statement protocol, text fallback)
├── DBSQLite          SQLDriver over the system libsqlite3, one dedicated thread per file
├── DBTunnel          SSH port forwarding over Citadel, known-hosts, TLS helpers
├── DBStore           Connection store, Keychain, query history, settings
├── DBTestKit         Fixtures, env-var server resolution, skip-with-reason helpers
│
└── DBCore            Driver protocol, value model, errors, ConnectionSession
```

A few load-bearing decisions, each recorded as an ADR in [`DECISIONS.md`](DECISIONS.md):

- **All database I/O runs in actors.** `@MainActor` is reserved for views and view models.
- **One driver-neutral value model.** Every native type maps to exactly one `DBValue` case. Unknown types surface as `.raw` with their type name rather than being guessed at.
- **Two execution paths**, chosen by whether the statement streams rows, so a `SELECT` over a million rows and a `CREATE PROCEDURE` are both first-class.
- **Pooled connections are reset before reuse**, and history and error logs are redacted.
- **No `try!`, no force unwraps outside tests, no `DispatchQueue`, no `print`.** Swift 6 with `-strict-concurrency=complete` and zero warnings, enforced in CI.

---

## Getting started

### Requirements

- macOS 14 Sonoma or later, Apple Silicon
- Xcode 16 or later
- A local PostgreSQL and/or MySQL server you already run. Tinker's tests never install, start or reconfigure a database, and never use Docker. The SQLite suite needs nothing at all: it creates a temporary database file of its own and always runs.

### Build and run

```sh
git clone git@github.com:tammami/Tinker.git
cd Tinker
open App/Tinker.xcodeproj
```

Select the `Tinker` scheme and run. The packages can also be built and tested from the command line:

```sh
swift build
swift test
```

### Run the full suite against real servers

Integration tests run against an isolated `tinker_test` database and a non-privileged `tinker_test` user. Prepare them once with admin URLs, then export the non-admin URLs the script prints:

```sh
export TINKER_TEST_PG_ADMIN_URL='postgresql://<you>@localhost:5432/postgres'
export TINKER_TEST_MYSQL_ADMIN_URL='mysql://root:<password>@127.0.0.1:3306/'
testenv/prepare.sh

export TINKER_TEST_PG_URL='postgresql://tinker_test:tinker_test@localhost:5432/tinker_test'
export TINKER_TEST_MYSQL_URL='mysql://tinker_test:tinker_test@127.0.0.1:3306/tinker_test'
Scripts/ci.sh
```

The suite refuses to run against any database not named `tinker_test` or any superuser account. Engines without a URL are skipped with a visible warning and reported in the coverage summary. The grid, transfer and sync suites also run against SQLite on every invocation, so the shared data path is exercised even on a machine with no server. A skipped test is never counted as a pass. See [`testenv/README.md`](testenv/README.md) for SSH and multi-server setups.

### Release

```sh
Scripts/release.sh                  # archive, Developer ID sign, notarize, staple, DMG
Scripts/release.sh --skip-notarize  # sign only
Scripts/release.sh --unsigned       # local smoke test
```

Updates are delivered through Sparkle 2. The appcast URL and EdDSA key are supplied from the environment at release time, so a build without them ships with the updater disabled and says so.

---

## Keyboard first

Every action is a menu item with a shortcut, registered through SwiftUI `Commands` so it is discoverable.

| | |
|---|---|
| ⌘T new query tab | ⌘↩ run statement at cursor |
| ⌘⇧↩ run all | ⌘. cancel |
| ⌘⇧S commit | ⌘⇧R rollback |
| ⌘⇧O quick-switch table | ⌘⇧F filter grid |
| ⌘⇧I format SQL | ⌘E export result |
| ⌘⌥C copy rows as `INSERT` | ⌘⌫ set cell to `NULL` |
| ⌘⇧L toggle read-only | ⌘R refresh |

The full list lives in [`SPEC.md`](SPEC.md) §10.2.

---

## How this project is run

Tinker is specification-driven. Three documents carry the state of the project and are kept current with every change:

- [`SPEC.md`](SPEC.md) is the source of truth: contracts, screens, acceptance criteria and the phased plan.
- [`DECISIONS.md`](DECISIONS.md) is an append-only ADR log. Every deviation from the spec and every new dependency has an entry with the option chosen and why.
- [`PROGRESS.md`](PROGRESS.md) records, per phase, what was completed, which tests prove it, and what was deliberately deferred. Gaps are listed as gaps, not claimed as done.

Working rules for contributors, including the dependency direction, the concurrency model and the definition of done, are in [`CLAUDE.md`](CLAUDE.md).

Release notes live in [`CHANGELOG.md`](CHANGELOG.md).

### Definition of done

A feature is done when the build is warning-free under strict concurrency, the tests are green, the driver feature has an integration test that actually ran against a local server, and the performance criteria are measured with signposts rather than by eye.

---

## Scope

Version 0.1 targets PostgreSQL, MySQL/MariaDB and SQLite on Apple Silicon. Redis, MongoDB, SQL Server, Oracle, cloud sync, collaboration and ER modelling are explicitly out of scope and are neither built nor stubbed.

SQLite has no server, so some panes say so instead of pretending: there are no users or sessions to manage, no stored routines, and no profiler. A column change SQLite's `ALTER TABLE` cannot express is applied the way SQLite's own documentation prescribes, by rebuilding the table inside one transaction.

Signed and notarized distribution is implemented in `Scripts/release.sh` but requires a Developer ID certificate that has not yet been exercised in this repository. The script fails loudly rather than skipping the step.

---

## Dependencies

| Purpose | Package |
|---|---|
| PostgreSQL | [vapor/postgres-nio](https://github.com/vapor/postgres-nio) |
| MySQL / MariaDB | [vapor/mysql-nio](https://github.com/vapor/mysql-nio) |
| SSH | [orlandos-nl/Citadel](https://github.com/orlandos-nl/Citadel) |
| Logging | [apple/swift-log](https://github.com/apple/swift-log) |
| Updates | [sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) |
| SQLite | the `libsqlite3` macOS ships, through the system `SQLite3` module |

Nothing else is added without an ADR.

---

## License

Tinker is released under the [PolyForm Noncommercial License 1.0.0](LICENSE).

You may use, study, modify and share it for any **noncommercial purpose**: personal projects, research, education, hobby work and the like. You may not sell it, sell access to it, or use it in a product or service that is offered for money. If you need a commercial license, open an issue and ask.

The license requires that this notice travel with every copy:

```
Required Notice: Copyright (c) 2026 ThinkFree (https://github.com/tammami/Tinker)
```
