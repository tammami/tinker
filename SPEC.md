# Tinker — Product & Technical Specification

Version: 0.1 (MVP scope)
Target: macOS, Apple Silicon only
Databases in scope: PostgreSQL, MySQL/MariaDB, SQLite (added 2026-09-09, Phase 10)
Explicitly out of scope for v0.1: Redis, MongoDB, SQL Server, Oracle, cloud sync, collaboration, ER modeling, scheduler, server monitor.

This document is the source of truth. Where this spec is silent, follow `CLAUDE.md` conventions. Where this spec conflicts with a library's idiom, this spec wins unless the conflict makes the feature impossible; in that case stop and report before deviating.

---

## 0. How to read and execute this spec

- Sections 1–4: context and constraints. Read once.
- Sections 5–9: core library contracts. Implement exactly; these are the API that the UI is built on.
- Sections 10–13: application behaviour. Each screen has explicit acceptance criteria.
- Section 14: phased task list. Execute in order. Do not start Phase N+1 until Phase N acceptance criteria pass.
- Section 15: testing. Tests are not optional and not deferred.

Every phase ends with: build passes with zero warnings under strict concurrency, all tests green, and a short `PROGRESS.md` entry describing what was done and what was deliberately deferred.

---

## 1. Product overview

Tinker is a native macOS database client for developers, positioned as a fast, safe replacement for Navicat/TablePlus for PostgreSQL and MySQL. Design principles, in priority order:

1. **Never corrupt or lose user data.** Every write to a database is explicit, previewable as SQL, and reversible before commit.
2. **Handle large result sets without degrading.** 1M-row tables must scroll at 60fps and never load fully into memory.
3. **Feel like a Mac app.** Standard AppKit behaviour: menus, keyboard shortcuts, multiple windows, tabs, dark mode, native text editing.
4. **Be honest with the user.** Every error surfaces the server's actual message. No silent retries, no swallowed exceptions.

Target user: an individual developer working daily against dev/staging/prod databases, typically over SSH.

---

## 2. Platform and toolchain

- macOS 14.0+ (Sonoma). Do not add availability checks for older versions.
- Architecture: arm64 only. No universal binary.
- Xcode 16+, Swift 6 language mode, `-strict-concurrency=complete`. The app must compile with zero warnings.
- Swift Package Manager for all dependencies. No CocoaPods, no Carthage.
- UI: SwiftUI for app shell (window chrome, sidebar, inspector, sheets, settings). AppKit via `NSViewRepresentable` for the data grid and the SQL editor. This split is mandatory; do not implement the grid in SwiftUI `Table`.
- Distribution: Developer ID signed, notarized, distributed as DMG with Sparkle 2 for updates. Not sandboxed (SSH tunnels and arbitrary file export require it). Hardened runtime enabled.

### 2.1 Dependencies (locked set)

| Purpose | Package | Notes |
|---|---|---|
| PostgreSQL driver | `vapor/postgres-nio` | `PostgresConnection` per physical connection, pooled by `ConnectionSession` (amended by ADR-0007; §7.3 says why `PostgresClient` is not used) |
| MySQL driver | `vapor/mysql-nio` | If auth or type coverage proves insufficient, escalate; fallback is `libmysqlclient` via C module (see §7.3) |
| SQLite driver | the system `SQLite3` module (`libsqlite3` shipped with macOS) | No package. One dedicated thread per open file (ADR-0036) |
| SSH tunnel | `orlandos-nl/Citadel` | Pure Swift SSH on NIO. Needs `direct-tcpip` channel forwarding. Fallback: libssh2 via C module |
| SQL parsing/highlighting | none — `DBSQL.SQLTokenizer` and `StatementSplitter` | Amended by ADR-0018: tree-sitter was not adopted; a hand-written tokenizer highlights and the splitter finds statement boundaries |
| Logging | `apple/swift-log` | Single logger per subsystem |
| Updates | `sparkle-project/Sparkle` | Phase 4 only |
| Test servers | The developer's existing local PostgreSQL and MySQL, plus optional remote servers, all supplied via env vars | See §17. No Docker, no installs. |

Do not add other dependencies without recording a justification in `DECISIONS.md`.

---

## 3. Repository layout

```
Tinker/
├── CLAUDE.md
├── SPEC.md                    (this file)
├── DECISIONS.md               (ADR log, append-only)
├── PROGRESS.md                (per-phase log)
├── Package.swift              (workspace root: local packages)
├── Packages/
│   ├── DBCore/                (protocols, value model, errors, session; NO UI, NO driver deps)
│   ├── DBPostgres/            (SQLDriver impl for PostgreSQL)
│   ├── DBMySQL/               (SQLDriver impl for MySQL/MariaDB)
│   ├── DBSQLite/              (SQLDriver impl for SQLite database files)
│   ├── DBTunnel/              (SSH tunnel, TLS helpers)
│   ├── DBStore/               (connection store, Keychain, history, settings persistence)
│   ├── DBSQL/                 (SQL text utilities: statement splitter, identifier quoting, DDL/DML generators, highlighting adapter)
│   └── DBTestKit/             (shared test fixtures, env-var server resolution, skip-with-reason helpers)
├── App/
│   └── Tinker/              (Xcode app target; SwiftUI + AppKit)
│       ├── App/               (entry, scenes, commands, menus)
│       ├── Features/
│       │   ├── Connections/
│       │   ├── SchemaBrowser/
│       │   ├── DataGrid/      (AppKit NSTableView based)
│       │   ├── SQLEditor/     (AppKit NSTextView based)
│       │   ├── Results/
│       │   ├── Export/
│       │   └── Settings/
│       ├── Shared/            (view models, design tokens, reusable views)
│       └── Resources/
├── Tools/
│   └── dbcli/                 (CLI harness exercising DBCore without UI; used for driver dev and integration tests)
└── testenv/
    ├── prepare.sh             (creates `tinker_test` db + user on the servers named in env vars; installs nothing)
    ├── fixtures/pg/*.sql      (fixture schema + data)
    ├── fixtures/mysql/*.sql
    └── README.md              (how to point tests at any server via env vars)
```

Dependency direction is strictly downward: App → DB* packages → DBCore. `DBCore` imports only Foundation and swift-log. Drivers never import each other. `DBStore` never imports drivers.

---

## 4. Concurrency and process model

- All database I/O happens inside Swift actors. The UI never blocks on I/O.
- One `ConnectionSession` actor per open connection. One connection can have multiple `QueryTab`s; each tab owns its own underlying driver connection (so a long-running query in one tab does not block another). Pool size per session: max 8 driver connections, lazily created, idle-closed after 5 minutes.
- Result rows are delivered as an `AsyncThrowingStream<RowBatch, Error>`; batch size 500 rows or 1 MB, whichever first.
- Cancellation: `Task.cancel()` on the query task MUST result in a server-side cancel (Postgres: `CancelRequest` on a new socket; MySQL: `KILL QUERY <id>` on a separate connection). A cancelled query must surface as `DBError.cancelled`, not as a generic error.
- Every driver call has a timeout: connect 15s (configurable), statement execution none by default (configurable per connection), idle keepalive 60s.
- `@MainActor` is applied only to view models and views. `DBCore` and drivers contain no `@MainActor` code.

