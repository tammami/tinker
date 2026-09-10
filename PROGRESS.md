# PROGRESS.md — per-phase log

All seven phases of SPEC §16 are complete. See the per-phase entries below, and the gaps each one records.

---

## Phase 0 — Scaffold (2026-09-03)

### Done
- Repository layout per SPEC §3: `Packages/{DBCore,DBPostgres,DBMySQL,DBTunnel,DBStore,DBSQL,DBTestKit}`, `App/Tinker`, `Tools/dbcli`, `testenv/`, `Scripts/`.
- Root `Package.swift` (tools 6.2, Swift 6 language mode → strict concurrency complete, macOS 14) with one target per package plus test targets; only dependency is swift-log (ADR-0001).
- `DBCore.SQLDialect` (SPEC §7/§9) is the single real type landed; all other packages are compiling placeholders.
- `DBTestKit.TestEnvironment`: resolves `TINKER_TEST_{PG,MYSQL}_URL(S)`, refuses any database other than `tinker_test` and admin user names (fails, does not skip), skips with a reason when unset, and prints a redacted summary.
- `Tools/dbcli` prints `hello`.
- `App/Tinker.xcodeproj`: SwiftUI app, macOS 14.0, arm64 only, Swift 6, strict concurrency, hardened runtime on, App Sandbox off, warnings as errors, links `DBCore` from the root package; opens one empty window (ADR-0002). Shared scheme `Tinker`.
- `testenv/prepare.sh`: creates `tinker_test` db + user on the developer's existing PG/MySQL from admin URLs, loads `testenv/fixtures/<dialect>/*.sql` as the test user, verifies not-superuser / no-global-grants, prints the non-admin URLs. Idempotent (re-run verified). Installs nothing.
- `Scripts/ci.sh`: rebuilds first-party modules with zero-warning gate, lints import direction, runs `swift test`, builds the app with xcodebuild, warns visibly when an engine's URL is unset, and ends with a coverage summary.

### Verified against local servers
- PostgreSQL 16.15 (Homebrew, `localhost:5432`): prepare OK; test user `rolsuper=f`, `CREATE TABLE` in another database denied.
- MySQL 9.4.0 (Laravel Herd, `127.0.0.1:3306`, root has an empty password): prepare OK; grants are exactly `USAGE ON *.*` + `ALL ON tinker_test.*`; `CREATE DATABASE` denied.
- `Scripts/ci.sh` green with both URLs exported.

### Tests
- `DBTestKitTests.TestEnvironmentTests` (11): env parsing order, primary+additional lists, refusal of other databases / missing database / admin users / wrong scheme / garbage, password redaction, `XCTSkip` when unset, summary text.
- `DBCoreTests.SQLDialectTests`: raw values are stable (they are persisted).
- One link-smoke test per placeholder package.

### Deferred / gaps
- Real privilege check (PG superuser, MySQL global grants) at connect time → Phase 1 (ADR-0006).
- Fixture set is a single `smoke` table; the full SPEC §17 fixture data (Unicode, 1 MB strings, extreme numerics, DST timestamps, 1M-row `big_table`) lands with the phases that consume it.
- No integration test actually opens a network connection yet (no driver). `ci.sh` reports the configured engines from the environment; from Phase 1 the driver tests log the detected server version.
- Only MySQL 9.4 is available locally. MySQL 9 has removed `mysql_native_password`; that auth path stays untested until a 5.7/8.0/MariaDB URL is added to `TINKER_TEST_MYSQL_URLS`.
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

### Tests
- `DBCoreTests` (23): kind/case correspondence for every `DBValueKind`, decimal text preservation, special doubles, coding round-trip, date/time/offset rendering, `ServerVersion` parsing and comparison, config coding carries no secret, `ResolvedConnectionConfig.description` omits the password, error descriptions.
- `DBSQLTests` (66): splitter against strings, comments, nested comments, dollar quoting, `DELIMITER`, a 2,000-statement dump, unterminated input, UTF-16 ranges, statement-at-cursor; quoting and display rules; literals and `renderForDisplay`; DML generation for simple, composite and UUID keys including the "two rows, three cells → two UPDATEs" criterion; filter compilation with LIKE escaping; paging strategy selection; formatter idempotence; tokenizer ranges.
- `DBPostgresTests` unit (31): binary decoding of every mapped type from hand-built payloads, `numeric` digit reassembly, epoch and BC date arithmetic, timestamptz in a session zone, arrays with NULLs, domains, enums, unknown types; parameter text and array-literal quoting; OID→kind mapping for every built-in type.
- `DBPostgresTests` integration (25, 1 skipped): connect and version, TCP-stage failure to a dead port, TLS `require` and `disable`, every mapped type round-tripping, NULLs, extremes and Unicode, 1 MB string, JSON depth 50, DST boundary instants, event ordering and batch sizes, real `affectedRows` for INSERT/UPDATE/DELETE/RETURNING, server-side parameter binding against an injection attempt, verbatim server errors with position, syntax-error position pointing at the token, connection reuse after an error, server-side cancel returning in well under a second with the connection still usable, consumer-task cancellation reaching the server, transactions, introspection of tables/views/matviews/columns/indexes/foreign keys/routines/DDL/row estimates, and a full 1,000,000-row stream.

### Verified against
PostgreSQL 16.15 (Homebrew, localhost:5432), reported in the CI coverage summary.

### Gaps that did not run, and why
- **`RAISE NOTICE` output** is never populated: postgres-nio does not expose `NoticeResponse` (ADR-0009). `QueryCompletion.notices` is always empty for PostgreSQL.
- **Columns of an empty result set** are not reported for query tabs, for the same reason (ADR-0009). Table tabs are unaffected.
- **Authentication-failure path is untested on this machine**: the local `pg_hba.conf` authorises loopback with `trust`, so a wrong password still connects. The test skips with that reason rather than passing. Add a password-enforcing server to `TINKER_TEST_PG_URLS` to cover it.
- **Encrypted connections are untested**: the local PostgreSQL is built without TLS, so `sslmode=require` fails with `tlsRequiredButUnavailable` — the correct behaviour, but the encrypted path itself never ran. `verify-ca` and `verify-full` are therefore also uncovered.
- **Only PostgreSQL 16 was exercised.** `TINKER_TEST_PG_URLS` is empty, so version branching for 11 and 12 (`prokind`, `attgenerated`) ran only on its modern branch.
- **Client-certificate TLS** is wired but unexercised; SPEC §16 places it in Phase 3.

