# PROGRESS.md — per-phase log

Current phase: **Phase 6 — MySQL driver** (Phases 0–5 complete).

---

## Phase 0 — Scaffold (2026-09-03)

### Done
- Repository layout per SPEC §3: `Packages/{DBCore,DBPostgres,DBMySQL,DBTunnel,DBStore,DBSQL,DBTestKit}`, `App/DBStudio`, `Tools/dbcli`, `testenv/`, `Scripts/`.
- Root `Package.swift` (tools 6.2, Swift 6 language mode → strict concurrency complete, macOS 14) with one target per package plus test targets; only dependency is swift-log (ADR-0001).
- `DBCore.SQLDialect` (SPEC §7/§9) is the single real type landed; all other packages are compiling placeholders.
- `DBTestKit.TestEnvironment`: resolves `DBSTUDIO_TEST_{PG,MYSQL}_URL(S)`, refuses any database other than `dbstudio_test` and admin user names (fails, does not skip), skips with a reason when unset, and prints a redacted summary.
- `Tools/dbcli` prints `hello`.
- `App/DBStudio.xcodeproj`: SwiftUI app, macOS 14.0, arm64 only, Swift 6, strict concurrency, hardened runtime on, App Sandbox off, warnings as errors, links `DBCore` from the root package; opens one empty window (ADR-0002). Shared scheme `DBStudio`.
- `testenv/prepare.sh`: creates `dbstudio_test` db + user on the developer's existing PG/MySQL from admin URLs, loads `testenv/fixtures/<dialect>/*.sql` as the test user, verifies not-superuser / no-global-grants, prints the non-admin URLs. Idempotent (re-run verified). Installs nothing.
- `Scripts/ci.sh`: rebuilds first-party modules with zero-warning gate, lints import direction, runs `swift test`, builds the app with xcodebuild, warns visibly when an engine's URL is unset, and ends with a coverage summary.

### Verified against local servers
- PostgreSQL 16.15 (Homebrew, `localhost:5432`): prepare OK; test user `rolsuper=f`, `CREATE TABLE` in another database denied.
- MySQL 9.4.0 (Laravel Herd, `127.0.0.1:3306`, root has an empty password): prepare OK; grants are exactly `USAGE ON *.*` + `ALL ON dbstudio_test.*`; `CREATE DATABASE` denied.
- `Scripts/ci.sh` green with both URLs exported.

### Tests
- `DBTestKitTests.TestEnvironmentTests` (11): env parsing order, primary+additional lists, refusal of other databases / missing database / admin users / wrong scheme / garbage, password redaction, `XCTSkip` when unset, summary text.
- `DBCoreTests.SQLDialectTests`: raw values are stable (they are persisted).
- One link-smoke test per placeholder package.

### Deferred / gaps
- Real privilege check (PG superuser, MySQL global grants) at connect time → Phase 1 (ADR-0006).
- Fixture set is a single `smoke` table; the full SPEC §17 fixture data (Unicode, 1 MB strings, extreme numerics, DST timestamps, 1M-row `big_table`) lands with the phases that consume it.
- No integration test actually opens a network connection yet (no driver). `ci.sh` reports the configured engines from the environment; from Phase 1 the driver tests log the detected server version.
- Only MySQL 9.4 is available locally. MySQL 9 has removed `mysql_native_password`; that auth path stays untested until a 5.7/8.0/MariaDB URL is added to `DBSTUDIO_TEST_MYSQL_URLS`.
- SSH: `sudo` is not available non-interactively in this environment, so Remote Login status could not be checked; Phase 2 needs it enabled in System Settings.

---

## Phase 1 — DBCore + PostgreSQL driver (2026-09-03)