---

## 5. DBCore — value model

```swift
/// A database value in a driver-neutral representation.
/// Drivers MUST map every native type to exactly one case. Unknown types map to .raw with the type name.
public enum DBValue: Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int64)
    case uint(UInt64)          // MySQL unsigned BIGINT only
    case double(Double)
    case decimal(String)       // exact string form; never converted to Double
    case string(String)
    case bytes(Data)
    case date(DBDate)          // yyyy-mm-dd, no time
    case time(DBTime)          // hh:mm:ss.ffffff, optional tz offset
    case timestamp(DBTimestamp)// full; carries `hasTimeZone` flag
    case uuid(UUID)
    case json(String)          // canonical text, not parsed
    case array([DBValue])      // Postgres arrays only
    case raw(typeName: String, text: String?, bytes: Data?)
}

public struct DBDate: Sendable, Hashable { public let year: Int, month: Int, day: Int }
public struct DBTime: Sendable, Hashable { public let hour: Int, minute: Int, second: Int, microsecond: Int, tzOffsetSeconds: Int? }
public struct DBTimestamp: Sendable, Hashable {
    public let date: DBDate; public let time: DBTime; public let hasTimeZone: Bool
    /// Always representable as text exactly as the server sent it for round-trip safety.
    public let serverText: String
}
```

Rules:
- `decimal` and `timestamp` retain server text. Editing these in the grid edits the text, and the driver sends it back as a typed literal. Never round-trip through `Double` or `Date`.
- Display formatting is a UI concern. `DBValue` has no formatting logic beyond a debug description.
- `DBValue.sqlLiteral(dialect:)` lives in `DBSQL`, not here.

```swift
public struct ColumnMeta: Sendable, Hashable, Identifiable {
    public let id: Int                // ordinal, 0-based
    public let name: String
    public let tableOID: String?      // driver-specific table identity if known
    public let nativeTypeName: String // e.g. "int4", "varchar(255)"
    public let kind: DBValueKind      // enum mirroring DBValue cases, for editor selection
    public let isNullable: Bool?
    public let isPrimaryKey: Bool?    // nil = unknown at result level
}

public struct RowBatch: Sendable {
    public let rows: [[DBValue]]
    public let startIndex: Int        // absolute row index of rows[0]
}

public enum QueryEvent: Sendable {
    case columns([ColumnMeta])        // exactly once per result set, before any rows
    case rows(RowBatch)
    case complete(QueryCompletion)    // once per statement
}

public struct QueryCompletion: Sendable {
    public let affectedRows: Int64?
    public let lastInsertID: Int64?   // MySQL only
    public let serverTag: String?     // e.g. "SELECT 42", "UPDATE 3"
    public let durationServer: Duration?
    public let durationTotal: Duration
    public let notices: [String]
}
```

---

## 6. DBCore — errors

```swift
public enum DBError: Error, Sendable {
    case connectionFailed(underlying: String, hint: String?)
    case authenticationFailed(user: String)
    case tlsRequiredButUnavailable
    case tunnelFailed(stage: TunnelStage, underlying: String)
    case cancelled
    case timeout(after: Duration)
    case server(ServerError)          // SQLSTATE-bearing error from the DB
    case unsupportedType(nativeName: String)
    case protocolError(String)
    case notConnected
}

public struct ServerError: Sendable, Hashable {
    public let sqlState: String?      // 5-char SQLSTATE where available
    public let code: Int?             // MySQL numeric code
    public let message: String        // verbatim server message
    public let detail: String?
    public let hint: String?
    public let position: Int?         // 1-based char offset in the statement, if server provides
}
```

Rule: the UI shows `ServerError.message` verbatim, plus detail/hint if present, plus the offending statement excerpt with `position` highlighted when available. Never rewrite server messages.

---

## 7. DBCore — driver contract

```swift
public protocol SQLDriver: Sendable {
    static var dialect: SQLDialect { get }          // .postgresql | .mysql
    static var displayName: String { get }
    static var defaultPort: Int { get }

    /// Open one physical connection. `endpoint` is already resolved (post-tunnel).
    static func connect(_ config: ResolvedConnectionConfig, logger: Logger) async throws -> any SQLConnection
}

public protocol SQLConnection: AnyObject, Sendable {
    var serverVersion: ServerVersion { get async }
    var backendID: String { get }                    // pid / thread id, for KILL/cancel and display

    /// Execute one or more statements. Emits events in order. Cancellation must reach the server.
    func execute(_ sql: String, parameters: [DBValue]) -> AsyncThrowingStream<QueryEvent, Error>

    /// Server-side cancel of whatever this connection is currently running. Safe to call from another task.
    func cancelCurrent() async

    func beginTransaction() async throws
    func commit() async throws
    func rollback() async throws
    var isInTransaction: Bool { get async }

    func ping() async throws
    func close() async

    var introspector: any SchemaIntrospector { get }
}
```

### 7.1 Parameterised execution

`execute(_:parameters:)` uses server-side parameters (`$1` Postgres, `?` MySQL). The UI's SQL editor always sends `parameters: []` (raw user SQL). Generated DML from the grid MUST use parameters for values. This is the primary SQL-injection and type-safety boundary.

### 7.2 Multi-statement handling

Drivers do not split statements. `DBSQL.StatementSplitter` splits user SQL into statements respecting strings, comments, dollar-quoting (PG), and `DELIMITER` (MySQL client convention — support it, since users paste dumps). The app executes statements one by one on the same connection, stopping at first error unless "continue on error" is enabled.

### 7.3 Driver-specific requirements

**PostgreSQL (`DBPostgres`)**
- Use `PostgresNIO` with `PostgresClient` for pooling? No — pool is managed by `ConnectionSession`; use `PostgresConnection` per physical connection so `backendID` (pid) and cancel token are accessible. Record this in DECISIONS.md.
- Auth: password, MD5, SCRAM-SHA-256. TLS modes: disable, prefer, require, verify-ca, verify-full. Client cert auth (Phase 3).
- Cancel: implement via PG cancel protocol (new TCP connection, send `CancelRequest` with pid + secret key).
- Type mapping (minimum): bool, int2/4/8, float4/8, numeric→decimal, text/varchar/char/name, bytea, date, time/timetz, timestamp/timestamptz, uuid, json/jsonb, arrays of the above (one level), enum types→string, interval→raw, all others→raw with `pg_type.typname`.
- Notices (`RAISE NOTICE`) delivered into `QueryCompletion.notices`.
- Multiple result sets from one `execute` (e.g. `SELECT 1; SELECT 2;` when sent unsplit) are not required; splitter handles it.