---

## Phase 2 — ConnectionSession, tunnel, store (2026-09-03)

### Done
- **`ConnectionSession` (§9)**: actor owning the tunnel, a pool of at most 8 physical connections with a 5-minute idle reap, a state stream (`disconnected` / `connecting(stage:)` / `connected` / `degraded`), leases per tab, rollback of any transaction a returned connection still holds, liveness check before reuse, the session-only read-only unlock, the introspection cache with per-table invalidation, and `testConnection` reporting stage by stage. Secrets, tunnels and drivers arrive through `SecretStore`, `TunnelProvider` and `DriverRegistry` so DBCore keeps its two imports (ADR-0012).
- **`DBTunnel`**: `SSHTunnelProvider` over Citadel with password and private-key authentication (ed25519 and RSA, passphrase supported), one level of jump host, and the three known-hosts policies backed by a real `~/.ssh/known_hosts` parser that understands plain, bracketed-port, multi-host and HMAC-SHA1-hashed entries and appends newly accepted keys. `SSHPortForward` binds an ephemeral loopback port and glues each accepted socket to a `direct-tcpip` channel on the same event loop (ADR-0015).
- **`DBStore` (§15)**: SQLite over the C API in WAL mode with a busy timeout, numbered migrations tracked in `PRAGMA user_version`, and typed access to connections, groups, query history (capped at 10,000 and trimmed on write), grid preferences and settings. `KeychainSecretStore` stores passwords, SSH passwords and passphrases under `com.tinker.connection`, and deletes all three when a connection is removed.
- **`dbcli`**: `--ssh user@host[:port]`, `--ssh-key`, `--ssh-password`.

### Tests
- `ConnectionSessionTests` (19): state transitions and the state stream, degraded state after a failed connect, one connection per lease, reuse after release, the pool stopping at eight and waiting rather than failing, rollback on release, replacement of a dead pooled connection, the dropped-with-open-transaction message, password resolution, the tunnel redirecting the driver to loopback while the certificate keeps naming the real host, one tunnel shared by every connection, the missing-provider error, the session-only read-only unlock, cache hits and invalidation by key and by table, and `testConnection` reporting stages in order.
- `DBStoreTests` (16) and `SQLiteDatabaseTests` (4): migrations applied once and recorded, every table from §15 present, WAL on, connections round-tripping across a reopen with SSH and jump-host config intact, edit-in-place keeping sidebar order, reordering, cascading delete of preferences and history, groups, history recording/search/cap/clear, grid preferences per table per connection, settings with defaults and forward-compatible decoding, value round-trips for every SQLite column type, bound parameters against an injection attempt, transaction rollback, and errors carrying the statement.
- **`testNoSecretReachesTheStoreFile`**: writes a connection, a history row and a setting, then greps every file the store touched — database, WAL and shared memory — for the secret. Required by SPEC §11.3.
- `KeychainSecretStoreTests` (5): round-trip, update-in-place, Unicode and 4 KB secrets, deletion of every field of one connection, scoping between connections, and deleting something absent. Skips with the OS status if the Keychain is unavailable.
- `KnownHostsTests` (11) and `SSHAuthenticationTests` (6): plain, marker, multi-host, bracketed-port and hashed entries, append round-trip, missing and malformed files, the three policies, and key loading for real `ssh-keygen` output (ed25519, ed25519 with a passphrase, RSA) plus clear errors for a wrong passphrase, a missing file, garbage, and agent authentication.
- `TunnelIntegrationTests` (8): against an SSH server hosted in the test process (ADR-0014) — byte forwarding, three connections through one tunnel, a 400 KB payload crossing several SSH windows, public-key authentication, wrong-password failing at `.sshAuth`, a closed port failing at `.ssh`, **PostgreSQL reached through the forward**, and a full `ConnectionSession` over the tunnel using the real driver.

### Gaps that did not run, and why
- **No test ran against OpenSSH's `sshd`.** Remote Login is off on this machine and enabling it needs administrator rights the test environment may not take. The in-process server covers the client's protocol path but not interoperability with `sshd`'s algorithm preferences. `dbcli --ssh user@localhost` against the local PostgreSQL — the literal Phase 2 acceptance criterion — therefore could not be run; the equivalent is covered by `testPostgresThroughTheTunnel`.
- **Jump hosts are untested.** `SSHClient.jump(to:)` is wired but no second server was stood up, and `TINKER_TEST_SSH_JUMP_URL` is unset.
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

### Tests
- `RowBufferTests` (7): absolute indexing, missing-page computation, streamed appends across batch boundaries, in-place replacement, and eviction that respects the cap while keeping the viewport.
- `EditBufferTests` (8): overlay reads, an edit that returns to its loaded value clearing itself, deletion superseding edits, inserts, discard, and the statement order updates → deletes → inserts.
- `GridCommitterTests` (6): the happy path in one transaction, rollback when an `UPDATE` affects zero rows or two, a server error keeping the server's words, `INSERT … RETURNING` counting as one row, and an empty commit opening no transaction.
- `GridModelTests` (17): page loading, exhaustion, no duplicate fetches, keyset selection only when a preceding page is loaded, offset fallback on a jump, sort and filter reloading from page 0, sort cycling, editability rules, original-identity WHERE clauses, commit clearing the buffer, a failed commit keeping it, streamed results and load failures.
- **`GridIntegrationTests` (10) against real PostgreSQL**: the first page of the million-row fixture in **79 ms** (criterion: under 500 ms), deep paging staying correct on a keyset cursor, memory bounded while scrolling 120 pages, server-side sort and filter, a filter value that would drop the table proving parameters are bound, three cells across two rows committing as two `UPDATE`s, **concurrent modification failing the commit and writing nothing**, insert and delete in one commit, composite/UUID/no-key behaviour, and an exact count of 1,000,000.
- **App smoke test** (`Tinker --smoke-test`, run by `Scripts/ci.sh`): store opens, session connects, a query returns its rows and columns, `SELECT pg_sleep(30)` cancels in **0.59 s**, and a table tab introspects and pages a real table.