### Done
- **DBCore value model (§5)**: `DBValue` with all 15 cases, `DBDate`/`DBTime`/`DBTimestamp`, `DBValueKind`, `ColumnMeta`, `RowBatch`, `QueryEvent`, `QueryCompletion`, `RowBatching` limits. `decimal` and timestamps keep exact text; nothing routes through `Double` or `Date`.
- **DBCore errors (§6)**: `DBError`, `ServerError` with SQLSTATE/detail/hint/position, `TunnelStage`.
- **DBCore contracts (§7, §8, §9)**: `SQLDriver`, `SQLConnection` (+ `executeCollecting`, `withTransaction`), `SchemaIntrospector` (+ `rowIdentity` fallback to a unique NOT NULL index), `ServerVersion`, `ConnectionConfig`, `TLSConfig`, `SSHConfig`, `SecretRef`, `ResolvedConnectionConfig`.
- **DBSQL**: `Identifier` quoting and display rules per dialect, `SQLLiteral` (display-only literals + `renderForDisplay`), `SQLScanner`, `StatementSplitter` (strings, quoted identifiers, line/block/nested comments, dollar quoting, MySQL `DELIMITER`), `SQLStatement` (`leadingKeyword`, `isProbablyReadOnly`, `shortLabel`), `DMLGenerator`, `FilterCompiler`, `PagePlanner` (OFFSET vs keyset), `SQLTokenizer`, `SQLFormatter`.
- **DBPostgres**: driver over postgres-nio with all five TLS modes; `PostgresSQLConnection` actor with two execution paths (ADR-0008), server-side cancel (ADR-0007), transactions, ping, close; `PostgresTypeCatalog` read from `pg_type` per connection; `PostgresBinaryDecoder` covering every type in §7.3 plus interval, inet/cidr, macaddr, bit/varbit, money; `PostgresParameterEncoder`; `PostgresIntrospector` over `pg_catalog` with version branching, including synthesized `CREATE TABLE` DDL.
- **dbcli**: streams TSV, `--introspect` dumps schema JSON, `--cancel-after`, `--ping`, verbose logging, server errors printed with SQLSTATE/detail/hint/position.
- **Fixtures**: `all_types` (every mapped type, NULL row, extremes row, 1 MB string, JSON nested 50 deep, all 256 byte values, CJK/emoji/RTL), `dst_samples`, `composite_pk`, `uuid_pk`, `no_pk`, `unique_not_null`, `customers`/`orders` with FK actions and indexes, view, materialized view, function, procedure, enum type, and `big_table` with 1,000,000 rows.

### Tests (147 total, 1 skipped)
- `DBCoreTests` (23): kind/case correspondence for every `DBValueKind`, decimal text preservation, special doubles, coding round-trip, date/time/offset rendering, `ServerVersion` parsing and comparison, config coding carries no secret, `ResolvedConnectionConfig.description` omits the password, error descriptions.
- `DBSQLTests` (66): splitter against strings, comments, nested comments, dollar quoting, `DELIMITER`, a 2,000-statement dump, unterminated input, UTF-16 ranges, statement-at-cursor; quoting and display rules; literals and `renderForDisplay`; DML generation for simple, composite and UUID keys including the "two rows, three cells → two UPDATEs" criterion; filter compilation with LIKE escaping; paging strategy selection; formatter idempotence; tokenizer ranges.
- `DBPostgresTests` unit (31): binary decoding of every mapped type from hand-built payloads, `numeric` digit reassembly, epoch and BC date arithmetic, timestamptz in a session zone, arrays with NULLs, domains, enums, unknown types; parameter text and array-literal quoting; OID→kind mapping for every built-in type.
- `DBPostgresTests` integration (25, 1 skipped): connect and version, TCP-stage failure to a dead port, TLS `require` and `disable`, every mapped type round-tripping, NULLs, extremes and Unicode, 1 MB string, JSON depth 50, DST boundary instants, event ordering and batch sizes, real `affectedRows` for INSERT/UPDATE/DELETE/RETURNING, server-side parameter binding against an injection attempt, verbatim server errors with position, syntax-error position pointing at the token, connection reuse after an error, server-side cancel returning in well under a second with the connection still usable, consumer-task cancellation reaching the server, transactions, introspection of tables/views/matviews/columns/indexes/foreign keys/routines/DDL/row estimates, and a full 1,000,000-row stream.

### Verified against
PostgreSQL 16.15 (Homebrew, localhost:5432), reported in the CI coverage summary.