**MySQL / MariaDB (`DBMySQL`)**
- Auth: `mysql_native_password`, `caching_sha2_password` (including the RSA public-key exchange path when TLS is off), `sha256_password`. This is a hard requirement; MySQL 8 defaults to caching_sha2.
- TLS: off, preferred, required, verify-ca, verify-identity.
- Cancel: keep one spare connection in the session for `KILL QUERY <threadId>`.
- Type mapping (minimum): TINYINT(1)→bool only if the column is declared `tinyint(1)` (expose as int otherwise, with a per-connection toggle), all integer types with signed/unsigned, FLOAT/DOUBLE, DECIMAL→decimal, all string types, BINARY/VARBINARY/BLOB→bytes, DATE, TIME, DATETIME (hasTimeZone=false), TIMESTAMP (hasTimeZone=false but server converts; document), YEAR→int, JSON→json, ENUM/SET→string, BIT→raw (the bit string as text for display, the bytes bound back on write; amended by ADR-0040), GEOMETRY→raw.
- `sql_mode`, `time_zone`, `character_set_results=utf8mb4` set on connect.
- `affectedRows` and `lastInsertID` populated from OK packet.
- Escalation rule: if `mysql-nio` cannot satisfy the auth or type list above after a genuine attempt, write the gap in DECISIONS.md and implement the driver over `libmysqlclient` via a system-library SwiftPM target instead. Do not ship a driver that fails MySQL 8 default auth.

**SQLite (`DBSQLite`)**
- A connection is a file: `ConnectionConfig.database` holds the path; `host`, `port`, `user`, password, TLS and SSH are empty and the editor does not show them. The file is refused unless it starts with the SQLite 3 header (or is empty); a missing file is an error unless the `sqliteCreateIfMissing` option is set.
- Threading: every `sqlite3*` call for one file runs on one dedicated thread (a `SerialExecutor` over a `Thread`), never on the cooperative pool. Cancel is `sqlite3_interrupt` from any thread; the stream then throws `.cancelled`. The statement timeout is a progress handler and throws `.timeout`.
- Type mapping: the storage class of each cell decides (`INTEGER`→int, `REAL`→double, `TEXT`→string, `BLOB`→bytes, `NULL`→null), refined by the declared type when the value fits: `BOOL*`→bool, `DATE`/`TIME`/`DATETIME`/`TIMESTAMP`→date/time/timestamp when the text is ISO-8601, `JSON`→json, `UUID`→uuid. Numeric affinity (`DECIMAL`, `NUMERIC`) stores a REAL with fifteen significant digits, and the driver reports the REAL it finds; there is no exact decimal in SQLite and the driver must not invent one. An undeclared column is typed by its first value.
- `affectedRows` is `sqlite3_changes64` read right after an INSERT/UPDATE/DELETE/REPLACE — the statement's own rows, not the rows its triggers or `ON DELETE CASCADE` touched, which `total_changes` would add and which made the grid refuse a correct one-row delete (amended by ADR-0040). DDL never reads it, so it cannot inherit the previous statement's count. `lastInsertID` from `sqlite3_last_insert_rowid` for INSERT/REPLACE. `INSERT … RETURNING` is used by the grid (3.35+).
- Errors: `sqlite3_errmsg` verbatim, the extended result code in `ServerError.code`, and `sqlite3_error_offset` converted from bytes to a one-based character position.
- Session state: `PRAGMA foreign_keys = ON` on connect (option `sqliteForeignKeys`), re-applied by `resetSessionState` after a `PRAGMA`/`ATTACH`. The read-only guard is `PRAGMA query_only`, held by the file. `lower()`/`upper()` are overridden on the connection with Unicode case folding, because Apple's SQLite has no ICU and the built-ins fold ASCII only; the grid's quick search relies on it.
- Introspection: `PRAGMA database_list` (databases), one pseudo-schema `main` per database (`SchemaRef.sqlite`), `sqlite_master` and the `pragma_*` table-valued functions for tables, columns (`table_xinfo`), indexes, foreign keys and the primary key; `sqlite_stat1` for row estimates (nil until `ANALYZE`); `dbstat` for sizes when compiled in; check constraints, foreign-key names, partial-index predicates and trigger timing are read from the DDL text, which is the only place SQLite keeps them. No routines, no partitioning, no comments, no users, no sessions beyond the connection's own; the `ServerIntrospector` reports pragmas and compile options as the "variables".
- Structure changes SQLite's `ALTER TABLE` cannot express (type, nullability, default, key or constraint changes, column order) are generated as the rebuild procedure from SQLite's documentation — `PRAGMA defer_foreign_keys`, create the new table, copy, drop, rename, recreate indexes and triggers — and run in one transaction. `DDLGenerator.sqliteNeedsRebuild(from:to:)` says when.
- Dumps carry `PRAGMA foreign_keys = OFF/ON` around INSERT batches; there is no COPY. Both statement splitters treat `CREATE TRIGGER … BEGIN … END` as one statement (a bare `BEGIN` is a transaction).

### 7.4 Server version

```swift
public struct ServerVersion: Sendable, Hashable {
    public let major: Int, minor: Int, patch: Int
    public let flavor: Flavor       // .postgresql, .mysql, .mariadb, .percona, .aurora, .sqlite, .unknown
    public let rawString: String
}
```

Introspection queries branch on `flavor` and version where catalogs differ (e.g. MariaDB vs MySQL 8 `information_schema` differences, PG `pg_attribute.attgenerated` on 12+).

---

## 8. DBCore — schema introspection

```swift
public protocol SchemaIntrospector: Sendable {
    func databases() async throws -> [DatabaseInfo]                  // MySQL: schemas; PG: databases (requires reconnect to switch)
    func schemas(in database: String) async throws -> [SchemaInfo]   // PG namespaces; MySQL returns single pseudo-schema
    func tables(in schema: SchemaRef) async throws -> [TableInfo]     // tables + views + materialized views, typed
    func columns(of table: TableRef) async throws -> [ColumnInfo]
    func indexes(of table: TableRef) async throws -> [IndexInfo]
    func foreignKeys(of table: TableRef) async throws -> [ForeignKeyInfo]
    func primaryKey(of table: TableRef) async throws -> [String]?    // column names in order, nil if none
    func routines(in schema: SchemaRef) async throws -> [RoutineInfo] // functions/procedures, signature only
    func tableDDL(_ table: TableRef) async throws -> String           // MySQL: SHOW CREATE TABLE; PG: synthesized (Phase 2)
    func approximateRowCount(_ table: TableRef) async throws -> Int64?

    // Added in Phase 8; everything above predates it.
    func checkConstraints(of table: TableRef) async throws -> [CheckConstraintInfo]
    func triggers(of table: TableRef) async throws -> [TriggerInfo]
    func partitioning(of table: TableRef) async throws -> PartitioningInfo?
    /// Collations the server offers, for the column editor's picker.
    func collations(in database: String) async throws -> [CollationInfo]
}
```

Model types (`TableInfo`, `ColumnInfo` etc.) carry: name, kind, comment, and for columns: ordinal, nativeType, nullable, default expression text, isPrimaryKey, isAutoIncrement/identity, isGenerated, character set/collation (MySQL). Keep them plain structs, `Sendable`, `Hashable`, `Identifiable` by fully-qualified name.

Introspection results are cached per session with explicit invalidation (user "Refresh", or after the app itself executes DDL). Never auto-refresh on a timer.

A cache lookup must distinguish "not read yet" from "read, and the answer was nothing". Several of these reads return an optional, and a cache that cannot tell the two apart silently answers every one of them with `nil` and never calls the driver.

---

## 9. ConnectionSession and connection configuration