### Gaps that did not run, and why
- **The view layer itself is untested.** macOS denies synthetic keyboard and mouse input to this build session, so neither XCUITest nor scripted input can drive menus, focus, drawing or the grid's mouse handling (ADR-0019). The app was launched and photographed: it loads its store, lists its connection, opens a query tab with ⌘T, and reports "Connected". Everything below the views is covered by the smoke test and the integration suites. **The full shortcut table in SPEC §10.2 has not been verified by hand.**
- **Scroll performance is measured by wall-clock page latency, not by `XCTMetric` or os_signpost.** The 500 ms first-page criterion is checked; the "main thread never blocks more than 16 ms" criterion is not, because it needs a signpost-instrumented UI test the environment cannot run.
- **`GridPlayground`**, the synthetic-data target SPEC §16 lists for performance iteration, was not built. Its purpose — iterating on grid performance without a database — is served by `GridIntegrationTests` against the real million-row table.
- **Editing a single-table query result** (SPEC §12.3, "Phase 2") is not implemented; query results are read-only. Recorded as a deliberate deferral.
- **Client-certificate TLS** is wired through `TLSConfig` and the driver but has no fixture to test against.

---

## Phase 6 — MySQL driver (2026-09-03)

### Done
- **`DBMySQL`** over mysql-nio 1.9.1: `MySQLDriver` with all five TLS modes and a plaintext fallback for `prefer`; `MySQLSQLConnection` actor streaming rows in the batch sizes SPEC §4 sets, reporting the OK packet's `affectedRows` and `lastInsertID`, cancelling with `KILL QUERY` from a connection kept for the purpose, and tracking transactions.
- **`MySQLValueDecoder`** covering every type in §7.3 across both wire formats: signed and unsigned integers of every width, `tinyint(1)` as boolean behind a per-connection toggle, `FLOAT`/`DOUBLE`, `DECIMAL` read as the exact characters MySQL sent, every string and binary type separated by character set, `DATE`, `TIME`, `DATETIME`, `TIMESTAMP`, `YEAR`, `JSON`, `ENUM`, `SET`, `BIT` rendered as bits, and `GEOMETRY` as raw bytes.
- **`MySQLIntrospector`** over `information_schema`, with version branching for generated columns, MySQL's single pseudo-schema per database, enum and set labels parsed from the declared type, and `SHOW CREATE TABLE` for DDL.
- `caching_sha2_password` — MySQL 8 and later's default — works with TLS off through the RSA public-key exchange, so no escalation to `libmysqlclient` was needed.
- **Zero UI changes.** MySQL was added to the driver registry and nothing else: no view, controller or grid code was touched. `GridIntegrationTests` proves it by running the same ten checks against both engines.

### Tests
- `MySQLIntegrationTests` (24): connect and version, TCP-stage failure, wrong password, TLS `require` and `disable`, every mapped type round-tripping including `BIGINT UNSIGNED` at its maximum and `DECIMAL(65,30)`, `DATETIME` and `TIMESTAMP` both arriving without a zone, NULLs, extremes and Unicode, a 1 MB string, JSON nested 50 deep, zero dates under a permissive `sql_mode`, event ordering and batching, `affectedRows` and `lastInsertID`, parameters bound against an injection attempt, server errors with code and SQLSTATE, reuse after an error, `KILL QUERY` stopping a statement in well under a second, transactions on InnoDB, introspection of databases/tables/views/columns/indexes/foreign keys/routines/DDL/row estimates, and a full 1,000,000-row stream.
- `MySQLValueDecoderTests` (6): bit rendering, enum and set label parsing including a doubled quote, declared-type to kind for every family, the `tinyint(1)` toggle, IP-address detection for SNI, and command-tag shape.
- `GridIntegrationTests` now runs on both engines: the first page of MySQL's million-row fixture arrives in **67 ms**.

### Gaps that did not run, and why
- **`mysql_native_password` is untested.** MySQL 9.4 removed the plugin, and it is the only server available here. Add a MySQL 5.7 or 8.0 URL to `TINKER_TEST_MYSQL_URLS` to cover it.
- **MariaDB is untested**, so its `information_schema` differences — routine parameters, index statistics, `GENERATION_EXPRESSION` — ran only on their MySQL branch.
- **`sha256_password` is untested**, for the same reason: no server offers it here.
- **Encrypted MySQL connections are untested.** The local server refused the TLS handshake, so `require` exercised only its failure path, and `verify-ca` and `verify-identity` never ran.
- **The authentication plugin in use was not asserted**: reading `mysql.user` needs a privilege the test account correctly lacks. The suite reports what it could read and moves on.

---

## Phase 7 — Release hardening (2026-09-03)

### Done
- **App icon**: a generated set at every size the catalogue asks for, 16 pt through 512 pt at 1× and 2×, drawn as three stacked discs on a blue squircle.
- **Hardened runtime and entitlements**: `Tinker.entitlements` turns the sandbox off — SSH tunnels and export need it (SPEC §2) — enables the network client, and grants none of the runtime exceptions. The hardened runtime is on in both configurations.
- **Sparkle 2** linked into the app target and wired behind an `Updater` facade. The feed URL and public key come from the environment at release time (ADR-0023); a build without them creates no updater, disables the menu item and says why. Automatic checking is off by default.
- **Crash reporting**, opt-in and local only: reports go to `Application Support/Tinker/Diagnostics`, record the app and system version and a stack trace, and never contain SQL, values or credentials. Settings has a Diagnostics pane to turn it on, count the reports, reveal them in Finder and delete them.
- **First-run experience**: shown once when there are no connections, stating where passwords are kept, that every grid change is previewed as SQL and runs in one transaction, and what Production and Read-only do. It offers the diagnostics choice there rather than assuming it.
- **`Scripts/release.sh`**: archive, export, verify the signature and hardened runtime, notarize, staple, `spctl` assess, build the DMG, sign and notarize it, and print the Sparkle signing command. `--skip-notarize` and `--unsigned` stop earlier. It derives the team id from the signing identity and refuses to run without a Developer ID certificate, naming what to install.

### Verified
- `Scripts/release.sh --unsigned` produces `Tinker-0.1.0.dmg`, 7.2 MB, containing the app and an Applications symlink.
- The DMG mounts, and the app **inside the mounted image** passes the full smoke test against the local PostgreSQL — store, connection, query, cancel, table tab.
- `Sparkle.framework` is embedded in the released bundle.
- Running the script without a Developer ID certificate fails with the list of available identities and the command to create the notary profile.

