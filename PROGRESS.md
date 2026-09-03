# PROGRESS.md — per-phase log

Current phase: **Phase 2 — ConnectionSession, tunnel, store** (Phases 0–1 complete).

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