### Gaps that did not run, and why
- **`RAISE NOTICE` output** is never populated: postgres-nio does not expose `NoticeResponse` (ADR-0009). `QueryCompletion.notices` is always empty for PostgreSQL.
- **Columns of an empty result set** are not reported for query tabs, for the same reason (ADR-0009). Table tabs are unaffected.
- **Authentication-failure path is untested on this machine**: the local `pg_hba.conf` authorises loopback with `trust`, so a wrong password still connects. The test skips with that reason rather than passing. Add a password-enforcing server to `DBSTUDIO_TEST_PG_URLS` to cover it.
- **Encrypted connections are untested**: the local PostgreSQL is built without TLS, so `sslmode=require` fails with `tlsRequiredButUnavailable` — the correct behaviour, but the encrypted path itself never ran. `verify-ca` and `verify-full` are therefore also uncovered.
- **Only PostgreSQL 16 was exercised.** `DBSTUDIO_TEST_PG_URLS` is empty, so version branching for 11 and 12 (`prokind`, `attgenerated`) ran only on its modern branch.
- **Client-certificate TLS** is wired but unexercised; SPEC §16 places it in Phase 3.

---

## Phase 2 — ConnectionSession, tunnel, store (2026-09-03)

### Done
- **`ConnectionSession` (§9)**: actor owning the tunnel, a pool of at most 8 physical connections with a 5-minute idle reap, a state stream (`disconnected` / `connecting(stage:)` / `connected` / `degraded`), leases per tab, rollback of any transaction a returned connection still holds, liveness check before reuse, the session-only read-only unlock, the introspection cache with per-table invalidation, and `testConnection` reporting stage by stage. Secrets, tunnels and drivers arrive through `SecretStore`, `TunnelProvider` and `DriverRegistry` so DBCore keeps its two imports (ADR-0012).
- **`DBTunnel`**: `SSHTunnelProvider` over Citadel with password and private-key authentication (ed25519 and RSA, passphrase supported), one level of jump host, and the three known-hosts policies backed by a real `~/.ssh/known_hosts` parser that understands plain, bracketed-port, multi-host and HMAC-SHA1-hashed entries and appends newly accepted keys. `SSHPortForward` binds an ephemeral loopback port and glues each accepted socket to a `direct-tcpip` channel on the same event loop (ADR-0015).
- **`DBStore` (§15)**: SQLite over the C API in WAL mode with a busy timeout, numbered migrations tracked in `PRAGMA user_version`, and typed access to connections, groups, query history (capped at 10,000 and trimmed on write), grid preferences and settings. `KeychainSecretStore` stores passwords, SSH passwords and passphrases under `com.dbstudio.connection`, and deletes all three when a connection is removed.
- **`dbcli`**: `--ssh user@host[:port]`, `--ssh-key`, `--ssh-password`.

### Tests (85 added; 232 total, 1 skipped)
- `ConnectionSessionTests` (19): state transitions and the state stream, degraded state after a failed connect, one connection per lease, reuse after release, the pool stopping at eight and waiting rather than failing, rollback on release, replacement of a dead pooled connection, the dropped-with-open-transaction message, password resolution, the tunnel redirecting the driver to loopback while the certificate keeps naming the real host, one tunnel shared by every connection, the missing-provider error, the session-only read-only unlock, cache hits and invalidation by key and by table, and `testConnection` reporting stages in order.
- `DBStoreTests` (16) and `SQLiteDatabaseTests` (4): migrations applied once and recorded, every table from §15 present, WAL on, connections round-tripping across a reopen with SSH and jump-host config intact, edit-in-place keeping sidebar order, reordering, cascading delete of preferences and history, groups, history recording/search/cap/clear, grid preferences per table per connection, settings with defaults and forward-compatible decoding, value round-trips for every SQLite column type, bound parameters against an injection attempt, transaction rollback, and errors carrying the statement.
- **`testNoSecretReachesTheStoreFile`**: writes a connection, a history row and a setting, then greps every file the store touched — database, WAL and shared memory — for the secret. Required by SPEC §11.3.
- `KeychainSecretStoreTests` (5): round-trip, update-in-place, Unicode and 4 KB secrets, deletion of every field of one connection, scoping between connections, and deleting something absent. Skips with the OS status if the Keychain is unavailable.
- `KnownHostsTests` (11) and `SSHAuthenticationTests` (6): plain, marker, multi-host, bracketed-port and hashed entries, append round-trip, missing and malformed files, the three policies, and key loading for real `ssh-keygen` output (ed25519, ed25519 with a passphrase, RSA) plus clear errors for a wrong passphrase, a missing file, garbage, and agent authentication.
- `TunnelIntegrationTests` (8): against an SSH server hosted in the test process (ADR-0014) — byte forwarding, three connections through one tunnel, a 400 KB payload crossing several SSH windows, public-key authentication, wrong-password failing at `.sshAuth`, a closed port failing at `.ssh`, **PostgreSQL reached through the forward**, and a full `ConnectionSession` over the tunnel using the real driver.