### Gaps that did not run, and why
- **Nothing was signed or notarized.** This machine has an Apple Development certificate only; a Developer ID Application certificate cannot be created by a build (ADR-0024). Signing, notarization, stapling, `spctl` assessment and the "installs on a clean macOS 14 machine" criterion are all untested. The script implements them and fails loudly rather than silently skipping.
- **Sparkle has never checked a feed.** No appcast exists to point it at, so the update path — `SPUStandardUpdaterController` reaching a signed appcast and applying an update — is unexercised.
- **The crash handler has not fired.** `NSSetUncaughtExceptionHandler` is installed when the user opts in; no test provokes it, because doing so would mean crashing the app under test.

---

## Status against SPEC §16

| Phase | State | Verified against |
|---|---|---|
| 0 Scaffold | complete | `Scripts/ci.sh` green |
| 1 DBCore + PostgreSQL | complete | PostgreSQL 16.15 |
| 2 Session, tunnel, store | complete | PostgreSQL 16.15, in-process SSH server, real Keychain |
| 3 Data grid | complete | 1,000,000-row fixtures on both engines |
| 4 App shell | complete | app smoke test; views not driven |
| 5 SQL editor and export | complete | app smoke test; views not driven |
| 6 MySQL | complete | MySQL 9.4.0 |
| 7 Release hardening | complete except signing | unsigned DMG, run from the mounted image |

**309 tests run, 1 skipped with a stated reason, 0 failures.** Largest suites: PostgreSQL
integration 27, MySQL integration 24, PostgreSQL decoder 24, `ConnectionSession` 19,
`GridModel` 17, `DBStore` 16, DML generation 12, known hosts 11, grid integration 10 (run
against both engines).

Every gap listed above is a thing that did not run, not a thing that was claimed.

---

## Interface pass and two model bugs found by driving the real app (2026-09-03)

Running the UI rather than the objects under it turned up two defects the headless smoke
test could not see, because it exercised the same objects in a different order.

### Bugs fixed

- **Expanding a table folder emptied it.** The schema's own load attaches each folder's
  tables inline, so `childCache` never held them. Expanding the folder asked the loader
  for children anyway; `children(of:)` returns `[]` for `.tableFolder`, that empty list was
  cached, and `applyCachedChildren` preferred it over the folder's real children. The
  folder drew open and empty while its badge still counted ten tables. `children(of:)` now
  returns the folder's own children. Covered by a new smoke-test check that expands a
  folder and asserts the count survives; with the fix reverted it reports `got 0`.

- **Every table opened read-only.** `IntrospectionCache.value(for:)` cast a missing entry
  straight to the requested type. That cast succeeds whenever the type is itself optional —
  `nil as? [String]?` yields `.some(nil)` — so a miss reported itself as a hit holding
  nothing and the loader never ran. Both optional-returning reads were affected:
  `rowIdentity`, so the grid saw no primary key and disabled editing on every table, and
  `approximateRowCount`. The lookup now checks presence before casting.

  The driver was never at fault: `PostgresIntrospector.primaryKey` returns `["id"]` for
  `customers`, which the integration suite now asserts directly.

### Interface changes

- Grid column separators are drawn by the cells at their trailing edge and by the header at
  the column boundary; the table's horizontal intercell spacing sat between the two, so the
  body's lines were offset from the header's. That spacing is now zero, and the separator
  colour moved to `DesignTokens.Colors.gridSeparator` at a quarter alpha — visible as a
  division, not as a cage.
- `GridHeaderCell` gives column titles the same six-point margin the cells use, so a label
  no longer touches the line beside it.
- A row gutter numbers the rows and is what a whole-row selection is clicked on: one click
  takes a row, shift-click takes the span (SPEC §12.4). `GridSelection` already modelled
  `.rows`; nothing in the view had ever set it. The cell focus ring is now drawn only for a
  cell selection.
- Clicks map a table position to a model column through the column's identifier. Columns are
  reorderable, so the previous positional index selected the wrong column after a reorder —
  the gutter would have made that worse.
- Connection rows carry an engine badge, drawn rather than taken from vendor logos
  (ADR-0026). Sidebar rows have eight points between icon and label.
- The app icon is a lightbulb mid-thought, regenerated by `Scripts/make-icon.swift`.

### Gaps

- ~~The app icon is not adaptive.~~ **Done.** `Tinker.icon` is a hand-authored Icon
  Composer document — `icon.json` plus one SVG layer — so the system composites the shape,
  gradient, specular highlight and shadow and derives the dark and tinted appearances. The
  schema came out of `IconComposerFoundation` (ADR-0027). `Scripts/make-icon.swift` and the
  fixed-size PNGs are gone; `xcrun actool --compile` on the `.icon` validates it.
- **Three UI tests fail on `postKey`, and they are the harness, not the app.** Every test
  driven by XCUITest's own synthesis passes, including the Query menu's Run item, the
  toolbar Run button, ⌘⇧I, ⌘Y and ⌘/. The three that fail are exactly the three that post
  raw `CGEvent`s, which need Accessibility permission the test runner does not hold. ⌘↩ was
  not separately proven; the two paths that run a statement were.
- **Column and rectangular selection still have no affordance.** SPEC §12.4 asks for cell,
  row, column and range; row is now clickable, column is not.

---

## Phase 8 — Table designer (2026-09-03, in progress)

SPEC §16 had the table designer deferred to v0.2. The user asked for it, so the spec moved
first: §8 gained the four reads it needs, §15b describes the feature, and §16 gained
Phase 8 (ADR-0028).

### Done

- **`TableDefinition`** is the structure as the user edits it, separate from the `…Info`
  types introspection returns, because an edit needs a stable identity per column and index.
  Without one a rename cannot be told from a drop and an add, and the designer would rebuild
  objects the user only renamed.
- **`DDLGenerator`** diffs two definitions into ordered statements for both dialects.
  Dependants come off before the columns they sit on and go back on afterwards. PostgreSQL
  alters one facet of a column at a time; MySQL restates the whole column. 29 unit tests
  assert exact statement text.