```swift
public struct ConnectionConfig: Sendable, Codable, Identifiable {
    public var id: UUID
    public var name: String
    public var color: ConnectionColor?        // nil, red, orange, yellow, green, blue, purple, gray
    public var groupPath: [String]            // folder hierarchy in sidebar
    public var dialect: SQLDialect
    public var host: String
    public var port: Int
    public var user: String
    public var passwordRef: SecretRef?        // Keychain reference, never the password itself
    public var database: String?              // initial database
    public var tls: TLSConfig
    public var ssh: SSHConfig?
    public var options: [String: String]      // driver-specific extras (e.g. PG "application_name", MySQL "tinyint1IsBool")
    public var statementTimeout: Duration?
    public var readOnly: Bool                 // app-level guard: blocks any non-SELECT unless user overrides per statement
    public var isProduction: Bool             // triggers confirmation on every write + red badge
}

public struct SSHConfig: Sendable, Codable {
    public var host: String; public var port: Int; public var user: String
    public var auth: SSHAuth                  // .password(SecretRef) | .privateKey(path: String, passphrase: SecretRef?) | .agent
    public var jumpHost: SSHConfig?           // one level of bastion (indirect recursion via Box)
    public var knownHostsPolicy: KnownHostsPolicy   // .strict | .acceptNew | .ignore (ignore requires explicit checkbox with warning)
}
```

`ConnectionSession` (actor) responsibilities:
1. Resolve secrets from Keychain.
2. Open SSH tunnel if configured; bind a local ephemeral port; produce `ResolvedConnectionConfig` pointing at 127.0.0.1:port.
3. Own the pool of `SQLConnection` (max 8), hand out one per `QueryTab`, reclaim on tab close.
4. Own the introspection cache.
5. Track state: `.disconnected`, `.connecting(stage:)`, `.connected`, `.degraded(Error)`, and publish it (AsyncStream) to the UI.
6. Reconnect policy: on connection drop, mark `.degraded`, do not auto-reconnect while a transaction was open (user must decide); otherwise reconnect on next use with one retry.

Secrets: stored in macOS Keychain under service `com.tinker.connection`, account = `<configID>.<field>`. Access group not needed. On config deletion, delete Keychain items. Passwords are never written to disk, logs, or crash reports.

---

## 10. Application UI — global

### 10.1 Window structure

One `NSWindow` per workspace. A workspace contains:

```
┌───────────────────────────────────────────────────────────────┐
│ Toolbar: [Connect ▾] [New Query ⌘T] [Run ⌘↩] [Cancel ⌘.] [Commit][Rollback] [Refresh ⌘R]   [Search ⌘⇧F] │
├──────────┬────────────────────────────────────────────────────┤
│ Sidebar  │ Tab bar:  [users ×] [SQL 1 ×] [orders ×] [+]        │
│          ├────────────────────────────────────────────────────┤
│ Conns    │                                                    │
│  ▾ prod  │   Tab content (Data grid | SQL editor + results)   │
│    ▾ db  │                                                    │
│      ▾ … │                                                    │
│ Filter ⌘⇧O  ├────────────────────────────────────────────────────┤
│          │ Status bar: conn name • db • server version • rows • time • tx state │
└──────────┴────────────────────────────────────────────────────┘
```

- Sidebar: `NavigationSplitView` with SwiftUI `List`/`OutlineGroup`. Collapsible with `⌘⌥S`.
- Tabs: custom SwiftUI tab bar (not `NSTabView`). Drag reorder, middle-click close, `⌘W` closes tab, `⌘⇧W` closes window, `⌘1–9` selects tab, `⌘⇧]`/`⌘⇧[` cycles.
- Each tab is either a **Table tab** (data grid for one table/view) or a **Query tab** (editor + results). Tabs belong to one connection; the tab bar shows the connection's color as a stripe.
- Multiple windows: `⌘N` opens a new workspace. Connection sessions are shared across windows (one session per config app-wide).
- Dark/light follow system; all colors from a `DesignTokens` enum mapping to `NSColor` system colors. No hard-coded hex except connection colors.

### 10.2 Keyboard shortcuts (complete list, must all work)

Amended by ADR-0041: Run is ⌘R, Run All ⌘⌥R, Run Selected ⌘⌃R, Refresh F5, Export ⌘⌥E and Copy as INSERT ⌘⌃C, for the reasons recorded there. Every other row below is as the app has it.

| Action | Shortcut |
|---|---|
| New query tab | ⌘T |
| Run selection or statement at cursor | ⌘↩ |
| Run all statements in editor | ⌘⇧↩ |
| Cancel running query | ⌘. |
| Commit | ⌘⇧S |
| Rollback | ⌘⇧R |
| Refresh (current tab data / schema) | ⌘R |
| Open table quick-switcher | ⌘⇧O |
| Find in editor / grid | ⌘F |
| Find & replace in editor | ⌘⌥F |
| Filter grid | ⌘⇧F |
| Toggle sidebar | ⌘⌥S |
| New window | ⌘N |
| Close tab / window | ⌘W / ⌘⇧W |
| Save query to file | ⌘S |
| Open SQL file | ⌘O |
| Format SQL | ⌘⇧I |
| Comment line | ⌘/ |
| Duplicate line | ⌘D |
| Toggle read-only for this connection | ⌘⇧L |
| Export current result | ⌘E |
| Copy row(s) as INSERT | ⌘⌥C |
| Copy cell value (raw) | ⌘C |
| Set cell NULL | ⌘⌫ |
| Add row | ⌘+ |
| Delete selected rows | ⌘− |
| Go to previous/next result tab | ⌥⌘← / ⌥⌘→ |

All shortcuts are registered via SwiftUI `Commands` so they appear in menus and are discoverable.

### 10.3 Error presentation

- Server errors: inline non-modal banner at top of the results area, red left border, monospaced message, "Copy" button, and (when position is known) the editor jumps to and highlights the offending token.
- Connection errors: sheet with stage (DNS / TCP / SSH / TLS / auth), the underlying message, and a "Retry" button.
- Never use `NSAlert` for query errors. Use it only for destructive confirmations.

---

## 11. Connections feature

### 11.1 Sidebar

- Tree: Groups → Connections → Databases → (Schemas for PG) → Tables / Views / Functions.
- Connection nodes show: color dot, name, status indicator (gray/green/yellow/red), `prod` badge if `isProduction`.
- Double-click connection: connect and expand. Single click: select (shows details in inspector, Phase 2).
- Double-click table: open Table tab (or focus if already open). ⌥-double-click opens a new tab anyway.
- Context menu on table: Open, Open in New Tab, New Query with `SELECT * FROM … LIMIT 100`, Copy Name, Copy Qualified Name, Copy DDL, Truncate…, Drop… (both destructive → confirmation sheet requiring the table name to be typed when `isProduction`).
- Filter field (`⌘⇧O`) fuzzy-matches table names across all connected databases; ↩ opens.
- Groups are drag-and-drop reorderable and persist.

### 11.2 Connection editor (sheet)

