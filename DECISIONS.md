# DECISIONS.md — architecture decision record (append-only)

Format: `ADR-NNNN — title` / date / context / decision / consequences. Never edit past entries; supersede them.

---

## ADR-0001 — One root `Package.swift`, packages laid out under `Packages/<Name>/`
Date: 2026-09-03 (Phase 0)

**Context.** SPEC §3 lists `Package.swift (workspace root: local packages)` and seven packages under `Packages/`. Two readings: (a) seven independent packages each with its own manifest plus a root umbrella, or (b) one root manifest whose targets point at `Packages/<Name>/Sources` and `Packages/<Name>/Tests`.

**Decision.** (b). One manifest, one build graph, one `swift test`, one local package reference from the Xcode app (`relativePath = ..`). On-disk layout is exactly the one in SPEC §3.

**Consequences.** Separate packages would enforce the import direction structurally, and SwiftPM does not fully enforce it for sibling targets. `Scripts/ci.sh` therefore lints every `import` in `Packages/*/Sources` against an allow-list (DBCore → Foundation + Logging only; drivers never import each other; DBStore never imports drivers). Building each package in isolation would otherwise rebuild NIO seven times per CI run.

## ADR-0002 — App target is `App/DBStudio.xcodeproj`, product `DBStudio`, bundle id `com.thinkfree.DBStudio`
Date: 2026-09-03 (Phase 0)

**Context.** The repository was created as `ThinkStudio.xcodeproj` with a boilerplate SwiftUI app (macOS 26.5 deployment target, Swift 5 mode, App Sandbox on, default MainActor isolation). SPEC names the product DBStudio, requires macOS 14.0+, Swift 6 strict concurrency, hardened runtime, and no sandbox (§2).

**Decision.** The boilerplate project was replaced by `App/DBStudio.xcodeproj` (synchronized folder `App/DBStudio/`), following the spec's naming and build settings. The bundle-id prefix keeps the developer's `com.thinkfree` organisation. Keychain service and Application Support paths use the spec's `DBStudio` names.

**Consequences.** If the product must ship under the name ThinkStudio, rename `PRODUCT_NAME`/`PRODUCT_BUNDLE_IDENTIFIER` and the Application Support folder in one commit; nothing else depends on the name.

## ADR-0003 — XCTest, not Swift Testing
Date: 2026-09-03 (Phase 0)

**Context.** SPEC §17 requires `XCTMetric`, os_signpost performance tests, XCUITest smoke tests, and skip-with-reason reporting.

**Decision.** All tests use XCTest. `DBTestKit` throws `XCTSkip` with a reason when an engine is not configured, and throws `TestEnvironmentError` (a failure) when a configured URL is unsafe.

**Consequences.** `DBTestKit` is a regular library target that imports XCTest (the same pattern as swift-snapshot-testing). It must never be linked into the app.

## ADR-0004 — Fixed credentials for the isolated test user
Date: 2026-09-03 (Phase 0)

**Context.** `testenv/prepare.sh` must be idempotent and print URLs the developer exports. A random password would change on every run and desynchronise the exported URL.

**Decision.** User `dbstudio_test`, password `dbstudio_test`, database `dbstudio_test`. The user is `NOSUPERUSER NOCREATEDB NOCREATEROLE` on PG and has only `USAGE ON *.*` plus `ALL ON dbstudio_test.*` on MySQL; `prepare.sh` verifies both after loading fixtures and refuses to print the URL otherwise.

**Consequences.** Local-only credentials. On PG the test user can still *connect* to other databases (CONNECT is granted to PUBLIC by default) but owns nothing there and cannot create objects; revoking that would mean modifying other databases, which SPEC §17.1 forbids.

## ADR-0005 — "Zero warnings" is enforced by `Scripts/ci.sh`, not by `Package.swift`
Date: 2026-09-03 (Phase 0)