### Gaps that did not run, and why
- **No test ran against OpenSSH's `sshd`.** Remote Login is off on this machine and enabling it needs administrator rights the test environment may not take. The in-process server covers the client's protocol path but not interoperability with `sshd`'s algorithm preferences. `dbcli --ssh user@localhost` against the local PostgreSQL — the literal Phase 2 acceptance criterion — therefore could not be run; the equivalent is covered by `testPostgresThroughTheTunnel`.
- **Jump hosts are untested.** `SSHClient.jump(to:)` is wired but no second server was stood up, and `DBSTUDIO_TEST_SSH_JUMP_URL` is unset.
- **SSH agent authentication is not implemented** (ADR-0013); `.agent` throws with a message naming the alternative.
- **ECDSA private-key files are unsupported**, because Citadel provides OpenSSH readers for ed25519 and RSA only.
- **`known_hosts` is never consulted in an integration test**: the tunnel tests use the `ignore` policy, since the in-process server generates a fresh host key each run. Parsing and policy selection are unit-tested against real key material.

---

## Phases 3–5 — Data grid, app shell, SQL editor (2026-09-03)

Built together, because the grid, the shell and the editor share the tab and session
plumbing and none of the three is testable in isolation.

### Done — Phase 3, the data grid (§12)
- **`DBGrid` package** (ADR-0017): `RowBuffer` (1,000-row pages, 200,000-row cap, eviction that keeps the viewport's neighbourhood), `EditBuffer` (cell edits, deletions, pending inserts, statement generation), `GridModel` (columns, paging, sort, filter, edit overlay, streamed results, memory cap), `GridCommitter` (one transaction, affected-row check, rollback), `ClipboardFormatter` (TSV, CSV, JSON, NDJSON, Markdown, INSERT, WHERE-IN) and `RowExporter` (streaming CSV/JSON/NDJSON/SQL).
- **AppKit grid**: `NSTableView` with fixed 22-point rows and automatic heights off, custom cell views drawing NULL italic-grey, binary as `<N bytes>`, long text truncated at 512 characters, yellow edited cells, green new rows, red struck-through deletions; spreadsheet-style cell, row, column and rectangular selection; keyboard navigation including page and document keys; inline editing with type coercion; column widths persisted per table per connection; lazy loading driven by the visible rectangle with a 200-row margin.
- **Paging**: `LIMIT`/`OFFSET` by default, switching to a keyset cursor past page 50 when a single integer key allows it *and* the previous page is loaded, since a cursor cannot jump into unloaded territory.
- **Editing**: enabled only with a primary key or a unique NOT NULL index; commit shows every statement in a preview sheet, runs them in one transaction, and rolls back when any statement does not affect exactly one row. Production connections hold the Execute button for 1.5 seconds and label it with the connection name.
- Cell inspector with hex dump, "Save as File…", pretty-printed JSON and an editable raw value.

### Done — Phase 4, the app shell (§10, §11)
- `NavigationSplitView` workspace: sidebar, custom tab bar with connection colour stripes and drag reordering, tab content, status bar showing connection, database, state, read-only and transaction status.
- Sidebar tree — groups → connections → databases → schemas → typed object folders → tables and routines — read one level at a time through the session cache, with status dots following the session's state stream, production badges, and context menus for open, copy name, copy qualified name, copy DDL, truncate and drop. Destructive actions on a production connection require the table name to be typed.
- Connection editor sheet with General, TLS, SSH (password, key file with a file chooser, agent, jump host, host-key policy) and Advanced sections, validation, a world-readable-key warning, and Test Connection reporting stage by stage.
- Quick-open (⌘⇧O) fuzzy-matching table names, query history panel (⌘Y), export sheet, settings window.
- Every shortcut in SPEC §10.2 registered through SwiftUI `Commands`, so each appears in a menu.

### Done — Phase 5, the SQL editor (§13, §14)
- `NSTextView` with a line-number gutter, current-line highlight, syntax highlighting from `DBSQL.SQLTokenizer` (ADR-0018), bracket matching, auto-indent, `⌘/` comment toggling, `⌘D` duplicate line, and a red underline on the token a server error names.
- Run the statement under the cursor, the selection, or every statement; one result tab per statement; per-statement messages; auto-commit toggle with explicit Commit and Rollback; elapsed-time indicator; server-side cancel.
- Alias-aware autocomplete: keywords, schema and table names, and the columns of tables the statement mentions, with `FROM users u` making `u.` offer users' columns.
- Query history recorded for every statement, capped at 10,000.
- Export to CSV, JSON, JSON Lines and SQL INSERT, over the selection, the loaded rows, or the whole table streamed from the server.

### Tests (86 added; 318 total, 1 skipped)
- `RowBufferTests` (7): absolute indexing, missing-page computation, streamed appends across batch boundaries, in-place replacement, and eviction that respects the cap while keeping the viewport.
- `EditBufferTests` (8): overlay reads, an edit that returns to its loaded value clearing itself, deletion superseding edits, inserts, discard, and the statement order updates → deletes → inserts.
- `GridCommitterTests` (6): the happy path in one transaction, rollback when an `UPDATE` affects zero rows or two, a server error keeping the server's words, `INSERT … RETURNING` counting as one row, and an empty commit opening no transaction.
- `GridModelTests` (17): page loading, exhaustion, no duplicate fetches, keyset selection only when a preceding page is loaded, offset fallback on a jump, sort and filter reloading from page 0, sort cycling, editability rules, original-identity WHERE clauses, commit clearing the buffer, a failed commit keeping it, streamed results and load failures.
- **`GridIntegrationTests` (10) against real PostgreSQL**: the first page of the million-row fixture in **79 ms** (criterion: under 500 ms), deep paging staying correct on a keyset cursor, memory bounded while scrolling 120 pages, server-side sort and filter, a filter value that would drop the table proving parameters are bound, three cells across two rows committing as two `UPDATE`s, **concurrent modification failing the commit and writing nothing**, insert and delete in one commit, composite/UUID/no-key behaviour, and an exact count of 1,000,000.
- **App smoke test** (`DBStudio --smoke-test`, run by `Scripts/ci.sh`): store opens, session connects, a query returns its rows and columns, `SELECT pg_sleep(30)` cancels in **0.59 s**, and a table tab introspects and pages a real table.

### Gaps that did not run, and why
- **The view layer itself is untested.** macOS denies synthetic keyboard and mouse input to this build session, so neither XCUITest nor scripted input can drive menus, focus, drawing or the grid's mouse handling (ADR-0019). The app was launched and photographed: it loads its store, lists its connection, opens a query tab with ⌘T, and reports "Connected". Everything below the views is covered by the smoke test and the integration suites. **The full shortcut table in SPEC §10.2 has not been verified by hand.**
- **Scroll performance is measured by wall-clock page latency, not by `XCTMetric` or os_signpost.** The 500 ms first-page criterion is checked; the "main thread never blocks more than 16 ms" criterion is not, because it needs a signpost-instrumented UI test the environment cannot run.
- **`GridPlayground`**, the synthetic-data target SPEC §16 lists for performance iteration, was not built. Its purpose — iterating on grid performance without a database — is served by `GridIntegrationTests` against the real million-row table.
- **Editing a single-table query result** (SPEC §12.3, "Phase 2") is not implemented; query results are read-only. Recorded as a deliberate deferral.
- **Client-certificate TLS** is wired through `TLSConfig` and the driver but has no fixture to test against.