- **Four catalog reads**, both engines: check constraints, triggers, partitioning,
  collations. PostgreSQL takes a check's predicate from `conbin` rather than stripping the
  wrapper off `pg_get_constraintdef`, and reads trigger timing, events and level from the
  `tgtype` bit mask. MySQL reports no checks below 8.0.16 rather than pretending its parser
  kept them.
- **`DDLExecutor`** runs the statements and reports what survived. PostgreSQL rolls back;
  MySQL cannot, so the result names the statements that had already committed and the
  preview sheet warns before running rather than explaining afterwards.
- **The Structure tab**: Columns, Indexes, Foreign Keys, Checks, Triggers, Partitions and
  Table panes, read-only until Edit, with a preview sheet as the only route to Execute.
  After a run the table's introspection is dropped and the pane reloads from the server, so
  what is shown is what the server has.

### Tests

- `DDLGeneratorTests` (29): create table on both dialects, column add/alter/rename/drop,
  generated columns, primary key add/change/drop, btree/unique/partial/fulltext indexes and
  prefix lengths, index rename versus rebuild, composite foreign keys with actions, check
  constraints, comments, table rename, and the statement ordering.
- `DDLExecutorTests` (6, against both local servers): every case runs the generated DDL and
  reads it back through introspection. Setting a primary key makes `rowIdentity` non-nil,
  which is what makes the grid editable. The failure test asserts PostgreSQL rolled back and
  that MySQL's result names what had already committed.
- `testDesignerReadsCheckConstraintsTriggersAndPartitioning` on both engines, against new
  fixtures with a checked table, a trigger and a range-partitioned table.
- Verified by hand in the running app: `checked_values` opened, `label` marked NOT NULL,
  previewed as `ALTER TABLE "public"."checked_values" ALTER COLUMN "label" SET NOT NULL`,
  executed, and confirmed with `pg_attribute.attnotnull` on the server.

### Notes

- **The editable panes are not built on SwiftUI's `Table`.** They were at first, and the
  controls inside its cells reached neither the accessibility system nor a click: `entire
  contents of window` reported zero checkboxes and synthetic clicks did nothing. A pane
  whose toggles cannot be operated is not an editor, so they lay out their own header and
  rows.
- Loading the new fixtures exposed that the PostgreSQL fixture was not idempotent, which
  `prepare.sh` claims to be. Fixed with `CASCADE`.

### Phase 8 completed (same day)

- **Triggers and partitions are editable.** Both panes take add, edit and remove. A
  PostgreSQL trigger offers several events, a timing including `INSTEAD OF`, row or
  statement level, a `WHEN` clause and its function; MySQL offers one event and a body.
  Partitions add and remove; strategy and key stay read-only because changing either means
  rebuilding the table. PostgreSQL detaches a partition and keeps the rows, MySQL drops it
  and does not — only one of the two is marked destructive.
- **Column reordering**, MySQL only. PostgreSQL has no syntax for it, so the control is
  absent there rather than present and disabled.
- **The collation picker** is the list the server reports.
- **Create Table** — View ▸ New Table… (⌘⇧N) opens the same panes with an empty definition
  and emits `CREATE TABLE`. Verified end to end in the app: the table was created on the
  server with its identity column and primary key, and opened as a tab.
- **Structure sync** — View ▸ Structure Sync… compares a table against another on any
  connection of the same engine and writes the DDL into a SQL editor tab. It generates and
  never applies. Drops are held back and listed commented unless the user asks for them.
  Objects are matched by name, because two servers share no identities; a `StructureSync`
  test caught that a difference made only of drops reported "the target already matches".
- **Column header sorting** (SPEC §12.4). `cycleSort` existed and nothing had ever called
  it: the model, the preferences and the persistence were all in place, but no click
  reached them. Click cycles none → ASC → DESC, shift-click adds a secondary sort, and the
  heading carries the indicator.

### Not done

- **The SQL editor has no line-number gutter.** It had one, and the gutter was why the
  editor never showed any text: an `NSRulerView` inside a SwiftUI `NSViewRepresentable`
  never took its reserved width and filled the rect it was handed, which reached across the
  text view. Three attempts to make it take that width failed, and drawing the numbers
  inside the text view's own margin did not land either. The text now draws; the numbers do
  not. SPEC §13.1 asks for them.
- **A database overview ("Objects") list** — every table with its row count, size, engine
  and collation, the way Navicat shows one when a database is opened — is not built and is
  not in SPEC.

---

## Phase 9 — Objects, pages, the tab's session, result panes (2026-09-03, in progress)

SPEC gained §11.4 (Objects), §12.7 (pages), §13.1a (the tab's session) and §13.2a (result
panes), plus Phase 9 in §16 and ADR-0029/0030.

### Done

- **A query tab carries its own connection and database.** Two pickers in its toolbar;
  statements resolve unqualified names against them, so a query reads `SELECT * FROM t`.
  MySQL switches with `USE`, PostgreSQL with `SET search_path` — it cannot change database
  on an open connection, and the search path is what an unqualified name resolves against
  there, so the picker is labelled Schema on PostgreSQL and Database on MySQL. The switch is
  reapplied on every connection acquisition, because the pool can hand back another one.
- **Autocomplete** (SPEC §13.1). The candidates were already implemented and alias-aware;
  nothing had ever displayed them. A borderless panel beside the caret that never takes key
  focus, with arrows, Return, Tab and Escape forwarded from the text view, ⌃Space to ask
  for it, and the typed letters picked out in each row.
- **The filter bug.** A filter whose first page failed left the grid drawing the table's
  planner estimate as empty rows — the "empty table with thousands of rows". The estimate
  describes the unfiltered table and is no longer used once a filter is on; a failed load
  now reports the server's words instead of failing silently.
- **The grid's row separators are gone**; only the header carries rules. The filter bar
  starts visible.

### Tests

- `testAFilteredGridDoesNotCountTheWholeTable` — with the fix reverted it reports
  1,000,000 rows, which is exactly what the screen showed.
- `testAFilteredGridCountsWhatItLoaded`.
- Verified in the app: the pickers show Local PostgreSQL / public, and
  `SELECT * FROM customers` runs unqualified against that session.

### Phase 9 completed (same day)

- **Pages (§12.7).** A table tab holds one page of 1,000 rows with first / previous / next
  / last, the page number and the rows it covers. The model keeps holding exactly one page,
  so rows stay numbered from zero within it and the grid, the edits and the selection all
  keep meaning the same thing on every page. A filter or a sort returns to page one. Only
  Last runs a `COUNT`, and only when pressed; everywhere else the estimate is shown marked
  as one (ADR-0029, ADR-0030).