**Context.** `.treatAllWarnings(as: .error)` in the manifest makes Xcode fail with `conflicting options '-warnings-as-errors' and '-suppress-warnings'`, because Xcode compiles package dependencies with warnings suppressed. `-Xswiftc -warnings-as-errors` on the command line would also apply to third-party packages, which we do not control.

**Decision.** `ci.sh` deletes the build directories of first-party modules (dependencies stay cached), rebuilds, and fails on any `warning:` whose path is under `Packages/` or `Tools/`. The app target sets `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and `GCC_TREAT_WARNINGS_AS_ERRORS=YES` in the project and `ci.sh` additionally greps the xcodebuild log.

**Consequences.** Warnings in third-party packages are visible in the log but do not fail CI.

## ADR-0006 — Admin-user check in `DBTestKit` is a name heuristic until Phase 1
Date: 2026-09-03 (Phase 0)

**Context.** SPEC §17.1 requires tests to refuse a URL whose user has privileges beyond `dbstudio_test`. Without a driver (Phase 1) the privilege level cannot be queried.

**Decision.** Phase 0 refuses the database name being anything but `dbstudio_test` and refuses users named `root`, `postgres`, `admin`, `mysql`. Phase 1 adds the real check at connect time (PG `rolsuper`, MySQL `SHOW GRANTS`) inside the integration-test fixtures.

**Consequences.** Until Phase 1, a non-standard admin account name is not caught. Tracked in PROGRESS.md.

## ADR-0007 — Cancel uses `pg_cancel_backend`, not the wire CancelRequest
Date: 2026-09-03 (Phase 1)

**Context.** SPEC §7.3 asks for cancellation via PostgreSQL's cancel protocol: a new TCP connection carrying `CancelRequest` with the backend pid and the secret key. postgres-nio 1.33 receives `BackendKeyData` but keeps both the pid and the secret key internal; neither is reachable through public API, and the channel cannot be observed from outside the library.

**Decision.** Open a second connection and run `SELECT pg_cancel_backend(<pid>)`. The pid comes from `pg_backend_pid()`, read once at connect time and exposed as `SQLConnection.backendID`.

**Consequences.** The requirement in SPEC §4 — "must result in a server-side cancel" — is met exactly: `pg_cancel_backend` sends the same `SIGINT` to the backend that the postmaster sends on receiving a `CancelRequest`, the statement fails with SQLSTATE 57014, and the connection stays usable. What differs is cost: a cancel opens a connection (~50 ms locally) instead of a bare socket write, and it requires the connecting role to own the target backend, which it always does here. `ConnectionSession` (Phase 2) keeps a spare connection to avoid the reconnect, mirroring the approach the spec prescribes for MySQL's `KILL QUERY`. Verified by `testServerSideCancelReturnsQuicklyAndLeavesTheConnectionUsable`.

## ADR-0008 — Two execution paths, chosen by whether the statement streams rows
Date: 2026-09-03 (Phase 1)

**Context.** postgres-nio offers two query APIs and neither does everything the spec needs. The structured-concurrency `query()` returns a back-pressured `PostgresRowSequence` but exposes no command tag, so `affectedRows` is unavailable. The callback `query(_:logger:file:line:_:)` returns `PostgresQueryMetadata` — the server's real command tag — but has no back-pressure. SPEC §12.3 makes `affectedRows == 1` the safety check that protects every grid commit, and SPEC §12.6 requires a million rows to stream without being materialised.

**Decision.** Statements whose leading keyword can return an unbounded result — `SELECT`, `WITH`, `VALUES`, `TABLE`, `SHOW`, `EXPLAIN` — or that contain `RETURNING`, take the back-pressured path; their affected-row count equals the number of rows streamed, which is what PostgreSQL itself reports for those commands. Every other statement takes the callback path and reports the server's own tag.

**Consequences.** Generated `UPDATE`/`DELETE` carry no `RETURNING`, so the affected-row check always reads a real server count. A misclassification can only cost back-pressure, never correctness. Covered by `testAffectedRowsForDML` and `testLargeResultStreamsInBatchesWithoutLoadingEverything`.

## ADR-0009 — Two known gaps in postgres-nio's public API
Date: 2026-09-03 (Phase 1)

**Context.** Two spec requirements have no public API in postgres-nio 1.33.

**Decision and consequences.**
1. *Notices.* SPEC §7.3 asks for `RAISE NOTICE` output in `QueryCompletion.notices`. postgres-nio handles `NoticeResponse` inside its channel handler and never surfaces it, so `notices` is always empty. Recorded as a gap in PROGRESS.md rather than faked.
2. *Columns of an empty result.* The row description is only reachable through the rows themselves, so a statement returning zero rows yields `columns: []`. Table tabs are unaffected because their columns come from the introspector; a query tab showing an empty result shows no headers.
3. *Transaction status.* `ReadyForQuery` carries it and postgres-nio does not expose it, so `isInTransaction` is tracked by the driver: the transaction methods set it, and `execute` also watches for `BEGIN`/`COMMIT`/`ROLLBACK` typed into the editor. A transaction opened inside a function body or a `DO` block is not observed.

Closing any of these means either a postgres-nio pull request or the fallback the spec reserves for MySQL — a hand-written frontend — which is out of scope for v0.1.

## ADR-0010 — Binary results, with text rendered losslessly by the driver
Date: 2026-09-03 (Phase 1)

**Context.** SPEC §5 requires `decimal` and `timestamp` to keep "the server text". postgres-nio hard-codes binary result format in its `Bind` message; there is no public way to request text.

**Decision.** Decode the binary form and render the exact text PostgreSQL itself would print. `numeric` is reassembled from its base-10000 digit groups, so every digit and the display scale survive. Timestamps are carried as integer microseconds and formatted through integer arithmetic; `timestamptz` is rendered in the session's `TimeZone`, whose offset for that specific instant comes from Foundation's zone database. Nothing passes through `Double` or `Foundation.Date`.

**Consequences.** Round-trip safety holds and is tested by comparing `serverText` back against the stored value on the server. Types whose binary form the driver does not model become `.raw` with `pg_type.typname` and their bytes, which is what SPEC §7.3 prescribes. `pg_type` is read once per connection so that enums, domains and user-defined types are classified from the catalog rather than guessed.

## ADR-0011 — Parameters are sent as text with an unspecified type OID
Date: 2026-09-03 (Phase 1)

**Context.** Generated DML must bind values server-side (SPEC §7.1) for every type the grid can edit, including types the driver models only as `.raw`.

**Decision.** Every parameter is bound as text with type OID 0, which tells PostgreSQL to infer the type from where the placeholder sits. One code path covers all types, and the server does the coercion.

**Consequences.** A placeholder with no inferable context — `SELECT $1` with no cast — fails with the server's own "could not determine data type" error, which is correct and legible. Generated DML always has column context. Covered by `testParameterTypesTheServerInfers`.

## ADR-0012 — `ConnectionSession` lives in DBCore behind three protocols
Date: 2026-09-03 (Phase 2)

**Context.** SPEC §3 puts the session in `DBCore`, and SPEC §9 has it resolve Keychain secrets, open SSH tunnels and hold a pool of driver connections. `DBCore` may import only Foundation and swift-log, so it cannot reach any of those directly.

**Decision.** `DBCore` declares `SecretStore`, `TunnelProvider` and `DriverRegistry`; the concrete implementations are injected. `DBStore` provides `KeychainSecretStore`, `DBTunnel` provides `SSHTunnelProvider`, and the app registers the drivers at launch.

**Consequences.** The session is testable with no I/O at all — `DBTestKit` supplies a fake driver, introspector and tunnel — and the dependency direction in SPEC §3 holds unchanged. The cost is one indirection at startup, where the app builds the registry.

## ADR-0013 — SSH agent authentication is not available
Date: 2026-09-03 (Phase 2)

**Context.** SPEC §9 lists `.agent` alongside password and key authentication. Citadel offers no agent support, and swift-nio-ssh's `NIOSSHUserAuthenticationOffer` accepts only a `NIOSSHPrivateKey` the process holds — there is no hook for a signature produced elsewhere. Supporting an agent means implementing `NIOSSHPrivateKeyProtocol`, `NIOSSHPublicKeyProtocol` and `NIOSSHSignatureProtocol` over the agent socket protocol and registering them as custom algorithms.

**Decision.** Password and private-key-file authentication ship. `.agent` throws a `tunnelFailed(stage: .sshAuth, …)` whose message names the alternative (`~/.ssh/id_ed25519`). The spec's stated fallback — libssh2 through a C module — would replace the whole tunnel implementation for one authentication method and is not worth it in v0.1.

**Consequences.** A user whose key is only in the agent, or on a hardware token, must point DBStudio at a key file. Recorded as a gap in PROGRESS.md. ECDSA key *files* are also unsupported, because Citadel exposes OpenSSH readers for ed25519 and RSA only; ed25519 is what `ssh-keygen` produces by default.

## ADR-0014 — Tunnel tests use an SSH server hosted in the test process
Date: 2026-09-03 (Phase 2)

**Context.** SPEC §16 Phase 2 names the machine's own `sshd` as the SSH test target, with Remote Login enabled in System Settings. Enabling it needs administrator rights, which the test environment is forbidden to take, and it is off on this machine.

**Decision.** The tunnel suite starts an SSH server inside the test process using Citadel's server support, with a generated host key and a delegate that accepts one password or one public key. Tests then forward to a local echo server and to the real local PostgreSQL.

**Consequences.** Key exchange, authentication and `direct-tcpip` forwarding are exercised over a real socket against a real SSH implementation, so the client is genuinely covered. What is *not* covered is interoperability with OpenSSH's `sshd` — its key-exchange and cipher preferences, its `known_hosts` behaviour end to end, and jump hosts. Those remain gaps until `DBSTUDIO_TEST_SSH_PASSWORD_URL` / `DBSTUDIO_TEST_SSH_JUMP_URL` name a reachable server.

Two Citadel defects were found along the way and worked around in the test server rather than in the library: `DirectTCPIPForwardingDelegate` installs only outbound handlers, so it forwards nothing; and `Curve25519.Signing.PrivateKey.makeSSHRepresentation()` writes a key its own parser rejects with `invalidPadding`. Key fixtures are therefore generated with `ssh-keygen`, which is what users have anyway.

## ADR-0015 — Both ends of a forward share one event loop
Date: 2026-09-03 (Phase 2)

**Context.** The forward glues an accepted local socket to an SSH `direct-tcpip` channel; each handler writes into the other's channel. NIO asserts that a write happens on the channel's own event loop, and the two channels were landing on different loops.

**Decision.** The local listener passes the SSH client's event loop as its `childGroup`, so every accepted socket shares a loop with the SSH connection.

**Consequences.** Writes cross no loop boundary and need no hop, which is also the faster arrangement. One SSH connection's forwards are serialised on one loop, which is correct for a client where a tunnel carries at most a handful of database connections.

## ADR-0016 — `saved_queries` is not created
Date: 2026-09-03 (Phase 2)

**Context.** SPEC §15 lists a `saved_queries` table marked "(Phase 2)", while SPEC §16 defers saved queries and snippets to v0.2 with "do not build now, do not stub".

**Decision.** The table is not created. `StoreSchema` is append-only, so v0.2 adds it as migration 2 when the feature is built.

**Consequences.** None for v0.1. The deferral list wins over the table listing, since building the table now would be the stub the spec forbids.