Fields laid out in a `Form`:
- General: Name, Color, Group, Type (PostgreSQL / MySQL), Host, Port (defaults per type), User, Password (SecureField, "Save in Keychain" always on; there is no "don't save"), Database.
- TLS: Mode picker, CA file, client cert/key (Phase 3), Server name override.
- SSH: Enable toggle; Host, Port (22), User, Auth (Password / Key file / Agent), Key path with file chooser, Passphrase, Jump host (collapsed disclosure).
- Advanced: Statement timeout, Application name, `tinyint(1)` as bool (MySQL), Read-only, Production.
- Footer: "Test Connection" (runs full connect path, reports stage-by-stage result in a small log view), Cancel, Save.

Validation: host/user required; port 1–65535; key file must exist and not be world-readable (warn, don't block).

### 11.3 Acceptance criteria

- Can create, edit, duplicate, delete, and group connections; changes persist across relaunch.
- Passwords never appear in `~/Library/Application Support/Tinker/*` files (test asserts this).
- SSH tunnel through a password-auth host and a key-auth host both work against the SSH test target (see §17.1).
- Connecting to a stopped server surfaces `.connectionFailed` with stage `tcp` within the timeout.

---

### 11.4 Database overview ("Objects")

Double-clicking a database or a schema in the sidebar opens an **Objects** tab listing what
it holds, so a database can be surveyed without expanding a tree node at a time.

- One row per object: name, kind, estimated rows, data length, engine (MySQL), collation,
  owner (PostgreSQL), and comment. Every figure comes from the introspector; nothing here
  runs `COUNT(*)`.
- A search field filters the list by name as the user types. Sorting is by any column.
- Double-clicking a row opens that table's tab; the context menu offers Open, Structure,
  Copy DDL and Drop.
- The counts are the server's estimates and are labelled as such, because a planner
  estimate is not a row count and showing it as one is a lie the user cannot check.

---

## 12. Data grid feature (Table tab and results)

This is the highest-risk component. It is an `NSTableView` (view-based, `usesAutomaticRowHeights = false`, fixed row height 22pt) inside an `NSScrollView`, wrapped for SwiftUI. One implementation serves both Table tabs and query results; Table tabs add editing and paging controls.

### 12.1 Data source model

```swift
@MainActor
final class GridDataSource {
    var columns: [ColumnMeta]
    var rowCount: Int              // known rows loaded
    var totalCount: Int?           // exact if known, else nil
    var isExhausted: Bool
    var buffer: RowBuffer          // ring/windowed storage, see below
    var edits: EditBuffer          // pending changes overlay
    func value(row: Int, col: Int) -> DBValue   // reads edits overlay first
    func ensureLoaded(range: Range<Int>) async  // triggers fetch of next page(s)
}
```

### 12.7 Pages

A table tab shows one page of at most 1,000 rows, not an endless scroll. The status bar
carries first / previous / next / last, the page number, and the row range being shown.

- Moving between pages re-reads from the server; it never holds more than the current page.
- The page size is a setting, defaulting to 1,000.
- A filter or a sort returns to page 1, because both change what page 2 would mean.
- Where the total is known — the filter's exact count, or a short final page — the status
  bar shows it. Where it is only the planner's estimate, it says so rather than presenting
  an estimate as a count.
- Query results keep streaming as §13 describes: a result set is what the statement
  returned, and paging it would mean running a different statement.

- **Paging strategy for Table tabs:** page size 1,000 rows. Query is `SELECT <cols> FROM t [WHERE filter] [ORDER BY sort] LIMIT 1000 OFFSET n`. Both dialects. When the table has a single-column integer PK and no user sort, use keyset paging (`WHERE pk > last ORDER BY pk LIMIT 1000`) instead of OFFSET beyond page 50 (OFFSET degrades). Record the choice in the status bar tooltip.
- **Streaming for query results:** rows append as batches arrive; grid calls `insertRows` incrementally; scroll position is preserved unless user is at the bottom.
- **Memory cap:** `RowBuffer` keeps at most 200,000 rows in memory. Beyond that for Table tabs, pages far from the viewport are evicted and refetched on demand (window of ±20 pages). For query results, beyond 200k rows the stream is paused and a banner offers "Load more (200k)" / "Export remaining to file directly" / "Cancel".
- Cell rendering: custom `NSView` subclass per cell reusing `NSTextField` with `drawsBackground=false`; NULL rendered as italic gray `NULL`; binary as `<N bytes>`; long text truncated at 512 chars in-cell with full value in the cell inspector; JSON pretty-printed in inspector only.
- Column widths persist per table per connection. Double-click column edge autosizes from loaded rows.

### 12.2 Sorting and filtering (Table tabs)

- Click column header: cycles none → ASC → DESC. ⇧-click adds secondary sort. Sort is server-side; reloads from page 1.
- Filter bar (`⌘⇧F`): rows of `[column] [operator] [value]`, operators: `=`, `≠`, `<`, `≤`, `>`, `≥`, `contains`, `starts with`, `ends with`, `is null`, `is not null`, `in (…)`, `between`. Combined with AND; an "Advanced" toggle shows the generated WHERE clause in an editable text field (raw mode). Values are sent as parameters, never interpolated.
- Filter and sort state persist per table per connection.

### 12.3 Editing (Table tabs only; results are read-only unless single-table with PK, Phase 2)

- Editing enabled only when the table has a primary key (or, for PG, a unique NOT NULL index; MySQL: unique NOT NULL index). Otherwise the grid is read-only with a status bar note "No primary key — read only".
- Double-click or ↩ on a cell starts inline edit with a type-appropriate editor: text field (strings/numbers), bool toggle popover, date/time picker popover with raw-text fallback, JSON/long text opens the cell inspector panel. ⌘⌫ sets NULL. Esc cancels. Tab moves right.
- Edits are held in `EditBuffer` and shown with a yellow cell background; new rows green; rows marked for deletion red with strikethrough. Nothing is sent until **Commit** (`⌘⇧S`) or Discard.
- Commit flow: generate statements → show the **Preview sheet** listing every statement (monospaced, syntax-highlighted, parameters rendered as literals for display) with a count summary → user clicks "Execute" → run inside one transaction → on success clear buffer and refresh affected rows in place; on any failure roll back everything and keep the buffer intact, showing the error against the failing statement.
- Generated DML rules:
  - `UPDATE t SET c1=$1, c2=$2 WHERE pk1=$3 AND pk2=$4` — only changed columns; WHERE uses PK columns with their **original** values.
  - `DELETE FROM t WHERE pk…` — same.
  - `INSERT INTO t (cols…) VALUES (…)` — only columns the user filled; others rely on defaults. After insert, refetch the row by PK (MySQL: `lastInsertID` for auto-increment; PG: use `RETURNING *`).
  - Each UPDATE/DELETE MUST be followed by an affected-row check: if `affectedRows != 1`, roll back the transaction and report "Expected 1 row, got N — data may have changed since load".
- `isProduction` connections: the Preview sheet's Execute button is disabled for 1.5s and labelled with the connection name in red.
- `readOnly` connections: Commit is disabled; the grid shows an unlock affordance (`⌘⇧L`) that toggles for the session only.

### 12.4 Selection, copy, paste

- Cell, row, column, and rectangular range selection like a spreadsheet.
- `⌘C` copies TSV of selection (NULL as empty, configurable to `NULL`). `⌘⌥C` copies selected rows as INSERT statements in the connection's dialect. Context menu offers copy as CSV / JSON / Markdown table / WHERE-IN list.
- `⌘V` into an editable grid pastes TSV into cells starting at the selection anchor (creates new rows if past the end), respecting type coercion; invalid values are flagged, not silently dropped.

### 12.5 Cell inspector

Right-side panel (`⌘⌥I`) showing the focused cell: column name, native type, raw value (editable text view), and for JSON a formatted read-only view with "Copy formatted". Byte values show hex dump + "Save as file…".

### 12.6 Acceptance criteria

- Fixture `big_table` with 1,000,000 rows (created by `testenv/fixtures`): opening the Table tab shows first page in < 500 ms; scrolling to the end via scrollbar drag stays responsive (main thread never blocks > 16 ms — verify with a signpost-based test); memory stays < 600 MB.
- Editing three cells in two rows and committing generates exactly two UPDATE statements with correct WHERE clauses (unit test on the generator with fixed inputs).
- Concurrent modification: change a row's PK value in another session before commit → commit fails with the "Expected 1 row" error and nothing is written (integration test).
- Tables with composite PK, with UUID PK, and with no PK all behave per spec.

---

## 13. SQL editor and query tab

### 13.1 Editor

- `NSTextView` subclass with: line numbers gutter, current-line highlight, syntax highlighting via tree-sitter (keywords, strings, comments, numbers, identifiers), bracket matching, auto-indent, `⌘/` comment toggling, multi-cursor not required.
- Font: user setting, default SF Mono 13.
- Statement-at-cursor detection uses `DBSQL.StatementSplitter`; the current statement's range is subtly highlighted in the gutter.
- Autocomplete (popover, triggered after 1 char or `⌃Space`): keywords, table names in current schema, columns of tables referenced in the current statement (alias-aware: `FROM users u` → `u.` lists users' columns), functions. Ranked by prefix match then fuzzy. Schema data comes from the session introspection cache.
- Error position from `ServerError.position` maps to a red squiggle until the text changes.
- Format SQL (`⌘⇧I`): a conservative formatter (uppercase keywords, one clause per line, indent sub-selects). Ship a small in-house implementation; do not pull a large dependency.

### 13.1a The tab's session

A query tab carries its own connection and database, chosen from two pickers in its
toolbar. Statements run in that session, so a query reads `SELECT * FROM t` rather than
`SELECT * FROM db.t`.

- Changing it issues the engine's own switch: `USE db` on MySQL, `SET search_path TO
  schema` on PostgreSQL, whose unqualified names resolve against the search path rather
  than against a database it cannot change on an open connection. The picker is therefore
  labelled Database on MySQL and Schema on PostgreSQL.
- A new tab inherits the connection and database of whatever was in front of it.
- The pickers show what the session actually holds after the switch, not what was asked
  for: a failed switch leaves the previous database selected and reports the server's words.

### 13.2 Execution

- `⌘↩`: if there is a selection, run the selection as one script; else run the statement under the cursor.
- `⌘⇧↩`: run every statement in the editor sequentially.
- Each statement produces one result tab beneath the editor (tabs labelled with the first 40 chars of the statement). Non-SELECT statements produce a message-only result ("UPDATE 3 rows in 12 ms").
- Auto-commit toggle in the query tab toolbar (default on). When off, the status bar shows "Transaction open" in orange and `Commit`/`Rollback` become active. Closing a tab with an open transaction asks Commit / Rollback / Cancel.
- Running indicator with elapsed time; `⌘.` cancels via server-side cancel.
- Query history: every executed statement (text, connection, database, timestamp, duration, row count / error) is stored in `DBStore` (SQLite), capped at 10,000 entries, searchable from a History panel (`⌘Y`). Double-click inserts into editor.
- Default result row limit: none. Streaming handles it; the 200k banner from §12.1 applies.

### 13.2a Result panes

Each executed statement produces a result with four panes, chosen by a segmented control:

- **Message** — the statement and what the server said, with its elapsed time.
- **Result N** — the rows. One pane per result set the statement produced.
- **Profile** — per-stage timings, where the engine offers them. MySQL's `SHOW PROFILE`,
  which needs `profiling` on for the session. PostgreSQL has no equivalent that does not
  re-run the statement, and re-running a write to time it is not something a client may do
  behind the user's back, so the pane says so and offers `EXPLAIN (ANALYZE)` as an explicit
  action for a `SELECT`.
- **Status** — the session counters: MySQL's `SHOW SESSION STATUS`, PostgreSQL's row from
  `pg_stat_database`.

Profile and Status are read when their pane is opened, not after every statement. Both cost
a round trip, and a pane nobody looks at should cost nothing.

The status line under the panes carries the SQL that ran, the elapsed time and the row
count, so what produced the rows on screen is always visible.

### 13.3 Acceptance criteria

- Pasting a 2,000-statement MySQL dump with `DELIMITER $$` procedures and running all executes correctly and reports per-statement results.
- A PG syntax error at position 37 highlights the correct token.
- Cancelling `SELECT pg_sleep(60)` returns within 1 s with `.cancelled`; the server connection is reusable afterwards (verified via `SELECT 1` on the same tab).
- Autocomplete offers alias-qualified columns.
- A query tab set to a database runs `SELECT * FROM t` without qualifying `t`.
- A table of 2,500 rows shows 1,000, reports which page it is on, and reaches the last row
  through the pager without ever holding more than one page.
- The Objects list of a schema names every table the sidebar lists, with the same counts
  the introspector reports.

---

## 14. Export

- Entry points: `⌘E` on any grid (Table tab or result), context menu, and "Export table…" from the sidebar (exports full table by streaming, not via the grid).
- Formats v0.1: CSV (configurable delimiter, quote, header, NULL representation, encoding UTF-8/UTF-8-BOM), JSON (array of objects or NDJSON), SQL INSERT (batch size, target dialect = source dialect only, include `CREATE TABLE` optional).
- Scope: selection / loaded rows / entire query or table (re-executes and streams to disk; progress sheet with cancel).
- Export runs off the main thread, writes with buffered `FileHandle`, never materialises the whole file in memory.

---

## 15. Persistence (`DBStore`)

SQLite database at `~/Library/Application Support/Tinker/store.sqlite` (WAL mode). Tables:
- `connections` (id, json blob of `ConnectionConfig` minus secrets, sort_order, updated_at)
- `groups` (path, expanded)
- `query_history` (id, connection_id, database, sql, started_at, duration_ms, rows, error, success)
- `grid_prefs` (connection_id, table_qualified_name, column_widths json, sort json, filter json)
- `saved_queries` (Phase 2)
- `settings` (key, value json)

Migrations: numbered SQL files applied in order, version tracked in `PRAGMA user_version`. No ORM; a small typed query layer over `SQLite3` C API.

---

## 15b. Table designer and structure sync

Editing structure, not rows. Everything here goes through the same discipline §12.3 already imposes on data edits: nothing runs until the user has read the SQL, and what runs, runs in one transaction.

### 15b.1 Structure tab

A table opens with a **Data** tab and a **Structure** tab. Structure is read-only until the user presses Edit, so browsing a production schema cannot alter it by a stray keystroke.

Structure has one pane per kind of object, each a table of rows the user can add to, edit and remove:

- **Columns** — name, type, length/precision/scale, nullable, default, auto-increment/identity, generated expression, character set, collation, comment. Reordering is offered only where the server supports it (MySQL `AFTER`); on PostgreSQL the control is absent, not disabled-with-a-tooltip.
- **Indexes** — name, method (btree, hash, gin, gist, brin, spgist on PG; btree, hash, fulltext, spatial on MySQL), column list with per-column sort direction, unique, partial predicate (PG), comment.
- **Primary key** — chosen on the Columns pane by marking columns, in key order. Dropping and adding a primary key is a single edit, not two.
- **Foreign keys** — name, local columns, referenced table and columns, `ON UPDATE` / `ON DELETE`, deferrability (PG).
- **Check constraints** — name and expression, stored verbatim.
- **Triggers** — name, timing (`BEFORE`/`AFTER`/`INSTEAD OF`), events, level (row/statement), condition (PG `WHEN`), and the body or the function it calls.
- **Partitions** — the strategy and key for a partitioned table, and the list of partitions with their bounds. Creating and detaching partitions is in scope; rewriting an unpartitioned table into a partitioned one is not.
- **Table** — name, comment, storage engine and character set (MySQL), tablespace (PG).

### 15b.2 How a change is applied

- The designer never mutates anything as the user types. It holds an edited `TableDefinition` beside the one introspection returned.
- **Preview** diffs the two and renders the statements. The sheet shows them in execution order, syntax-highlighted, and is the only route to Execute.
- Execution runs every statement in one transaction. PostgreSQL rolls back cleanly; **MySQL commits DDL implicitly**, so on MySQL the sheet says so plainly, lists the statements that will not roll back, and asks for confirmation naming the table.
- After execution the app invalidates that table's introspection and reloads the pane from the server. What is shown afterwards is what the server has, never the edit that was requested.
- A failure reports the server's message verbatim (§6) alongside the statement that produced it, and leaves the editor's state intact so the user can correct it.
- `isProduction` and `readOnly` connections behave as in §12.3: read-only forbids Execute outright; production delays the button and names the connection in red.

### 15b.3 Create table

The same editor with an empty definition. It emits one `CREATE TABLE` plus the `CREATE INDEX`, `COMMENT ON` and trigger statements the definition needs, in dependency order.

### 15b.4 Structure sync

Compares a source table or schema against a target on any configured connection, including across engines, and produces the DDL that would make the target match. It is a generator, not an applier: the result opens in a SQL editor tab. It never drops anything the user has not seen; destructive statements are listed separately in the preview and are unchecked by default.

### 15b.5 Acceptance criteria

- Adding a column, changing its type, marking it `NOT NULL`, setting a default and dropping it each produce the statements the server accepts, verified against local PostgreSQL and MySQL fixtures.
- Setting a primary key on `no_pk` makes the Data tab editable without reopening the tab, because introspection was invalidated.
- Creating a btree index and a unique index on `customers`, then dropping them, round-trips through introspection: what the designer shows afterwards equals what the server reports.
- A composite foreign key with `ON DELETE CASCADE` created by the designer is read back with the same actions.
- A failing statement (a duplicate index name) leaves the table unchanged on PostgreSQL, reports the server's text, and on MySQL reports exactly which statements had already committed.
- Structure sync of a table against itself produces no statements.
- No pane blocks the main thread: opening Structure on a table with 100 columns and 30 indexes stays under one frame (§12.6 method).

---

## 16. Phased execution plan

Each phase lists deliverables and acceptance criteria. Do not reorder.

### Phase 0 — Scaffold (½ day)
- Repo layout per §3, `Package.swift` workspace, empty packages compiling, app target launching an empty window, `Tools/dbcli` printing "hello".
- `testenv/prepare.sh`: reads `TINKER_TEST_PG_ADMIN_URL` and `TINKER_TEST_MYSQL_ADMIN_URL` (superuser/root URLs to the developer's existing local servers), creates database `tinker_test` and user `tinker_test` with rights only on that database, loads fixtures. Idempotent. Installs and starts nothing. Prints the non-admin URLs to export as `TINKER_TEST_PG_URL` / `TINKER_TEST_MYSQL_URL`.
- `Scripts/ci.sh`: builds and runs unit tests; if `TINKER_TEST_PG_URL` / `TINKER_TEST_MYSQL_URL` are set, also runs integration tests for those engines; otherwise skips them with a visible warning, never a silent pass.
- Accept: `Scripts/ci.sh` green after `testenv/prepare.sh` against the developer's local servers.

### Phase 1 — DBCore + PostgreSQL driver (2 weeks)
- §5, §6, §7 (Postgres), §8 (Postgres introspector), `DBSQL.StatementSplitter` (PG dialect), `DBSQL.Identifier` quoting.
- `dbcli`: `dbcli pg://user:pass@host/db "SELECT …"` streams rows as TSV; `dbcli … --introspect` dumps schema JSON; `dbcli … --cancel-after 2s` demonstrates cancel.
- Tests: type round-trip for every mapped type against all PG versions; cancel; SCRAM auth; TLS require against a self-signed fixture; introspection snapshots for a fixture schema (tables, views, matviews, composite PK, FKs, identity columns, enums, arrays).
- Accept: all above green on the local PG (`TINKER_TEST_PG_URL`) and on any additional URL in `TINKER_TEST_PG_URLS` (comma-separated, optional). Log the detected server version in the test output.

### Phase 2 — ConnectionSession, tunnel, store (1.5 weeks)
- §9 session actor with pool, state stream, reconnect policy. `DBTunnel` with Citadel (password, key, agent, jump host). `DBStore` with migrations, Keychain wrapper.
- SSH test target: by default the local machine's `sshd` (Remote Login must be enabled in System Settings; `testenv/README.md` documents it) with the current user via agent/key auth. Password-auth and jump-host tests run only when `TINKER_TEST_SSH_PASSWORD_URL` / `TINKER_TEST_SSH_JUMP_URL` are set; otherwise they are skipped with a warning.
- Tests: tunnel connect (key/agent always; password and jump when configured); session pool limits; Keychain round-trip; assert no secret bytes in store file.
- Accept: `dbcli` can connect via `--ssh user@localhost` to the local PG.

### Phase 3 — Data grid (3–4 weeks)
- §12 in full for Table tabs, backed by Postgres.
- A standalone `GridPlayground` app target that loads synthetic 1M-row data without a DB, for perf iteration.
- Tests: generator unit tests (UPDATE/DELETE/INSERT for simple, composite, UUID PK); paging strategy selection; scroll performance signpost test; concurrent-modification integration test.
- Accept: §12.6 criteria.

### Phase 4 — App shell, connections UI, schema browser (2 weeks)
- §10, §11. Sidebar, tabs, windows, shortcuts, error presentation, settings window (font, NULL display, confirm-on-prod toggles).
- Accept: §11.3 criteria; full shortcut table verified manually and via a checklist in `PROGRESS.md`.

### Phase 5 — SQL editor and query tabs (3 weeks)
- §13 in full. Result grids reuse Phase 3 grid in read-only mode. Query history. Export (§14).
- Accept: §13.3 criteria; export of 1M rows to CSV completes with flat memory.

### Phase 6 — MySQL driver (1.5 weeks)
- §7.3 MySQL, introspector, splitter `DELIMITER` support, dialect-specific paging/quoting/DML generation.
- The app must require **zero** UI code changes to support MySQL. If a UI change is needed, the abstraction leaked; fix it in DBCore/DBSQL and record in DECISIONS.md.
- Tests: mirror the PG suite against the local MySQL (`TINKER_TEST_MYSQL_URL`) and any URLs in `TINKER_TEST_MYSQL_URLS` (intended for a MariaDB 10.11+ and a MySQL 5.7 server if you have them), with special attention to caching_sha2 auth (TLS on and off), unsigned BIGINT max, DECIMAL precision, DATETIME vs TIMESTAMP, zero dates under permissive sql_mode.
- Known gap: without a MySQL 5.7 and a MariaDB server in `TINKER_TEST_MYSQL_URLS`, `mysql_native_password` and MariaDB catalog differences are untested. Record this in `PROGRESS.md` at the end of the phase; do not claim coverage that did not run.
- Accept: identical feature matrix to PG; MySQL 8.4 default install connects with no user configuration beyond host/user/password.

### Phase 7 — Release hardening (1 week)
- Sparkle, signing, notarization script, crash reporting opt-in (local logs only, no third-party), first-run experience, app icon, DMG.
- Accept: notarized DMG installs and runs on a clean macOS 14 machine with no Xcode.

### Phase 9 — Objects list, pages, the tab's session and result panes (2 weeks)
- §11.4 Objects tab, §12.7 pages, §13.1a connection and database pickers, §13.2a Message /
  Result / Profile / Status panes.
- Tests: paging unit tests over a fixture loader (first/last/next/previous, the page a
  filter returns to); an integration test per engine that switches a tab's database and
  runs an unqualified statement against it; Objects against the local fixtures.
- Accept: the §13.3 criteria added for them.

### Phase 8 — Table designer and structure sync (4 weeks)
- §15b in full, both engines. `DBSQL.DDLGenerator` diffs two `TableDefinition`s into ordered statements; the introspector gains check constraints, triggers, partitioning and collations (§8).
- The Structure tab, its panes, the preview sheet, Create Table, and structure sync as a generator.
- Tests: a diff unit suite per dialect covering every column attribute, primary-key add/drop/change, index add/drop including method and partial predicate, foreign-key actions, check constraints and triggers; integration tests that run the generated DDL against the local PG and MySQL and read it back through introspection, asserting the round trip; a failure test asserting PostgreSQL rolls back and that MySQL's partial-commit warning names the right statements.
- Accept: §15b.5 criteria, on PostgreSQL and MySQL.

### Phase 10 — SQLite (added 2026-09-09)
- `DBSQLite` per §7.3; `SQLDialect.sqlite` handled everywhere the other two are (every `switch` over the dialect stays exhaustive, and the App branches on `hasSchemaLayer` / `isFileBased` / `hasUserAccounts` rather than on `== .mysql`).
- A database file opens as a connection: dropped on the window, opened from Finder (document types for `.sqlite`, `.sqlite3`, `.db`, `.db3`, `.s3db`, `.sl3`), or chosen from File › Open SQLite Database… (⌥⌘O). A file that already has a connection reuses it; otherwise a connection named after the file is saved. The connection editor has a file mode with Choose… and New….
- Tests: the SQLite suite runs against a temporary database file the suite creates itself, so it never skips and needs no environment variable (`TINKER_TEST_SQLITE_DISABLED` leaves it out); the grid, transfer and sync suites run against SQLite alongside the configured servers. Fixtures in `testenv/fixtures/sqlite/` mirror the other engines' where SQLite can.
- Accept: every §12.6 and §13.3 criterion that a file can meet, on the SQLite fixture; the rebuild of a column change verified by reading the table back; a trigger body imported whole; `EXPLAIN QUERY PLAN` recognised as read-only.

Deferred to v0.2 (do not build now, do not stub): EXPLAIN visual, editing of multi-table results, client-cert TLS, Redis, other engines, attached SQLite databases beyond listing them. (Amended: import, data transfer, dump/restore, snippets and the table designer were pulled into Phases 8–9 by ADR-0028 and exist; they are no longer deferred.)

---

## 17. Testing strategy

- **Unit tests** (no I/O): value model, splitter, quoting, DML/DDL generators, paging strategy, EditBuffer semantics, filter → WHERE compilation, formatter.
- **Integration tests**: every driver capability in §7.3 against every server the test environment can reach. Fixture schema and data are created by `testenv/fixtures/<dialect>/*.sql` and are identical in intent across dialects. Tests are tagged by dialect; the server version is read at runtime and reported in the test log so gaps are visible.

### 17.1 Test environment (no Docker)

- The developer's existing local PostgreSQL and MySQL are the primary targets. `testenv/prepare.sh` only creates the isolated `tinker_test` database and user on them; it never modifies server configuration, other databases, or global settings.
- SQLite needs no server and no preparation: `TestEnvironment.servers(for: .sqlite)` returns a temporary file under the process's temporary directory, and each suite loads `testenv/fixtures/sqlite/*.sql` into it once per process.
- All servers are supplied purely through environment variables:
  - `TINKER_TEST_PG_URL` / `TINKER_TEST_PG_URLS`
  - `TINKER_TEST_MYSQL_URL` / `TINKER_TEST_MYSQL_URLS`
  - (SSH needs none: the tunnel suites start their own servers, in-process and the machine's `sshd`, ADR-0014 and ADR-0039. `TINKER_TEST_SSH_PASSWORD_URL` and `TINKER_TEST_SSH_JUMP_URL` were listed here but never read; removed by the Phase 4 review.)
- Integration tests **must** run against a database named `tinker_test` and refuse to run (fail loudly) if the URL points anywhere else or if the user in the URL has privileges beyond that database (PG: not superuser; MySQL: no global grants). They drop and recreate fixture objects at start; they never touch other databases. This is the only protection for the developer's real local data.
- Skipped tests are reported as skipped with the reason. CI output ends with a coverage summary: which engines/versions actually ran.
- **Performance tests**: grid scroll and memory using `XCTMetric` and os_signpost; export memory flatness.
- **UI tests**: minimal XCUITest smoke: launch, create connection, connect, open table, run query, cancel query. Everything else is covered below the UI layer by design.
- Test data must include: Unicode (CJK, emoji, RTL), very long strings (1 MB), binary with all 256 byte values, NULLs in every column type, extreme numerics (`-2^63`, `2^64-1` unsigned, `NUMERIC(65,30)`), timestamps at DST boundaries and year 0001/9999, arrays with nulls (PG), JSON with nested depth 50.

---

## 18. Definition of done (every task)

1. Code compiles under Swift 6 strict concurrency with zero warnings.
2. New public API has doc comments and is covered by tests.
3. No `try!`, no `!` force-unwraps outside tests, no `DispatchQueue` (use structured concurrency), no `print` (use Logger).
4. No secret, connection string, or user data in logs above `.debug`.
5. `PROGRESS.md` updated; any deviation from this spec recorded in `DECISIONS.md` with rationale.
6. Manual verification steps listed in the PR/commit message when behaviour is user-visible.