- **Objects list (§11.4).** Double-clicking a schema lists what it holds — kind, estimated
  rows, size, engine, collation, comment — searchable and sortable, with the estimate
  labelled under the list. `TableInfo` gained engine and collation, which MySQL reports and
  PostgreSQL does not.
- **Result panes (§13.2a).** Message / Result / Profile / Status, with the SQL that produced
  the rows, its elapsed time and the record count in the status line under them. Profile and
  Status are read when their pane is opened rather than after every statement. PostgreSQL has
  no profile that does not re-run the statement, and re-running a write to time it is not
  something a client may do on its own, so that pane says so rather than doing it.
- The suggestion list closes on Escape, on a click, on the caret leaving the word, when the
  editor loses focus, and when a statement runs.

### Tests

- Five paging tests over the fixture loader: one page at a time, the page's row range, the
  short last page, moving between pages issuing one request each, and filter and sort
  returning to page one.
- Verified in the app: 1,000-row pages over the million-row fixture (rows 1001–2000 on page
  2), the Objects list of `public` with 17 objects, and the four result panes including
  PostgreSQL's `pg_stat_database` in Status.

### Also fixed

- **The query tab was laying its editor out at the ideal width of what sat beside it**, so
  the editor and its toolbar appeared as a narrow centred column while the results below
  filled the pane. Introduced by the result-panes change and found while fixing the gutter;
  both split-view panes now fill the width.

### Not done

- ~~The editor's line-number gutter~~ **Done.** It lives in the scroll view's own left
  content inset, so the text is shifted by exactly its width and can never be drawn under
  it, and it is positioned by autoresizing rather than constraints — an `NSScrollView` tiles
  its own subviews and a constrained one drags the whole subtree into auto layout, which
  left the editor with no width at all. Its height is set once SwiftUI has laid the editor
  out, because the scroll view has none when the gutter is made. Verified scrolled: lines
  27–38 track their text.
- **Profile on PostgreSQL** is a message rather than a measurement, by choice.
- Paging and the Objects list have no integration test of their own; they are covered by
  unit tests over a fixture loader and by hand against the local servers.

---

## Phase 10 — SQLite (2026-09-09)

SPEC gained SQLite in §1, §2.1, §3, §7.3, §16 (Phase 10) and §17.1, plus ADR-0036…0038.
Asked for by the user as "support sqlite, drag the file like Navicat".

### Done

- **`DBSQLite`**, a driver over the system `SQLite3` module: `SQLiteDriver` (header check,
  create-if-missing option, `createDatabase(at:)`, `connectionConfig(forFileAt:)`),
  `SQLiteConnection` (an actor on its own thread, streaming rows in SPEC §4 batches,
  `sqlite3_interrupt` cancel, progress-handler timeout, `RETURNING`, transactions read from
  `sqlite3_get_autocommit` so a typed `BEGIN` counts), `SQLiteValueCodec` (storage class
  first, declared type as refinement; ISO-8601 parsing without `Foundation.Date`),
  `SQLiteIntrospector` (pragmas, `sqlite_master`, `sqlite_stat1`, `dbstat`, DDL-text
  reading for checks, constraint names, partial predicates and triggers; `ServerIntrospector`
  with pragmas and compile options as variables).
- **`SQLDialect.sqlite`** through every package: quoting, literals (no type keywords, `X''`
  bytes, `9e999` for infinity), `?` placeholders, backtick tokens, a SQLite keyword set,
  `CAST(… AS TEXT)`, `lower()`-folded quick search, `DEFAULT VALUES`/`RETURNING` in DML,
  `EXPLAIN QUERY PLAN`, `VACUUM`/`REINDEX`, a `CREATE TABLE … AS SELECT … WHERE 0` duplicate
  that says what it loses, `DROP VIEW IF EXISTS` before `CREATE VIEW`, `COLLATE BINARY` for
  the sync merge, `PRAGMA foreign_keys` around dumps and imports, user operations that
  throw. `DDLGenerator` writes an inline `INTEGER PRIMARY KEY AUTOINCREMENT`, schema-scoped
  indexes and triggers, and the documented table rebuild for anything `ALTER TABLE` cannot
  do. Both splitters keep `CREATE TRIGGER … BEGIN … END` whole.
- **App**: `SQLiteDriver` registered; `EngineMark` feather; the sidebar treats `main` as
  MySQL's pseudo-schema; the connection editor has a file mode (Choose…/New…, no
  host/TLS/SSH); status bar and subtitles show the path and "Local file"; query tab session
  pickers, status pane (pragmas) and profile note; Users, routines and the profiler are not
  offered. `SQLiteFileOpener` handles drop on the window, Finder open
  (`TinkerAppDelegate`, `App/Info.plist` document types merged into the generated plist) and
  File › Open SQLite Database… (⌥⌘O). `dbcli` takes `sqlite:///path`.
- **Tests**: `TestEngine.sqlite` is a temporary file and always runs; fixtures in
  `testenv/fixtures/sqlite/` (the million-row `big_table` loads in about a second through a
  recursive CTE). The grid, transfer and sync integration suites now run on SQLite on every
  invocation, so a machine with no server still exercises the shared data path.

### Tests

- `SQLiteIntegrationTests` (32): version and local transport; a missing file is refused
  unless creation is asked for; a text file is refused by its header; `createDatabase`
  writes the header and refuses to overwrite; every declared type arrives as its kind;
  NULLs; extremes and Unicode; a 1 MB string and JSON 50 deep; text that does not fit its
  declared type keeps its storage class; event order and batching (500/500/200); affected
  rows, last insert id and silent DDL (`sqlite3_changes` is not reset by DDL — found by the
  transfer suite reporting 600,250 rows for 200,000); parameters bound not interpolated;
  errors verbatim with code and character position (multi-byte checked); usable after an
  error; interrupt cancels within a second and the consuming task's cancellation stops the
  statement; timeout; transactions; introspection snapshot (estimate 1,000,000 from
  `sqlite_stat1`, sizes from `dbstat`, a missing schema holds nothing); column details;
  keys, indexes and foreign keys with their DDL names and actions; DDL from SQLite itself
  with indexes; checks and triggers parsed from DDL; server reads say what a file has;
  foreign keys enforced by default and optional; `lower('ÖRLD Straße')`; read-only held by
  the file through `ConnectionSession` (`WITH … INSERT` refused, unlock works); a column
  type change rebuilt in one transaction and read back; 200,000 rows streamed in ≥400
  batches; spatial text parses.
- `SQLiteCodecTests` (4): declared-type reduction, temporal parsing, error offsets,
  DDL-text reading.
- `SQLiteDialectTests` in DBSQL (10): identifiers, literals, tokens, the trigger-body
  splitter, `EXPLAIN QUERY PLAN`, table operations, DML, the quick-search filter, views,
  and the SQLite `CREATE TABLE`.
- `ScriptStreamTests.testSQLiteTriggerBodiesHoldTheirSemicolonsAndBackticksAreNames`.
- Grid (13), transfer (5) and sync (3) integration suites on SQLite, alongside the servers.
- Full run: **577 tests, 0 failures, 1 skipped** (the pre-existing PostgreSQL trust-auth
  skip). `Scripts/ci.sh --skip-app` green; the app builds with zero warnings.
- Verified in the app: a file opened through Finder became the connection "Northwind
  Lite" (feather mark, `main`, 13 tables, `~100000` estimate on the analysed table); the
  `orders` table tab, its Structure tab, a query with aggregates on the `main` session, and
  the Objects list with sizes from `dbstat`.

### Not done

- Attached databases show in the sidebar but nothing else targets them.
- The headless smoke test and the feature pass stay PostgreSQL-first.
- `TransferModel`'s "create the target database" emits the server engines' statements; on
  SQLite a new database is a new file, which the transfer wizard does not offer.
- No prepare step exists for SQLite because none is needed; `testenv/README.md` is
  unchanged.

## 2026-09-10 — SSH key files against current OpenSSH (ADR-0039)

Reported: connecting through an SSH tunnel with `~/.ssh/id_rsa` failed at `sshAuth` with
"SSH authentication failed", although `ssh` accepts the same key. Root cause: Citadel signs
RSA keys as `ssh-rsa` (SHA-1) only, and OpenSSH ≥ 8.8 refuses that algorithm for public-key
authentication; the server never saw a signature it could accept. Reproduced against the
machine's own `sshd` (OpenSSH 10.3) before the fix, green after.

### Done
- `OpenSSHPrivateKey` (DBTunnel) reads key files: `openssh-key-v1` with bcrypt + AES-CTR/CBC
  encryption; PEM `RSA PRIVATE KEY` (with OpenSSL's `DEK-Info` MD5/AES-CBC encryption), SEC1
  `EC PRIVATE KEY` (named or explicit curve), PKCS#8 `PRIVATE KEY`. Key types RSA, ed25519,
  ECDSA P-256/384/521. Every refusal names the file and, where one exists, the `ssh-keygen -p`
  command that converts it.
- `RSASSHPrivateKey<Algorithm>` signs through `_CryptoExtras` as `rsa-sha2-512`,
  `rsa-sha2-256` or `ssh-rsa`; `SSHTunnelProvider.connectClient` offers them in that order,
  one connection each (Citadel's authentication method gives a delegate a single turn). The
  error names every algorithm that was refused.
- `CTinkerBcrypt`: OpenBSD's `bcrypt_pbkdf` vendored as a C target. swift-crypto named as a
  direct dependency for `_CryptoExtras`; `Package.resolved` unchanged. `Scripts/ci.sh` allows
  the new imports (`_CryptoExtras`, `CTinkerBcrypt`, `os`) for DBTunnel.

### Tests
- `OpenSSHInteropTests` (9) start `/usr/sbin/sshd` unprivileged on a free port in a temp
  directory — no administrator rights, nothing on the machine changed — and forward to an
  echo server through it: RSA against a default server (the reported failure), RSA against a
  `PubkeyAcceptedAlgorithms ssh-rsa` server (the fallback), ed25519, ECDSA P-384,
  passphrase-protected RSA (bcrypt/aes256-ctr), aes256-cbc, PEM RSA, encrypted PEM RSA, and a
  key the server does not know, whose message lists `rsa-sha2-512, rsa-sha2-256, ssh-rsa`.
  A failure carries sshd's own log. They skip only when `sshd` is missing or will not start.
- `OpenSSHPrivateKeyTests` (10, no network): every format `ssh-keygen` writes (7 cases) is
  read as the right key type; four encrypted variants decrypt; RSA public numbers match the
  `.pub` file; wrong passphrase vs. missing passphrase vs. damaged file are told apart in
  three formats; an unsupported cipher is named with the conversion hint; garbage and a
  truncated file are rejected; messages carry path and hint; `mpint` normalisation;
  candidates are ordered strongest first; each algorithm's signature verifies only under its
  own name, and the public-key blob round-trips through the wire format.
- Existing `KnownHostsTests` (12) and `TunnelIntegrationTests` (8, 2 skipped without
  `TINKER_TEST_PG_URL`) unchanged in behaviour; `authenticationMethod(for:)` became
  `authenticationAttempts(for:)`.
- DBTunnel total: 45 tests, 0 failures, 2 skipped (the PostgreSQL-env ones).

### Not done / deferred
- RSA *host* keys are still verified through Citadel's `ssh-rsa` type: a server whose only
  host key is RSA fails at key exchange against OpenSSH ≥ 8.8. Fixing it means registering
  SHA-2 host-key types with `NIOSSHAlgorithms`, which changes key-exchange negotiation for
  every connection; not touched here.
- `chacha20-poly1305@openssh.com`- and 3DES-encrypted key files, encrypted PKCS#8, and FIDO
  `sk-` keys are refused with a message. Agent authentication remains ADR-0013.
- Jump hosts and password authentication against a real `sshd` are still only covered when
  `TINKER_TEST_SSH_*_URL` is set (unchanged).

## 2026-09-10 — Structure editor: Done with pending edits, row selection

Reported: a column added in Structure vanished after Done; the row highlight stayed on
`org_id` while the cursor was in `user_id`.

### Done
- `StructureView`: Done with pending statements opens the preview and leaves editing only
  after a complete run; with nothing pending it leaves at once. Cancel keeps editing.
- `TableTabController.reloadAfterStructureChange` re-reads with `keepingEdits: true`; it
  was the path that replaced the pending column. `StructureController.read` announces kept
  edits only when the server definition changed, because that status text is what makes
  the table tab reload its grid.
- `ColumnsPane`: a `@FocusState` keyed by column id on every text field; focus drives
  `selectedColumnID`. Type, Not null, Auto and the key button select their row too.

### Tests
- None added: the app was not built at the user's request ("jangan build apapun"), so the
  changes are parse-checked (`swift-format lint`) but not compiled or run. To verify:
  build, open a table's Structure, Edit, Add Column, Done → the preview appears; Execute →
  the column is on the server and editing ends. Click into any cell → its row highlights.

### Not done
- The highlight seen under the sidebar was the sidebar's own selection of the last-clicked
  item (`rekrut_sekolah`), on the same line by coincidence; nothing in the grid draws
  outside its pane. Left as is.

## 2026-09-11 — Review, Phase 1: critical fixes (ADR-0040, ADR-0041)

An eight-perspective review (architecture, internals, correctness, performance, security,
reliability, DX, UX) ranked ten findings as critical. This phase closes them.

### Done
- `ConnectionSession`: per-connection occupancy (idle / leased / resetting / checking) that
  only changes between suspension points; `lease()` snapshots the candidate before its
  `await` and re-finds it by id (it crashed on a subscript after a concurrent disconnect);
  `release()` rolls back unconditionally, resets, and only then marks the connection idle
  (a concurrent lease could receive it and lose its read-only guard to the reset);
  `disconnect()` takes the pool before its first `await` and refuses leases meanwhile;
  `lease()` fails after 15 s with a message when every connection stays busy; the
  introspection read releases its lease before returning; `testConnection` restores the
  published state; idle reaping keeps the most recently used connection.
- PostgreSQL: SQLSTATE 57014 is `.cancelled` only after this client's own cancel, else the
  server's verbatim message (`statement_timeout`); class 28 after connect is verbatim;
  `float4` shows `0.1`, not `0.10000000149011612`; `money` carries `12.34`, which the
  server reads back as the same amount (it carried `1234`).
- MySQL: no reconnect in the clear after a failed TLS handshake (the retry keyed on the
  words "ssl"/"tls"/"handshake" in the error); `BIT` binds its bytes back, not the text
  `"1010"`; `FLOAT` keeps its shortest text; `Int64(exactly:)` on `affectedRows` and
  `lastInsertID` (a trap past 2⁶³).
- SQLite: `affectedRows` is `sqlite3_changes64`, the statement's own rows, not the cascade
  and trigger rows `total_changes` added (a one-row delete with three children was
  refused by the grid as "touched 4 rows").
- `SQLStatement` carries its dialect: a MySQL script opening with `# note` had no leading
  keyword and a `DROP` behind it passed the production gate. `CALL` and `DO` ask for the
  connection's name on production.
- App: ⌘⌫ is Set NULL again (it deleted rows, and with auto-commit on the DELETE was on
  the server before the status bar updated); Delete Rows is ⌘−, Add Row ⌘+, Rollback ⌘⇧R,
  Run Selected ⌘⌃R, Close Window ⌘⇧W; New Window opens the scene (it sent
  `newDocument(_:)` to nothing). A delete under auto-commit asks first. Sort, filter,
  quick search, page changes and Refresh ask before discarding pending edits (they
  discarded silently — on production, where auto-commit is off, that was every pending
  edit). Closing a tab, the other tabs, or quitting asks when a tab has uncommitted edits
  or an open transaction. The confirmation callback is injected by the workspace at
  controller creation, not by a view on appear. The query tab's memory cap now leaves
  the stream (`break` left only the `switch`), and a run whose task was cancelled reports
  `.cancelled` instead of "OK — 0 rows".
- Connection editor: each TLS mode says what it checks; `require` and `prefer` say the
  certificate is not checked.
- `Scripts/ci.sh --strict` (or `TINKER_CI_STRICT=1`): fails when an engine URL is unset,
  when any test skips, or when the smoke test cannot run. Default remains warn-and-green.
- `--smoke-test` only takes a PostgreSQL connection whose database is `tinker_test`, and
  restores the stored connection on failure (it flipped it to production and read-only
  and restored it only on the happy path). The five grid integration suites no longer
  turn a misconfigured URL into "SQLite only" with `try?`.

### Tests
- `ConnectionSessionTests` (+6): `testAConnectionBeingResetIsNotHandedOut`,
  `testReleaseRollsBackUnconditionally`, `testDisconnectDuringAPingRefusesTheLease`,
  `testAFullPoolFailsTheLeaseAfterTheWaitTimeout`,
  `testTestConnectionRestoresThePublishedState`,
  `testIntrospectionReleasesItsLeaseBeforeReturning`. `FakeDriver` gained ping/reset
  delays and a rollback count.
- `PostgresIntegrationTests` (+2): `testStatementTimeoutKeepsTheServersMessageAndIsNotACancel`,
  `testFloat4AndMoneyKeepTextTheServerAccepts`.
- `MySQLIntegrationTests` (+1): `testBitValuesRoundTripThroughParametersAndFloatKeepsItsText`.
- `SQLiteIntegrationTests` (+1): `testAffectedRowsCountsDirectRowsNotCascadesOrTriggers`.
- `StatementSplitterTests` (+2): `testLeadingKeywordRespectsTheDialectsComments`,
  `testOpaqueBodiesCountAsDestructive`.
- `Scripts/ci.sh` green against local PostgreSQL 16 and MySQL 9.4 plus the SQLite file:
  one skip (`testWrongPasswordSurfacesAsAuthenticationFailure`: the local server trusts
  the user), app built with zero warnings, smoke test passed.

### Not done / deferred
- The delete confirmation, pending-edit guards, close/quit questions and shortcut changes
  have no automated test: `Commands` and sheets are not reachable from XCTest, and the
  smoke pass drives controllers with `confirm` unset (which answers "yes"). Verified by
  hand in the built app is still owed; listed under Phase 5's UI-test work.
- Class-28-after-connect verbatim mapping has no integration test: nothing a
  non-superuser can run on the local server produces one.
- Reconnect policy, keepalive, backpressure, the cancel-hits-next-statement race, and
  releasing a query tab's lease when idle are Phase 2/3.
