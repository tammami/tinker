# DECISIONS.md — architecture decision record (append-only)

Format: `ADR-NNNN — title` / date / context / decision / consequences. Never edit past entries; supersede them.

---

## ADR-0001 — One root `Package.swift`, packages laid out under `Packages/<Name>/`
Date: 2026-09-03 (Phase 0)

**Context.** SPEC §3 lists `Package.swift (workspace root: local packages)` and seven packages under `Packages/`. Two readings: (a) seven independent packages each with its own manifest plus a root umbrella, or (b) one root manifest whose targets point at `Packages/<Name>/Sources` and `Packages/<Name>/Tests`.

**Decision.** (b). One manifest, one build graph, one `swift test`, one local package reference from the Xcode app (`relativePath = ..`). On-disk layout is exactly the one in SPEC §3.

**Consequences.** Separate packages would enforce the import direction structurally, and SwiftPM does not fully enforce it for sibling targets. `Scripts/ci.sh` therefore lints every `import` in `Packages/*/Sources` against an allow-list (DBCore → Foundation + Logging only; drivers never import each other; DBStore never imports drivers). Building each package in isolation would otherwise rebuild NIO seven times per CI run.

## ADR-0002 — App target is `App/Tinker.xcodeproj`, product `Tinker`, bundle id `com.thinkfree.Tinker`
Date: 2026-09-03 (Phase 0)

**Context.** The repository was created as `ThinkStudio.xcodeproj` with a boilerplate SwiftUI app (macOS 26.5 deployment target, Swift 5 mode, App Sandbox on, default MainActor isolation). SPEC names the product Tinker, requires macOS 14.0+, Swift 6 strict concurrency, hardened runtime, and no sandbox (§2).

**Decision.** The boilerplate project was replaced by `App/Tinker.xcodeproj` (synchronized folder `App/Tinker/`), following the spec's naming and build settings. The bundle-id prefix keeps the developer's `com.thinkfree` organisation. Keychain service and Application Support paths use the spec's `Tinker` names.

**Consequences.** If the product must ship under the name ThinkStudio, rename `PRODUCT_NAME`/`PRODUCT_BUNDLE_IDENTIFIER` and the Application Support folder in one commit; nothing else depends on the name.

## ADR-0003 — XCTest, not Swift Testing
Date: 2026-09-03 (Phase 0)

**Context.** SPEC §17 requires `XCTMetric`, os_signpost performance tests, XCUITest smoke tests, and skip-with-reason reporting.

**Decision.** All tests use XCTest. `DBTestKit` throws `XCTSkip` with a reason when an engine is not configured, and throws `TestEnvironmentError` (a failure) when a configured URL is unsafe.

**Consequences.** `DBTestKit` is a regular library target that imports XCTest (the same pattern as swift-snapshot-testing). It must never be linked into the app.

## ADR-0004 — Fixed credentials for the isolated test user
Date: 2026-09-03 (Phase 0)

**Context.** `testenv/prepare.sh` must be idempotent and print URLs the developer exports. A random password would change on every run and desynchronise the exported URL.

**Decision.** User `tinker_test`, password `tinker_test`, database `tinker_test`. The user is `NOSUPERUSER NOCREATEDB NOCREATEROLE` on PG and has only `USAGE ON *.*` plus `ALL ON tinker_test.*` on MySQL; `prepare.sh` verifies both after loading fixtures and refuses to print the URL otherwise.

**Consequences.** Local-only credentials. On PG the test user can still *connect* to other databases (CONNECT is granted to PUBLIC by default) but owns nothing there and cannot create objects; revoking that would mean modifying other databases, which SPEC §17.1 forbids.

## ADR-0005 — "Zero warnings" is enforced by `Scripts/ci.sh`, not by `Package.swift`
Date: 2026-09-03 (Phase 0)

**Context.** `.treatAllWarnings(as: .error)` in the manifest makes Xcode fail with `conflicting options '-warnings-as-errors' and '-suppress-warnings'`, because Xcode compiles package dependencies with warnings suppressed. `-Xswiftc -warnings-as-errors` on the command line would also apply to third-party packages, which we do not control.

**Decision.** `ci.sh` deletes the build directories of first-party modules (dependencies stay cached), rebuilds, and fails on any `warning:` whose path is under `Packages/` or `Tools/`. The app target sets `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` and `GCC_TREAT_WARNINGS_AS_ERRORS=YES` in the project and `ci.sh` additionally greps the xcodebuild log.

**Consequences.** Warnings in third-party packages are visible in the log but do not fail CI.

## ADR-0006 — Admin-user check in `DBTestKit` is a name heuristic until Phase 1
Date: 2026-09-03 (Phase 0)

**Context.** SPEC §17.1 requires tests to refuse a URL whose user has privileges beyond `tinker_test`. Without a driver (Phase 1) the privilege level cannot be queried.

**Decision.** Phase 0 refuses the database name being anything but `tinker_test` and refuses users named `root`, `postgres`, `admin`, `mysql`. Phase 1 adds the real check at connect time (PG `rolsuper`, MySQL `SHOW GRANTS`) inside the integration-test fixtures.

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

**Consequences.** A user whose key is only in the agent, or on a hardware token, must point Tinker at a key file. Recorded as a gap in PROGRESS.md. ECDSA key *files* are also unsupported, because Citadel exposes OpenSSH readers for ed25519 and RSA only; ed25519 is what `ssh-keygen` produces by default.

## ADR-0014 — Tunnel tests use an SSH server hosted in the test process
Date: 2026-09-03 (Phase 2)

**Context.** SPEC §16 Phase 2 names the machine's own `sshd` as the SSH test target, with Remote Login enabled in System Settings. Enabling it needs administrator rights, which the test environment is forbidden to take, and it is off on this machine.

**Decision.** The tunnel suite starts an SSH server inside the test process using Citadel's server support, with a generated host key and a delegate that accepts one password or one public key. Tests then forward to a local echo server and to the real local PostgreSQL.

**Consequences.** Key exchange, authentication and `direct-tcpip` forwarding are exercised over a real socket against a real SSH implementation, so the client is genuinely covered. What is *not* covered is interoperability with OpenSSH's `sshd` — its key-exchange and cipher preferences, its `known_hosts` behaviour end to end, and jump hosts. Those remain gaps until `TINKER_TEST_SSH_PASSWORD_URL` / `TINKER_TEST_SSH_JUMP_URL` name a reachable server.

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

## ADR-0017 — A `DBGrid` package holds the grid's model
Date: 2026-09-03 (Phase 3)

**Context.** SPEC §3 puts the data grid under `App/Tinker/Features/DataGrid/`, and SPEC §17 requires unit tests for `EditBuffer` semantics and paging-strategy selection. Code in the Xcode app target cannot be reached by `swift test`, which is what `Scripts/ci.sh` runs.

**Decision.** The grid's model — `RowBuffer`, `EditBuffer`, `GridModel`, `GridCommitter`, `ClipboardFormatter`, `RowExporter`, `SessionGridLoader` — lives in a new `Packages/DBGrid`. Only the AppKit views and the tab controller stay in the app.

**Consequences.** An eighth package the spec's layout does not list, in exchange for the buffer, the edit overlay, the commit rules and the whole paging path being covered by tests that run on every CI pass, including against a real million-row table. The dependency-direction lint covers `DBGrid` like every other package.

## ADR-0018 — Highlighting uses `DBSQL.SQLTokenizer`, not tree-sitter
Date: 2026-09-03 (Phase 5)

**Context.** SPEC §2.1 lists `ChimeHQ/SwiftTreeSitter` plus a `tree-sitter-sql` grammar for "highlighting and statement boundary detection only".

**Decision.** Neither is added. Statement boundaries already come from `DBSQL.StatementSplitter`, which handles PostgreSQL dollar quoting and the MySQL client's `DELIMITER` directive — the latter is a client convention no SQL grammar models. Highlighting uses `DBSQL.SQLTokenizer`, which classifies keywords, strings, comments, numbers, placeholders and quoted identifiers from the same scanner the splitter uses.

**Consequences.** One shared lexer instead of two parsers that could disagree, and no C grammar to vendor and build. What is lost is structural highlighting — a table name coloured differently from a column name — which the spec does not ask for. If v0.2 wants a real parse tree, the tokenizer's public API is the seam to replace.

## ADR-0019 — The UI smoke test is a launch flag, not XCUITest
Date: 2026-09-03 (Phase 3–5)

**Context.** SPEC §17 asks for a minimal XCUITest covering launch, create connection, connect, open table, run query and cancel query. XCUITest drives the app through the accessibility system, which requires the machine to grant Accessibility permission to the test runner. This machine denies synthetic input to the build session, and a build machine cannot grant it to itself.

**Decision.** `Tinker --smoke-test` runs the same sequence headlessly against the objects the views drive: `AppEnvironment` opens the store, `ConnectionSession` connects, `QueryTabController` runs a statement and reads its rows, cancels a `pg_sleep(30)` and checks it returned in under five seconds, and `TableTabController` introspects and pages a real table. `Scripts/ci.sh` runs it after building the app.

**Consequences.** Every layer below the views is covered end to end on each CI run, and the checks are readable and fast. What is *not* covered is the view layer itself: menu items, focus, drawing, mouse and keyboard handling in the grid and editor. Those remain manual, and PROGRESS.md says so.

## ADR-0020 — MySQL uses the prepared-statement protocol, with a text fallback
Date: 2026-09-03 (Phase 6)

**Context.** mysql-nio offers two paths. `query()` prepares the statement, binds parameters server-side and reports the OK packet, which is where `affectedRows` and `lastInsertID` come from — both required by SPEC §7.3 and by the grid's commit check. `simpleQuery()` uses the text protocol, accepts any statement, and reports no metadata at all.

**Decision.** Everything goes through `query()`. When the server answers 1295, "not supported in the prepared statement protocol yet", the statement is retried on `simpleQuery()`.

**Consequences.** Statements that need the fallback — `SHOW GRANTS`, `ANALYZE`, several administrative commands — report no affected-row count, which none of them has. Every statement the grid generates takes the prepared path, so the affected-row check always reads a real count. Rows arrive in binary format on the prepared path and text on the fallback, and the decoder handles both.

## ADR-0021 — mysql-nio's own error cases are mapped back to server errors
Date: 2026-09-03 (Phase 6)

**Context.** mysql-nio unwraps two common server errors into cases of its own: 1064 becomes `.invalidSyntax(String)` and 1062 becomes `.duplicateEntry(String)`. Both lose the numeric code and the SQLSTATE, which SPEC §6 requires the UI to show.

**Decision.** The mapper puts them back: `.invalidSyntax` becomes SQLSTATE 42000 code 1064, `.duplicateEntry` becomes 23000 code 1062, and the message travels through untouched.

**Consequences.** A MySQL syntax error reads the same as a PostgreSQL one — code, SQLSTATE and the server's own words — instead of appearing as an internal protocol error. The reconstruction is exact for these two codes; a future mysql-nio release that unwraps more errors would need the same treatment.

## ADR-0022 — No Server Name Indication for an IP address
Date: 2026-09-03 (Phase 6)

**Context.** TLS to `127.0.0.1` failed with `NIOSSLExtraError.cannotUseIPAddressInSNI`. SNI carries a host name, and NIOSSL refuses an address.

**Decision.** The driver sends a server name only when the host is not an IPv4 or IPv6 literal.

**Consequences.** `require` mode works against a server reached by address, which is the common local case. `verify-full` against an address cannot check a host name, so it verifies the chain only — the same thing `mysql --ssl-mode=VERIFY_IDENTITY` does with an address.

## ADR-0023 — Sparkle is configured from the environment at release time
Date: 2026-09-03 (Phase 7)

**Context.** Sparkle 2 needs an appcast URL and an EdDSA public key, and the matching private key signs each release. Only whoever ships the app has those, and committing a placeholder key would make an unsigned feed look trusted.

**Decision.** `Info.plist` reads `SUFeedURL` and `SUPublicEDKey` from build settings that `Scripts/release.sh` fills in from `TINKER_APPCAST_URL` and `TINKER_SPARKLE_PUBLIC_KEY`. A build without them creates no `SPUStandardUpdaterController` at all, and the Check for Updates menu item is disabled and says so.

**Consequences.** A development build never touches the network for updates and never logs Sparkle's "no feed" error. Automatic checking is off until the user turns it on, which is the right default for a tool that talks to production databases. The release script prints the `sign_update` command whose output goes into the appcast.

## ADR-0024 — The signed and notarized path could not be exercised here
Date: 2026-09-03 (Phase 7)

**Context.** SPEC §16 Phase 7 accepts on "a notarized DMG installs and runs on a clean macOS 14 machine". Notarization needs a Developer ID Application certificate and an App Store Connect credential. This machine has only an Apple Development certificate, and creating a Developer ID one requires a paid account action no build can take for itself.

**Decision.** `Scripts/release.sh` implements the whole path — archive, export with `developer-id`, verify the hardened runtime, notarize, staple, `spctl` assess, build and notarize the DMG — and refuses to run with a message naming exactly what is missing and how to create it. `--unsigned` runs everything except signing and notarization, which is what was verified here.

**Consequences.** The build, packaging and installation path is proven: `--unsigned` produces a 7.2 MB DMG whose app passes the smoke test when run from the mounted image. Signing, notarization, stapling and Gatekeeper's verdict are untested and recorded as a gap in PROGRESS.md. Whoever holds the certificate runs `Scripts/release.sh` unchanged.

## ADR-0025 — Menu commands route through a shared workspace reference, not `@FocusedValue`
Date: 2026-09-03

**Context.** The Query and View menus act on the frontmost workspace. `@FocusedValue` is the SwiftUI way to express that, and it works until an AppKit view takes first responder: while `SQLTextView` has focus the focused value goes missing, SwiftUI disables the menu item, and its keyboard shortcut is swallowed with nothing happening. The SQL editor is exactly where ⌘↩ matters, so the mechanism failed in the one place it was needed.

**Decision.** `CommandCenter.shared` holds a reference to whichever `WorkspaceController` is frontmost; each workspace registers on appear and deregisters on disappear. The menus read from it instead of from the focus system.

**Consequences.** Run, Run All, Cancel, Format, History and the tab commands stay enabled while the editor has focus, which `WorkspaceUITests.testQueryMenuRunItem` checks by clicking the item and asserting it is enabled. The cost is one piece of global state; it is confined to menu routing and holds only the frontmost controller.

## ADR-0026 — Engine badges are drawn, not vendor logos
Date: 2026-09-03

**Context.** A sidebar of connections should say at a glance which are PostgreSQL and which are MySQL. The obvious answer is each project's logo, but those are trademarks, and bundling them in a shipped application is not ours to do.

**Decision.** `EngineMark` draws the badge in the app's own hand: what each engine is known by — an elephant, a dolphin — as a plain silhouette on a plate in that project's colour. No vendor artwork is copied or shipped.

**Consequences.** A developer reads the row instantly, and the app carries no third-party marks. The shapes are `Shape` implementations rather than assets, so they stay sharp at any size and need no catalogue entries. If the marks are ever judged too close to the originals, only this one file changes.

## ADR-0027 — The app icon is a hand-authored Icon Composer document
Date: 2026-09-03

**Context.** macOS 26 draws app icons in light, dark, tinted and clear appearances, and applies the shape, gradient, specular highlight and shadow itself. An asset catalogue cannot express that: `actool` rejects `appearances` entries under the `mac` idiom and rejects a `platform` value of `macos` or `macOS` — the appearance format in Xcode's own templates is iOS-only. Both single-size layouts warned, which fails `Scripts/ci.sh`. The supported input is an Icon Composer `.icon` document, and Icon Composer is a GUI application with no command line.

**Decision.** `Tinker.icon` is written by hand rather than through the GUI. It is a plain directory: `icon.json` naming one group, one layer and the background fill, and `Assets/bulb.svg` holding the artwork. The schema was read out of `IconComposerFoundation`; colours are `space:components` strings, which is what "Invalid color encoding, missing ':' delimiter" was complaining about. `ASSETCATALOG_COMPILER_APPICON_NAME` names it, and the synchronized folder group picks it up with no project surgery.

**Consequences.** The icon is adaptive: the system composites the squircle, the gradient, the specular sweep and the shadow, and derives the dark and tinted appearances, so none of that is painted into the artwork any more. The source is one SVG a designer can edit, which is why `Scripts/make-icon.swift` and the ten fixed-size PNGs are gone. The format is not publicly documented, so an Xcode upgrade could change it; `xcrun actool --compile` on the `.icon` reproduces the check in seconds, and `Scripts/ci.sh` fails on any warning it emits.

## ADR-0028 — The table designer moves from deferred into Phase 8
Date: 2026-09-03

**Context.** SPEC §16 listed "table designer" and "structure sync" as deferred to v0.2, with `CLAUDE.md` forbidding scope expansion. The user asked for structure editing — set a primary key, create a btree index, design a table the way Navicat or TablePlus do — which is exactly that deferred item.

**Decision.** Rather than build against the spec, the spec changed first. §8 gains the four reads a designer needs (check constraints, triggers, partitioning, collations), a new §15b describes the feature and its acceptance criteria, and §16 gains Phase 8 and drops both items from the deferred list. Import, data transfer, backup/restore and the rest stay deferred.

**Consequences.** The repository's rules and its code agree again: work on the designer is now in scope because the spec says so, and everything still outside §16's phases is still forbidden. The cost is a fifth phase after "release hardening", so v0.1 as originally scoped is already shippable and Phase 8 lands on top of it.

**What the spec now demands that v0.1 did not.** DDL must run in one transaction with the statements shown first, PostgreSQL must roll back on failure, and MySQL's implicit DDL commit must be stated to the user rather than hidden — because on MySQL a half-applied structure change is a real outcome, not a theoretical one.

## ADR-0029 — A table tab shows pages, not an endless scroll
Date: 2026-09-03

**Context.** SPEC §12 built the grid around a scrollbar over the whole table: 1,000-row pages fetched behind a scroll position, with §12.6 asking that a million rows stay smooth. The user asked for what Navicat and TablePlus do instead — 1,000 rows on screen with a pager underneath.

**Decision.** §12.7 replaces the endless scroll for **table tabs** with explicit pages: first / previous / next / last, the page number and the row range in the status bar, and never more than one page held. Query results keep streaming, because a result set is what one statement returned and paging it would mean running another.

**Consequences.** The million-row acceptance criterion in §12.6 now applies to a page rather than to a scroll: the cost of reaching row 900,000 is one query, not 900 of them. The buffer, the keyset strategy and the paging planner all stay; what changes is who moves the page — the pager rather than the scrollbar. Memory is bounded by one page, which is strictly better than the old ceiling.

## ADR-0030 — Estimates are labelled as estimates
Date: 2026-09-03

**Context.** The grid drew its row count from `approximateRowCount`, the planner's estimate. Under a filter that number describes a different set of rows entirely, and a filtered grid whose first page failed showed a million empty lines. The Objects list would carry the same figure per table.

**Decision.** An estimate is only ever used where it is true — an unfiltered table — and is shown as an estimate. A filtered grid counts what it actually read, and the Objects list says its row figures are the server's estimates.

**Consequences.** A filtered grid can under-report until the last page is reached, which is honest. Nothing runs `COUNT(*)` to make a number look precise, which is what §12 forbade for good reason on a large table.

## ADR-0031 — Grid edits may write as they are made, but never on production
Date: 2026-09-07

**Context.** SPEC §12.3 says nothing reaches the server until Commit or Discard. The user asked for the opposite on ordinary connections: an edit that writes the moment focus leaves the cell, a new row that writes when the selection leaves it, and no Commit/Discard question in the status bar — the way a spreadsheet behaves.

**Decision.** Each table tab and query tab has an Auto-commit checkbox (on by default). With it on, a cell edit, Set NULL and Delete Rows write at once through the same path Commit uses — primary-key `WHERE` with the original values, one transaction, `affectedRows == 1` checked — and the page is re-read afterwards. A new row waits until the selection leaves it. With it off, §12.3 applies unchanged. On a connection marked Production the checkbox is not shown and every write still goes through the commit sheet, whatever the tab's setting: production keeps the spec's behaviour.

**Consequences.** Writes are single-flight per grid: one commit at a time, a change made during a write goes as the next one, and only what a commit actually wrote is cleared from the buffer, so nothing typed during a write is lost. A refused write leaves the edit in place with the server's message and a Retry. §12.3's guarantee is now conditional on the checkbox, which is why it is visible in the bar and remembered per tab.
## ADR-0032 — Text exports guard against spreadsheet formula injection
Date: 2026-09-07

**Context.** A CSV or tab-separated field that begins with `=`, `+`, `-`, `@`, a tab or a carriage return is evaluated by Excel, Numbers and Google Sheets when the file is opened. A value stored in a database by someone else — `=HYPERLINK(...)`, `=cmd|...` — therefore runs on the machine of whoever opens the export. The exports and the clipboard's CSV and TSV renderings passed such values through untouched.

**Decision.** Those fields get a leading apostrophe, which every spreadsheet reads as "text follows" and hides. The guard is on by default in `ExportOptions.guardFormulas` and `ClipboardFormatter.Options.guardFormulas`, with a switch in the export sheet for someone who needs the bytes exactly as stored. JSON, SQL and Excel exports need no guard: JSON and SQL are not opened by spreadsheets, and the `.xlsx` writer emits inline strings, never formulas.

**Consequences.** Only text-typed values (strings, JSON, arrays, raw server text) are guarded; a numeric, date or boolean column is rendered by Tinker and cannot carry a formula, so `-5` in an integer column stays `-5`. A text value that legitimately starts with `-` or `+` (a Markdown bullet, a phone number written `+62…`) is exported as `'+62…` unless the switch is off.

## ADR-0033 — New connections require TLS; what a session negotiated is shown
Date: 2026-09-07

**Context.** A security review found that `tls.mode = prefer`, the default for new connections, falls back to plaintext without any sign in the UI, that TLS 1.0/1.1 were accepted, and that mysql-nio proceeds in the clear whenever a server greeting omits the SSL capability — even under `verify-full` — which an on-path attacker can arrange and then read the `caching_sha2_password` exchange.

**Decision.** A connection created in the editor starts with `require`; connections already stored keep whatever they had, since changing them behind the user's back could stop a working connection. Both drivers set `minimumTLSVersion = .tlsv12`. The MySQL driver reads `Ssl_cipher` after the handshake and refuses an unencrypted wire for any mode that requires one. Every connection reports its transport (`pg_stat_ssl`, `Ssl_cipher`/`Ssl_version`) and the status bar shows a closed or open lock with the detail as a tooltip, so a `prefer` connection that ended up in the clear is visible.

**Consequences.** A new connection to a server without TLS fails until the user lowers the mode, which is the point. Tests: `MySQLIntegrationTests.testRequiredTLSIsVerifiedAgainstTheNegotiatedCipher`, `PostgresIntegrationTests.testTransportReportsWhatTheServerSees`.

## ADR-0034 — A pooled connection is reset before it is reused; history and errors are redacted
Date: 2026-09-07

**Context.** The same review found that a pooled connection carried session state from one tab to the next (`USE`, `SET search_path`, `SET ROLE`, `foreign_key_checks`), so an import with unqualified names could land in the database a closed tab had chosen; that query history stored `CREATE USER … PASSWORD '…'` verbatim in the SQLite store; and that PostgreSQL protocol errors were rendered with `String(reflecting:)`, whose text includes the query and its bound values.

**Decision.** Drivers note statements that change session state and, when the session releases the lease, run `RESET ALL` + `RESET ROLE` (PostgreSQL, re-applying the configured statement timeout) or `USE <database>` plus the session defaults (MySQL). `SQLRedactor` masks the literal after `PASSWORD`, `IDENTIFIED … BY/AS` and `SECRET` before a statement or an error message is written to history, and the store runs with `secure_delete` on. Errors are summarised from their code and server message only.

**Consequences.** A tab that relies on `SET search_path` on its own held connection is unaffected: the reset happens on release, not while the tab holds the lease. Server-side read-only (`default_transaction_read_only`) is applied on lease, after the reset, by the session. Tests: `PostgresIntegrationTests.testSessionStateIsResetAfterASetStatement`, `MySQLIntegrationTests.testSessionStateIsResetAfterASetStatement`, `RedactionTests`.

## ADR-0035 — Dumps and `NO_BACKSLASH_ESCAPES`
Date: 2026-09-07

**Context.** `SQLLiteral` escapes MySQL string literals the way the server's default `sql_mode` reads them: `'` doubled and `\` doubled. A server or session running with `NO_BACKSLASH_ESCAPES` reads `\\` as two characters, so a dump restored there would corrupt values containing backslashes or NUL bytes. Nothing can break out of a literal either way, since `'` is always doubled.

**Decision.** Dumps state the assumption rather than switch modes: the MySQL dump header carries `-- Literals assume the default sql_mode (backslash escapes); restore with NO_BACKSLASH_ESCAPES off.` A `SET sql_mode` at the top of a dump would silently change the target session's mode for everything that follows, which is worse than a documented assumption.

**Consequences.** Restoring into a `NO_BACKSLASH_ESCAPES` session remains the user's call, and the header tells them. Import through Tinker itself runs on a fresh connection whose mode the reset in ADR-0032 puts back to the server default.

## ADR-0036 — SQLite moves into scope, over the system library, on a thread of its own
Date: 2026-09-09

**Context.** SPEC §1 listed SQLite as out of scope for v0.1. The user asked for it, with the Navicat behaviour of dropping a file on the app and having it open. SQLite has no network protocol: it is a C library that blocks the calling thread, its connections are bound to one thread at a time (`THREADSAFE=2` on macOS), and `sqlite3_interrupt` is the one call permitted from another thread. Apple ships `libsqlite3` 3.51 with column metadata, `dbstat`, JSON and FTS5 compiled in, but without ICU. Adding a SwiftPM SQLite package would have meant a second copy of the library in the process for no gain.

**Decision.** `DBSQLite` uses the system `SQLite3` module directly, the way `DBStore` already does; no new dependency. Each `SQLiteConnection` is an actor whose executor is a dedicated `Thread`, so SQLite's blocking calls never occupy the cooperative pool and every call on a handle happens on one thread. `cancelCurrent()` is nonisolated and calls `sqlite3_interrupt`, because waiting for the actor would mean waiting for the statement being cancelled. The statement timeout is a progress handler. `SQLDialect` gained `.sqlite` and the helpers `hasSchemaLayer`, `isFileBased`, `hasMultipleDatabases` and `hasUserAccounts`, so the App decides on properties rather than on `== .mysql`. SPEC §1, §2.1, §3, §7.3, §16 and §17.1 were amended.

**Consequences.** Every `switch` over the dialect is exhaustive on purpose, so a fourth engine will break the build in the right places. The fixture for SQLite is a temporary file the suites create, which makes the grid, transfer and sync suites run on every machine with no setup. Attached databases are listed but otherwise out of scope.

## ADR-0037 — What SQLite cannot do is reported, not imitated
Date: 2026-09-09

**Context.** SQLite has no exact decimal (numeric affinity keeps fifteen digits in a REAL), no `ALTER COLUMN`, no comments, no stored routines, no users, no sessions, no profiler, and its built-in `lower()`/`upper()` and `LIKE` fold ASCII only. The other two drivers promise exact decimals and server-held state, and the UI is built on those promises.

**Decision.** The driver reports what the file holds: a `DECIMAL` column arrives as `.double`, an undeclared column takes the storage class of its first value, and text in a `DATE` column that does not read as a date stays text. A column change the engine cannot express is generated as SQLite's own documented rebuild (`sqliteRebuild` in `DDLGenerator`), run inside one transaction by `DDLExecutor`, which is transactional for SQLite as it is for PostgreSQL. `lower()` and `upper()` are overridden per connection with Swift's Unicode folding, and the quick-search filter uses them on SQLite; this is what SQLite's own ICU extension does. Users, sessions, routines and the profiler are hidden or answer with a one-line message in the driver's words rather than an empty pane.

**Consequences.** A `NUMERIC(12,4)` column edited in the grid round-trips through a REAL, which is SQLite's behaviour and now visibly so. A rebuild rewrites the whole table; the preview shows every statement it is made of. Filters generated for SQLite only run on Tinker's own connections, which is the only place they run.

## ADR-0038 — A SQLite file opens as a connection, wherever it comes from
Date: 2026-09-09

**Context.** The point of SQLite support was the Navicat gesture: a file lands on the app and is usable. Tinker's model is connections in a store, with a Keychain entry for the password; a file has neither password nor host.

**Decision.** `SQLiteFileOpener` is the one path for a dropped file, a Finder open (`NSApplicationDelegate` with document types declared in `App/Info.plist`, merged into the generated plist, rank Alternate so Tinker offers itself without claiming `.db`) and File › Open SQLite Database…. A file that already has a connection reuses it; any other becomes a saved connection named after the file, selected and expanded at once. A file with a database extension but no SQLite header opens the connection editor instead, whose validation names the problem. A `.sql` file dropped alongside opens as a query tab on the active connection, as ⌘O does. The connection's `database` field is the absolute path; `host`, `port` and `user` are empty and the sidebar and status bar show the path in their place.

**Consequences.** A moved or deleted file leaves a connection that fails with `No such file: …` and the hint to choose the file again; nothing is created silently. The editor's New… button creates an empty database through SQLite itself so the header is right from the first byte.

## ADR-0039 — RSA keys sign with SHA-2; key files are read by Tinker, not Citadel
Date: 2026-09-10

**Context.** A user's `id_rsa` failed with "SSH authentication failed" against a server that accepts the same key from `ssh`. Citadel signs RSA keys only as `ssh-rsa` — PKCS#1 v1.5 over SHA-1 — and OpenSSH 8.8 (2021) and later refuse that algorithm for public-key authentication by default; they take `rsa-sha2-256` and `rsa-sha2-512` (RFC 8332). Reproduced against the machine's own `sshd` (OpenSSH 10.3): `ssh -o PubkeyAcceptedAlgorithms=ssh-rsa` is denied, `rsa-sha2-512` is accepted, and Tinker's tunnel failed exactly as reported. Every RSA key file was therefore unusable against a current server. Citadel's RSA type is also its own reader of OpenSSH key files, and it keeps the private numbers to itself, so the hash cannot be changed from outside.

**Decision.**
- `OpenSSHPrivateKey` (DBTunnel) reads key files itself: the `openssh-key-v1` container with its bcrypt KDF and AES-CTR/CBC encryption, and the PEM formats older `ssh-keygen` releases wrote (`RSA PRIVATE KEY` with OpenSSL's MD5 `DEK-Info` encryption, `EC PRIVATE KEY`, PKCS#8 `PRIVATE KEY`). Key types: RSA, ed25519, ECDSA P-256/384/521 — the last three were refused before, because Citadel had no reader for them. Not read: `chacha20-poly1305@openssh.com`- or 3DES-encrypted files, encrypted PKCS#8, and FIDO `sk-` keys; each is named in the error with the `ssh-keygen -p` command that rewrites the file.
- RSA signing goes through swift-crypto's `_CryptoExtras` (`_RSA.Signing.PrivateKey(n:e:d:p:q:)`, PKCS#1 v1.5 with SHA-512, SHA-256 or SHA-1), wrapped in `RSASSHPrivateKey<Algorithm>` for swift-nio-ssh. The algorithm name in the authentication request and the type string inside the key blob both come from the key's prefix in swift-nio-ssh, so the blob says `rsa-sha2-512` where RFC 8332 says `ssh-rsa`; OpenSSH maps both names to the same key type and accepts it (proved by the interop tests). The algorithm types are *not* registered with `NIOSSHAlgorithms`, which would also advertise them as host-key algorithms and change key exchange; that is a separate gap (a server with only an RSA host key still fails at key exchange, because Citadel's `ssh-rsa` host-key signature is what OpenSSH 8.8+ refuses there too).
- A key is offered under each algorithm it supports, strongest first: `rsa-sha2-512`, `rsa-sha2-256`, then `ssh-rsa` for servers older than OpenSSH 7.2. Citadel's `SSHAuthenticationMethod.custom` gives a delegate one turn and then fails the connection, so each attempt is a new connection (`SSHTunnelProvider.connectClient`); a server that accepts the first — every current one — costs nothing extra. The refusal message names every algorithm tried.
- `bcrypt_pbkdf` is vendored as the C target `CTinkerBcrypt` (OpenBSD's `blf.c` and `bcrypt_pbkdf.c`, BSD/ISC licences in the files; SHA-512 from CommonCrypto). swift-crypto is named as a direct dependency for `_CryptoExtras` — it was already in the graph through Citadel; `Package.resolved` is unchanged.

**Consequences.** RSA, ECDSA and ed25519 key files work against current OpenSSH, and the old PEM `id_rsa` works too. `OpenSSHInteropTests` starts the machine's own `/usr/sbin/sshd` unprivileged on a free port — no administrator rights, nothing changed on the machine — which is what SPEC §17.1 asked for and ADR-0014 could not get; the in-process Citadel server stays for the password and forwarding cases. ADR-0013's statement that ECDSA files are unsupported no longer holds. Two things stay open: RSA host keys with SHA-2 (above), and agent authentication (ADR-0013).

## ADR-0040 — Pool occupancy, unconditional rollback, and four driver corrections
Date: 2026-09-11 (review, Phase 1)

**Context.** An eight-perspective review of the codebase found, in `ConnectionSession`: a lease that indexed the pool after an `await` and crashed when a disconnect emptied it meanwhile; a release that marked a connection idle *before* rolling it back and resetting it, so a concurrent lease could receive the connection, apply the read-only guard, and have the guard wiped by the reset still in flight; a full pool that made `lease()` poll for ever; and an introspection read that released its lease in a detached task, racing the caller's next lease. In the drivers: a MySQL transaction opened by a typed `SET autocommit = 0` was invisible to the keyword tracker and was *committed* by the `SET autocommit = 1` in the session reset; PostgreSQL's SQLSTATE 57014 was always `.cancelled`, so a `statement_timeout` lost its message; class-28 errors after connect were rewritten to "Authentication failed"; `float4` widened through its bit pattern and showed `0.10000000149011612`; `money` was rendered as its minor-unit integer, which the server read back as a hundred times the amount; MySQL `BIT` bound its text `"1010"` back as the number 1010; SQLite `affectedRows` used `sqlite3_total_changes`, which counts cascades and triggers, so the grid refused a correct one-row delete; and the MySQL driver retried in the clear whenever an error message contained "ssl", "tls" or "handshake" — a downgrade an on-path attacker can trigger.

**Decision.**
- Each pooled connection carries an occupancy — idle, leased, resetting, checking — that changes only between suspension points; everything after an `await` goes back through the connection's id. `release` rolls back unconditionally (a `ROLLBACK` outside a transaction is a warning on every engine), resets, and only then marks the connection idle. `disconnect` takes the pool before its first `await`, refuses leases meanwhile, and leaves a connection with a statement in flight to the lease or release that owns it. `lease()` gives up after `leaseWaitTimeout` (15 s) with a message naming the pool size; the introspection read releases before it returns; `testConnection` restores the published state.
- SQLSTATE 57014 is `.cancelled` only when this client asked for the cancel (a flag set in `cancelCurrent`); otherwise it is `.server` with the verbatim message. SPEC §6's `.timeout` is not produced for it: the server's own words ("canceling statement due to statement timeout") say what to change, which is what §1's fourth principle asks for.
- Class 28 is a login failure only in `mapConnect`; after connect it is shown verbatim.
- `float4` and MySQL `FLOAT` widen through their shortest decimal text. `money` renders with two fractional digits and no symbol, which is what the server accepts as input; `lc_monetary` locales with other scales are not read (JPY-style locales would show a wrong scale, and are documented here rather than handled).
- MySQL `BIT` stays `.raw` for display and binds its bytes as a binary string, which MySQL reads as the bit pattern. SPEC §7.3's "BIT→bytes" is amended to this: the text form is what the grid shows, the bytes are what goes back.
- SQLite `affectedRows` is `sqlite3_changes64` after a row write; SPEC §7.3's `total_changes` clause is amended. The DDL concern it addressed is already handled by reading the count only after INSERT/UPDATE/DELETE/REPLACE.
- The MySQL driver never reconnects in the clear after a failed handshake. `prefer` still means what it says: mysql-nio proceeds without TLS when the server's greeting has no SSL capability, which is the only downgrade the mode allows.

**Consequences.** Tests: `ConnectionSessionTests` (six new: a resetting connection is not handed out, release rolls back unconditionally, disconnect during a ping refuses the lease, a full pool fails after the wait, test connection restores state, introspection releases before returning); `PostgresIntegrationTests.testStatementTimeoutKeepsTheServersMessageAndIsNotACancel` and `testFloat4AndMoneyKeepTextTheServerAccepts`; `MySQLIntegrationTests.testBitValuesRoundTripThroughParametersAndFloatKeepsItsText`; `SQLiteIntegrationTests.testAffectedRowsCountsDirectRowsNotCascadesOrTriggers`. `FakeDriver` gained ping and reset delays and a rollback count so the races are reproducible without a server.

## ADR-0041 — Keyboard shortcuts: the deviations from SPEC §10.2, and two swaps undone
Date: 2026-09-11 (review, Phase 1)

**Context.** The app's shortcuts differed from SPEC §10.2 in nine rows, none recorded. Two of them were dangerous: ⌘⌫ deleted rows where the spec, the help page's reader and TablePlus mean "set NULL" — and with auto-commit on (ADR-0031) the DELETE reached the server with no sheet and no confirmation; and ⌘⇧R ran the selection where the spec says Rollback. ⌘⇧S was registered twice (File › Commit and the table tab's button), "New Window" sent `newDocument(_:)` to an app without documents, and there was no Close Window key.

**Decision.**
- Restored to the spec: Set NULL ⌘⌫, Add Row ⌘+, Delete Selected Rows ⌘−, Rollback ⌘⇧R, Close Window ⌘⇧W.
- Kept as they were, and recorded here: Run ⌘R (the system claims ⌘↩ for the window, and Return with modifiers is what every text view keeps); Run All ⌘⌥R; Refresh F5 (the key every database tool shares, and ⌘R is taken); Export ⌘⌥E (⌘E is Explain's neighbour ⌘⇧E); Copy as INSERT ⌘⌃C. Run Selected moves from ⌘⇧R to ⌘⌃R.
- The duplicate ⌘⇧S on the table tab's Commit button is gone; File › Commit is the one registration. New Window opens the workspace scene through `openWindow`.
- Auto-commit stays on by default, as ADR-0031 chose at the user's request, but a delete under auto-commit asks first, in a sheet that names the table and the row count, on both table tabs and result grids. Sort, filter, quick search, page changes and Refresh ask before discarding pending edits; closing a tab, closing the other tabs and quitting ask when a tab holds uncommitted edits or an open transaction (SPEC §13.2). The confirmation callback is set by the workspace when it creates a controller, not by a view on appear, so a tab that has not been shown yet can still ask.

**Consequences.** The help page lists the keys as they now are. `SmokeFeaturePass` exercises the confirmation through the controller's `confirm` property. There is no unit test for the shortcut table itself: `Commands` are not observable from XCTest; the page and the code were reconciled by hand.

## ADR-0042 — The SSH transport is a fork of swift-nio-ssh, pulled in by Citadel
Date: 2026-09-11 (review, Phase 2)

**Context.** The review found that `Package.resolved` resolves `swift-nio-ssh` from `https://github.com/Wellz26/swift-nio-ssh.git` (0.3.6, revision `a05e6bbe6b141ee68da3030e00275504c0595d4d`), a personal fork of `apple/swift-nio-ssh`, because Citadel's own manifest names it. Nothing in this repository mentioned it: `Package.swift` names Citadel, and the transport underneath — key exchange, host-key verification, the cipher suite — came from a source no one here had chosen or reviewed.

**Decision.** Recorded here rather than replaced. SwiftPM cannot pin a transitive dependency from the root manifest; `Package.resolved` pins the exact revision above and is committed, so a build reproduces the audited tree. Any bump of Citadel is a bump of this fork and must be diffed against upstream `apple/swift-nio-ssh` before it is committed; the review notes go in this file. Moving to upstream is Citadel's decision, not ours, and is not attempted.

**Consequences.** Nothing changes for a user. A maintainer updating Citadel has a written obligation: read the fork's diff, record what it changes, and refuse the bump if the diff is not understood. The dependency lint in `Scripts/ci.sh` is unaffected: DBTunnel imports `NIOSSH` under either origin.

## ADR-0043 — Phase 2 of the review: the session decides about reconnecting, the grid drops stale answers, one write queue
Date: 2026-09-11 (review, Phase 2)

**Context.** After Phase 1 the architectural findings remained: SPEC §9.6's reconnect policy existed only as a doc comment (`noteConnectionDropped` had no caller, `makeConnection` no retry, and a query tab kept a dead held connection for its whole life); every query tab held a pooled connection for its lifetime whether or not it had a transaction to keep; two overlapping page loads let the later answer win regardless of which sort or filter it belonged to; `TableTabController.start()` could run twice and build two grids; twenty call sites released their lease with `defer { Task { await session.release(lease) } }`, a detached task the caller's next lease races (in `selectDatabase` the defer sat inside an inner block and released the connection *before* the `USE` ran on it); the two tab controllers each carried a copy of the single-flight write queue; `WorkspaceTab` carried seven properties nobody read; and the sidebar's state watchers were never cancelled.

**Decision.**
- `DBError.indicatesLostConnection` names the errors that mean the connection is gone. On one of them the query tab calls `noteConnectionDropped`, forgets its lease, and the next run takes a fresh one. A drop while a transaction was open sets the session waiting: `lease()` and `connect()` refuse with the reason until `reconnect()`, which only the sidebar's Reconnect item calls — nothing the app does on its own (a transfer, a dump, the query builder) can discard the user's uncommitted work for them. `makeConnection` retries once on a network-class failure and never on a server answer such as a refused password.
- A query tab releases its lease after a run when auto-commit is on and no transaction is open. Eight idle tabs no longer hold the pool.
- `GridModel` carries a load generation; a page load started before a reload drops its rows when they arrive.
- `TableTabController.start()` is single-flight.
- `ConnectionSession.withLease` leases for the duration of a body and releases before returning, on the caller's actor. The package call sites and the query tab's use it; the remaining app sites keep the detached form, which is now harmless for correctness (a released connection is marked resetting until its reset finishes, ADR-0040) and costs at most one extra connection.
- `GridWriteQueue` (DBGrid) is the one single-flight write gate; both controllers own one and pass in what differs (which grid, how a commit runs, how the page is re-read). `GridEditPrompts` words the delete and discard questions once. `EditBuffer.removeEmptyInserts()` replaces two copies of the same loop.
- `WorkspaceTab` keeps `sql` and `autoCommit`; the rest lives on the controllers. The sidebar cancels watchers for connections that no longer exist.
- `WITH … INSERT/UPDATE/DELETE` without RETURNING takes the collecting path on PostgreSQL, so its affected-row count is the server's.
- SPEC §2.1, §7.3, §10.2 and §16 are amended in place with a pointer to the ADR that changed them, so the spec no longer names tree-sitter, `PostgresClient`, or "deferred" features that ship.

**Not done, and why.** `EditBuffer` is still keyed by row index. Keying it by row identity would let edits survive a reload; the Phase 1 guards ask before every reload that would discard them, which removes the loss, and re-keying touches `RowBuffer`, `GridModel` and every grid view's row addressing for a smaller gain. Deferred, not forgotten.

**Consequences.** Tests: `ConnectionSessionTests` (+4: lost transaction waits for the user, drop without a transaction reconnects with one retry, authentication failure is not retried, `withLease` releases on return and on throw), `GridModelTests.testAStaleLoadDoesNotOverwriteANewerOne`, `GridWriteQueueTests` (4), `PostgresIntegrationTests.testWithPrefixedDMLReportsTheServersAffectedRowCount`.

## ADR-0044 — Phase 3 of the review: back-pressure, keepalive, measured performance, fault injection
Date: 2026-09-11 (review, Phase 3)

**Context.** The review's performance and reliability findings: every driver yielded into an unbounded `AsyncThrowingStream`, so a slow consumer turned a million-row result into a million rows in memory whatever the batch size said; nothing pinged idle connections and `ping()` had no deadline, so a socket that died while the machine slept stalled every lease for as long as TCP took to notice; a cancel could land on the statement *after* the one it was meant for, because opening the helper connection took longer than the statement had left; SPEC §12.6 was checked by wall clock, not `XCTMetric`; no test terminated a backend mid-query; the dump read each table under its own snapshot; the SQL editor re-tokenized the whole document on every keystroke, copied the whole buffer on every caret move, and walked every line from the first on every gutter frame; the export sheet wrote the file on the main actor; and a MySQL zero date decoded as NULL.

**Decision.**
- `QueryEventChannel` (DBCore): a bounded, single-producer/single-consumer hand-off of `QueryEvent`s, four batches deep. `send` waits when it is full; on PostgreSQL that wait reaches the socket through `PostgresRowSequence`, on SQLite it parks the statement between two `step`s on the connection's own thread. The consumer's stream is `AsyncThrowingStream(unfolding:)` over `next()`. A consumer that leaves the loop — the grid's memory cap, a thrown error — drops the stream; the pull closure owns a lifetime object whose `deinit` cancels the channel and the statement, since the throwing stream has no callback of its own for that. Nothing is cancelled when the producer had already finished. **MySQL keeps its unbounded buffer**: mysql-nio delivers rows through a synchronous callback on the event loop and exposes no way to stop reading; true back-pressure there needs a change in mysql-nio, and pretending otherwise would be worse than saying so. Its `SELECT`s in query tabs are paged server-side, which bounds the common case.
- `ConnectionSession` pings idle connections every `keepaliveInterval` (60 s) on a task it owns and cancels; `ping()` is bounded by `pingTimeout` (5 s), after which the connection is dropped and the hung ping abandoned rather than awaited. Both intervals are injectable, so the tests run them in milliseconds.
- PostgreSQL and MySQL count statements; a cancel that finds a newer statement running when its helper connection is ready is dropped. Not observable in a deterministic test — the window is the helper connect time — so it is covered by reasoning and by the existing cancel tests still passing.
- `GridModel` emits `page load` signposts; `GridPerformanceTests` measure the first page with `XCTClockMetric` and `XCTOSSignpostMetric` and fifty pages with `XCTMemoryMetric`, and hold the §12.6 500 ms bound as an assertion. Main-thread hitching in the real `NSTableView` is still not measured: that needs an app-hosted test, listed under Phase 5.
- Fault injection: `pg_terminate_backend` and `KILL CONNECTION` from a second session, mid-statement and between statements. The mid-statement MySQL case is skipped in Debug builds: mysql-nio `assert`s "Statement not closed" in `MySQLQueryCommand`'s deinit when the connection dies under a prepared statement, which aborts a Debug test process and is compiled out of the Release build the app ships as.
- The dump's data phase reads under one read-only snapshot (`REPEATABLE READ` / `WITH CONSISTENT SNAPSHOT` / a deferred `BEGIN`), committed at the end; a table's foreign keys failing to read fails the dump instead of silently misordering it.
- The editor highlights documents over 200,000 UTF-16 units in a window around the visible text and re-highlights on scroll; bracket matching reads the `NSString` in place, scans at most 20,000 units, and clears only the two cells it marked; the gutter keeps a line-start table and starts drawing at the first visible line. The elapsed-time label is a view of its own, so the timer no longer re-renders the tab and its editor bridge ten times a second; the grid's `updateNSView` redraws visible cells only when the selection changed.
- `ExportWriter` (DBGrid) is an actor around `RowExporter`; the export sheet awaits it between batches, so encoding and file writes happen off the main actor and the driver's channel, not the process, holds what the file has not taken yet.
- A MySQL zero date decodes as `.raw` with its text (`0000-00-00`, `0000-00-00 00:00:00`), which the same permissive `sql_mode` accepts back; it was NULL.

**Consequences.** Tests: `QueryEventChannelTests` (7), `ConnectionSessionTests` (+2: a hung ping is abandoned and the connection replaced, keepalive drops a dead idle connection), `PostgresIntegrationTests` (+3: a slow consumer of two million rows grows resident memory by less than 96 MB; leaving the stream early frees the connection at once; a terminated backend is reported as a lost connection), `MySQLIntegrationTests` (`KILL` proven through `information_schema.processlist`; the killed-statement test on a cross join that cannot finish first; `testAKilledConnectionIsReportedAsLost`, Release-only; zero dates), `GridIntegrationTests` (+2: a killed backend is replaced on the next lease; awkward text and `1.1000` survive the grid's INSERT and UPDATE), `GridPerformanceTests` (2), `ScriptTransferIntegrationTests.testADumpReadsEveryTableFromOneSnapshot`. The editor and export changes have no automated test; they are the kind of thing Phase 5's app-hosted measurements are for.

## ADR-0045 — Phase 4 of the review: a log that exists, passwords out of argv, documents that match the code
Date: 2026-09-11 (review, Phase 4)

**Context.** swift-log's default handler prints to standard output, which a Finder-launched app discards, so nothing any package logged ever reached a place a person could read, and a bug report had nothing to attach. `dbcli` took the database password in the URL and the SSH password on the command line, visible in `ps` and the shell history. `DBError.connectionFailed` carried no endpoint, so "connection refused" did not say which of five hosts refused, and `testConnection` rendered foreign errors with `String(reflecting:)`, whose text can include the request. `README.md` named Xcode 16 for a `swift-tools-version: 6.2` manifest, `Scripts/appbuild.sh` and `release.sh`'s flags were documented nowhere, `testenv/README.md` said `sshd` interop was not covered (it has been since ADR-0039) and, with SPEC §17.1, named two `TINKER_TEST_SSH_*` variables nothing reads. `release.sh` stamped the build number from the clock, so the shipped build never matched the project's; `CHANGELOG.md` had no `[0.1.1]` section for the version that was bumped. The SSH editor offered agent authentication, which ADR-0013 says does not work. Fourteen app call sites still released their lease on a detached task.

**Decision.**
- `AppLogging.bootstrap()` runs first in `TinkerApp.init` and installs `OSLogHandler`: each swift-log record goes to the unified log under subsystem `com.thinkfree.Tinker` with the label as category (`privacy: .public`, since the text is the app's own words and a `<private>` record is no use in a report), and the last 400 records at `.info` and above stay in memory. Settings › Diagnostics › **Copy Diagnostics** puts the app and system versions, the engines configured (counts, no hosts), the log subsystem and those records on the clipboard. Nothing above `.debug` carries SQL, values or credentials (SPEC §18 rule 4); `dbcli --verbose` says so in its usage, since it turns `.debug` on.
- `dbcli` reads the database password from `PGPASSWORD`, `MYSQL_PWD` or `TINKER_DB_PASSWORD` when the URL has none, and the SSH password from `TINKER_SSH_PASSWORD`; the argv forms still work and the usage says why not to use them.
- `makeConnection` prefixes the endpoint (`host:port`, or the file) to a connection-class failure's message; `testConnection` uses `String(describing:)`.
- `README.md`: Xcode 26, the CLI clients `prepare.sh` needs, a table of the scripts and their flags, `TINKER_TEST_SQLITE_DISABLED`, where the log is. `testenv/README.md` and SPEC §17.1 describe the two SSH servers the tests actually start and drop the unread variables. `release.sh` reads `CURRENT_PROJECT_VERSION` from the project and refuses to archive without a `## [VERSION]` section in `CHANGELOG.md`; the changelog gains `[0.1.1]` for what shipped and an `[Unreleased]` entry for the review. The SSH editor lists Agent only for a stored connection that already chose it, labelled "not available".
- Ten of the fourteen detached-release sites now use `withLease` (the smoke pass, the query builder, the table operation sheet and its importer, the sidebar's DDL, server activity's reads and user statements). `StructureController.load` and `TransferModel`'s dump keep the detached form: their bodies span several dozen lines and other awaits, and the form is correct since ADR-0040; they are noted rather than rewritten under time.
- `Scripts/ci.sh` keeps its `touch` of first-party sources (ADR-0005): the alternative — `-warnings-as-errors` as an unsafe flag in `Package.swift` — would make the packages unusable from the Xcode project.

**Consequences.** `DBCoreTests` and the app build cover the code paths; the logging handler has no unit test (the app target has none), and is exercised by every run of the app and the smoke test.

## ADR-0046 — Phase 5 of the review: undo, first contact with an SSH host, what the lock means, the grid's voice
Date: 2026-09-11 (review, Phase 5)

**Context.** The product findings left after Phases 1–4: no undo below "Discard all", so one wrong cell meant losing every pending edit; `accept-new` trusted an unknown SSH host silently and appended its key to the user's own `~/.ssh/known_hosts`, so a man-in-the-middle at Tinker's first contact also decided what the user's `ssh` would trust from then on, and a key recorded for `host:22` vouched for any port of the host; the status bar's closed lock read the same for `require` (encrypted, anyone at the other end) as for `verify-full`; VoiceOver got a cell's text with no column, no selection and no way to tell NULL from the word "NULL"; and chip and badge sizes were literals scattered through views.

**Decision.**
- `GridModel` records every change to its `EditBuffer` — whoever makes it, since the buffer is a property with `didSet` — two hundred deep, with redo; a commit or a reload forgets the history, because what they leave is not undoable. The grid's table view answers Edit › Undo and Redo itself through the delegate (`gridDidRequestUndo`/`Redo`, validated by `gridCanUndo`/`Redo`) rather than through an `NSUndoManager` whose registrations would have to mirror every edit path. Refused while a write is on the server.
- `HostKeyTrust` (DBTunnel) says where keys are read, where a new one is recorded, and who is asked. The app reads the user's `~/.ssh/known_hosts` *and* its own `Application Support/Tinker/known_hosts`, records only to its own, and asks with the `SHA256:` fingerprint in a sheet before trusting; a refusal fails the tunnel with the fingerprint in the message; a headless run refuses. `dbcli` and the tests keep the old behaviour through `HostKeyTrust.openSSHDefault`. A `known_hosts` entry now matches only its own port, as OpenSSH does. The `ignore` policy still refuses a key marked `@revoked`.
- `TransportSummary` carries whether the TLS mode verifies the certificate; the status bar shows "Encrypted, unverified" in orange with a warning badge for `prefer` and `require`, and the tooltip says what to choose instead.
- Each grid cell tells accessibility its column as the label, its value with NULL, "not loaded" and binary spelled out, its edited/new/deleted state, and whether it is selected or focused.
- `DesignTokens.Typography` is the type ramp; `Scripts/ci.sh` refuses a `.system(size: <number>)` in a view.

**Not done, and why.** A review sheet before a cross-server paste (the transfer executes DDL rebuilt from the source's catalog on the target, so a hostile default expression on the source runs on the target): the paste streams the dump straight into the executor, and a review means buffering the structure phase and re-plumbing the wizard; deferred with the threat named — it needs DDL rights on the source. One pane per result set for statements that return several (SPEC §13.2a): the second `.columns` event still replaces the first grid; needs a result model that holds several grids and a picker. The three-way memory-cap banner (Load more / Export / Cancel): the stream is stopped on the server at the cap, so "Load more" would be a re-run with an offset; the banner offers Export. An app-hosted performance target for main-thread hitching in the real `NSTableView`, and a unit-test target for the app's own types (logging, diagnostics, prompts). Each is listed in PROGRESS.md as open.

**Consequences.** Tests: `GridModelTests.testUndoAndRedoWalkTheEditsOneChangeAtATime`; `TunnelIntegrationTests.testAcceptNewAsksBeforeTrustingAndRecordsToTheProvidersOwnFile` (refuse, accept and record to the provider's file, no question the second time); the `known_hosts` port test already pinned the bracket form. The status-bar label, the accessibility attributes and the typography lint are checked by the build and by hand.

## ADR-0047 — Finishing what the review phases deferred: edits that follow their row, back-pressure on MySQL, cancels that wait, the paste review, several result sets, the cap banner, app-hosted tests
Date: 2026-09-11 (review, follow-up)

**Context.** ADR-0040 to ADR-0046 each named things left open. Together: pending edits were keyed by row *index*, so a reload that moved rows put an edit on the wrong row and the app guarded against it by discarding edits before any reload; MySQL results were not under back-pressure (mysql-nio hands rows to a callback on its event loop, which cannot wait); a cancel from a dropped stream could land on the *next* statement of the connection when the first had ended meanwhile; a cross-server paste executed DDL rebuilt from the source's catalog on the target with nobody reading it; a batch that returned several result sets showed only the last; the memory-cap banner offered no "Load more"; several call sites still used the detached lease/release form; the app target had no unit-test target and the real `NSTableView` had never been measured; a killed MySQL connection was only tested by hand because mysql-nio asserts in Debug.

**Decision.**
- `EditBuffer` is keyed by `RowIdentity` — the row's primary-key values (or the whole row without a key) — not by index. `GridModel.reload` keeps edits and undo history; an edit follows its row across a sort or a page move, and a row that is gone keeps its edit until the user discards it. The "discard pending edits before reload" prompt is gone with the reason for it.
- `QueryEventChannel` is a lock-based class with a non-suspending `offer` and an `onDemand` hook. The MySQL driver's `RowBatcher` offers batches from the event loop and turns the socket's `autoRead` off when the channel is full; `onDemand` turns it on again and reads. TCP does the rest: a slow consumer is a slow server.
- A statement waits for any cancel on its way before it starts (`waitForCancelsToLand`), on PostgreSQL and MySQL; the cancel is counted (`AtomicCounter`) the moment a stream is dropped, before the hop onto the actor, so nothing can start in the gap. `BEGIN`/`COMMIT`/`ROLLBACK` wait too. The MySQL kill connection is opened once even when two cancels race (the second closes its own).
- A dump's snapshot transaction is rolled back by the dump itself on every exit — cancelled, refused at review, failed — so the connection is usable again without a trip through the pool; SQLite refuses a `BEGIN` inside a transaction.
- `TransferRunner.run(review:)` buffers the structure phase — every chunk until the first `INSERT` or `COPY` — and asks before forwarding it to the executor; a refusal throws `DeclinedAtReview` with nothing written. The app shows the statements in the workspace's confirmation sheet; a headless run refuses.
- `QueryResultTab` holds `grids` and `shownGridIndex`; every `.columns` event after the first opens a new grid; the SQLite driver reports each row-returning statement of a batch as its own result set. A picker above the grid switches.
- The memory cap is a prompt with three answers: `loadMore` raises `RowBuffer.rowCapacity` by 200,000 and the stream continues (the row batches were never dropped, only parked); `exportRest(URL)` hands the remaining batches to `ExportWriter` and stops the grid; `stop` cancels. Cancelling the tab resolves a pending prompt.
- A zoned time (`timetz`) has no MySQL or SQLite column that keeps its offset: it crosses as text (`varchar(32)` / `TEXT`) with the server's spelling, never through `TIME`.
- `TinkerTests` is a unit-test bundle hosted by the app (`BUNDLE_LOADER`/`TEST_HOST`); it compiles against the host's modules and links no package product itself, because a test bundle that links the same products makes Xcode build every package as a dynamic framework, and swift-crypto's product framework comes out without a binary. Its `DataGridPerformanceTests` host `DataGridView` in a window over a 100,000 × 20 in-memory result and time a revision reload and forty scroll stops against one frame. Run by `Scripts/ci.sh` after the app build.
- What that measurement found and changed: a grid cell was an `NSView` hosting an `NSTextField` under three Auto Layout constraints; a screen of them cost 165 ms to make on a reload and 26 ms per scroll stop (Release). The cell now draws its text itself with cached attributes and no layer of its own (8 ms per stop), and a revision reload with the same columns notes the row count and reloads the prepared rows instead of `reloadData` (8 ms instead of 21). The `TinkerUITests` product was named `Tinker`, which collided with the app's module once the test action built it; it is `TinkerUITests` now.
- `Scripts/ci.sh` runs the one MySQL kill test in a Release build (with `-enable-testing`, for the suites' `@testable` imports) when a MySQL URL is set, since mysql-nio asserts in Debug on the killed channel. Its first run found that a connection killed under a statement over TLS surfaced as `protocolError("NIOSSL.NIOSSLError.uncleanShutdown")` — not a lost connection, so the session would not have replaced it. The MySQL mapper now reads `uncleanShutdown`, `ioOnClosedChannel` and an `IOError` as the connection being gone.

**Consequences.** Tests: `BufferTests`/`CommitAndModelTests` on identities (`testEditsFollowTheirRowAcrossAReload`, undo across reload); `QueryEventChannelTests` (offer, demand, cancel, drop); `MySQLIntegrationTests.testASlowConsumerDoesNotAccumulateTheResultInMemory`; `testACancelThatArrivesAfterItsStatementEndedDoesNotHitTheNextOne` on PostgreSQL and MySQL; `SQLiteIntegrationTests.testEveryRowReturningStatementInABatchIsItsOwnResultSet`; `ScriptTransferIntegrationTests.testATransferShowsItsStructureBeforeRunningAnyOfIt`; `SyncIntegrationTests.testAllTypesTransfersAcrossEngines`; `SchemaTranslatorTests` for the zoned time; `TinkerTests.AppHelperTests` (logging buffer, diagnostics text, prompts, host-key trust, result tabs) and `DataGridPerformanceTests`. The cross-engine fidelity test is what caught the `timetz` case.

## ADR-0048 — Scheduled events: a MySQL-only object, and a scheduler that says whether it will ever run
Date: 2026-09-17

**Context.** Navicat shows an "Events" node beside Tables, Views, Functions and Procedures. It is not a Navicat feature: it is the MySQL event scheduler, so a schedule set there keeps running with the client closed and the laptop off, because the server runs it. The user asked for the same in Tinker, and for the app to say whether the server's scheduler is actually on — MySQL stores an event whose scheduler is off without complaint and then never fires it, which is the failure this feature exists to prevent. Events were in no phase of SPEC; the user mandated them as new scope, and SPEC §8 and §11.5 now carry them.

**Decision.**
- The node is gated on a new `SQLDialect.hasScheduledEvents`, not on `== .mysql` at call sites. PostgreSQL has no built-in scheduler (pg_cron is an extension) and SQLite has no server, so neither shows the folder, the Objects segment or the "New Event…" item.
- `EventInfo` mirrors `information_schema.EVENTS` and keeps every timestamp as the **server's own text**. A schedule is meaningful only in the server's time zone; a `Date` here would reinterpret it in the Mac's. The editor shows that zone beside the schedule fields.
- `events(in:)`, `eventDefinition(in:name:)` and `schedulerState()` are declared on `ServerIntrospector` **and** given defaults in an extension. Declaring them only in the extension would statically dispatch to the default through the existential, so MySQL's implementation would never run and the folder would always be empty — no compiler error, just silence. The extension is what keeps PostgreSQL and SQLite from having to answer.
- DDL generation lives in `DBSQL.EventOperations`, beside `UserOperations`, because `ci.sh`'s dependency lint keeps generators out of drivers and `GeneratedDDL.table` is non-optional, so `DDLGenerator` cannot describe a schema-scoped object. `DEFINER` is never written: setting one needs `SUPER`, so an ordinary account would be refused. An edit is an `ALTER EVENT`, rename included, not a drop and recreate, so a failed second half cannot lose the event.
- The statement is sent whole on a leased connection, never through `StatementSplitter`: an event body may hold semicolons and MySQL's splitter has no `BEGIN … END` tracking. For the same reason "New Event…" opens the editor rather than a query tab holding a skeleton, which is how new functions and procedures work.
- `event_scheduler` is modelled as three states, not a boolean: `on`, `off`, `disabled`. `DISABLED` is fixed at server start and no statement can move it, so that case offers no Enable button and says the server has to be restarted. Enabling uses `SET PERSIST` on MySQL 8.0+ so the change survives a restart, and `SET GLOBAL` elsewhere, where the person is told it will not. Enabling is a whole-server write and goes through `ProductionGate`.
- The state is shown in three places: the sidebar folder's subtitle, above the Objects tab's event section, and as a banner in the editor **before** anything is saved. A refusal is shown verbatim, which is what names the privilege to ask a DBA for.
- The editor edits in place, departing from `SourceView`'s convention of punting view and routine edits to a query tab, for the splitter reason above. SPEC §11.5 records this so it is a stated rule rather than a deviation.

**A driver bug this uncovered.** `SET GLOBAL` and `SET PERSIST` fail to go through mysql-nio's prepared-statement path on MySQL 9.x: the `COM_STMT_PREPARE` response will not decode and throws `COM_STMT_PREPARE_OK.Error.missingNumParams`, so the caller saw `Protocol error: … missingNumParams` instead of `Access denied; you need … SUPER or SYSTEM_VARIABLES_ADMIN`. `MySQLSQLConnection.isUnsupportedByPreparedProtocol` now treats that one decode failure — `missingNumParams`, a short prepare-OK packet — as "retry over the text protocol", alongside MySQL's own 1295. Nothing has executed at that point, so the retry repeats no work. The other `COM_STMT_PREPARE_OK` errors are deliberately **not** retried: `missingStatus` is what an ERR packet decodes to, and retrying those both hides the server's answer and changes when a statement actually reaches the server — a first attempt at the broad version made a transfer's transaction-control statements run where they previously failed client-side, and broke `ScriptTransferIntegrationTests`. It fixes every administrative statement, not just events.

**Consequences.** Tests: `DBSQLTests.EventOperationsTests` (15, no server) covering rendering, quote injection through names, comments and timestamps, interval validation for simple and compound units, the absent `DEFINER`, and the refusal on PostgreSQL and SQLite; `MySQLIntegrationTests` create → list → enable → drop against the local server, with the event always `DISABLE`d, `ON COMPLETION PRESERVE` and starting in 2099 so the developer's running scheduler cannot fire it, plus a scheduler-state read and a refused-verbatim test that is deterministic because `tinker_test` lacks the privilege; `TinkerTests.EventEditorControllerTests` (7) for the form's statement, its validation messages, the wording of each scheduler state and the already-past hint. Demo scenes `events`, `events-off`, `events-disabled` and `events-tree`; the forced state is read only while `--ui-demo` is present, so a stale key cannot put a false warning on a real server. The whole MySQL suite now runs against MariaDB 11.8 as well as MySQL 9.4 (`TINKER_TEST_MYSQL_URLS`), and MariaDB is where the scheduler-off path is exercised against a real server rather than an injected state — its default is `OFF`, MySQL's has been `ON` since 8.0. Known gap: events are not yet carried by the dump or the transfer.


## ADR-0049 — Imports that stand on their own, and a second MySQL-family server in the test matrix
Date: 2026-09-17

**Context.** `DBPostgres`, `DBMySQL` and `DBTunnel` imported `NIOCore`, `NIOPosix`, `NIOConcurrencyHelpers`, `NIOSSL`, `NIOSSH` and `Crypto` without declaring any of them; every target but `DBCore` imported `Logging` the same way. They compiled because SwiftPM leaks a dependency's own dependencies onto the module search path. That works until postgres-nio, mysql-nio or Citadel changes what it depends on, at which point first-party code stops compiling for a reason that has nothing to do with it. Separately, MariaDB had never been in the test matrix, so the `mysql_native_password` path and every MariaDB catalog difference were untested.

**Decision.**
- `swift-nio`, `swift-nio-ssl` and `swift-nio-ssh` are declared in `Package.swift`, and every target that imports a module now names it. No package is new to the graph — `Package.resolved` is unchanged by the edit — so this adds declarations, not dependencies.
- `swift-nio-ssh` is declared at the fork Citadel pins (`Wellz26/swift-nio-ssh`, `0.3.4 ..< 0.4.0`). Two URLs for one package identity cannot resolve, so pointing at `apple/swift-nio-ssh` would break the graph. That the SSH stack rides on a third-party fork is Citadel's choice and remains a risk worth knowing about.
- `testenv/prepare.sh` takes an optional `TINKER_TEST_MARIADB_ADMIN_URL` and prepares a second MySQL-family server, exporting it as `TINKER_TEST_MYSQL_URLS`. A `mariadb://` URL uses the MariaDB client, because MySQL 9's client cannot load `mysql_native_password` and a MariaDB server still offers it. It also creates `'tinker_test'@'localhost'` beside `'tinker_test'@'%'`: a MariaDB install keeps anonymous `''@'localhost'` rows and matches the most specific host first, so a `'%'` account alone is never reached from localhost.
- Three fixture differences were made portable rather than forked: `CAST(… AS JSON)` is gone (MariaDB has no JSON cast), the nested-JSON depth is 30 rather than 50 (MariaDB's `json_valid()` stops at 31), and the recursion cap is set per flavour by `prepare.sh` (`cte_max_recursion_depth` on MySQL, `max_recursive_iterations` on MariaDB) since neither server knows the other's name. `GEOMETRY SRID n` is stripped for MariaDB, which has no column-level SRID.

**A race the second server made visible.** `DBGridTests` intermittently failed one test — a transfer declined at review, then immediately repeated on the same source lease, hitting `cannot start a transaction within a transaction` on SQLite. The dump's snapshot transaction is rolled back by the dumper on its way out, but `TransferRunner` cancelled the task group and threw `DeclinedAtReview` **without waiting for it**, so the caller could start the next dump first. `TransferRunner` now drains the cancelled group before rethrowing, and `SQLiteConnection.resetSessionState` rolls back a transaction left open by a lease, the way `RESET ALL` does for PostgreSQL. The cross-engine and grid suites were also scoped to one server per engine, since a second MySQL-family server there multiplies pairings without testing anything the driver suites do not. The failure was seen once before MariaDB was configured, so the race predates it; it is rarer now but not proven gone, and it is recorded here rather than called fixed.

**Consequences.** The whole `DBMySQLTests` suite runs green against MySQL 9.4 and MariaDB 11.8. Three assertions became flavour-aware and record real differences rather than hiding them: MariaDB reports a JSON column as text, because its JSON *is* `LONGTEXT` under a `json_valid()` check; and MySQL reorders the axes of a geographic SRID while MariaDB stores the order it was given, so identical WKT produces bytes that read back transposed — which means **Tinker's map pane plots a MariaDB geometry at swapped coordinates unless the author wrote longitude first**. Nothing in the bytes says which convention was used, so this is reported here rather than guessed at in the parser.

## ADR-0050 — A winged database for the app icon, engine marks drawn from the real logos, and a rollback that survives cancellation
Date: 2026-09-17

**Context.** Three things the user judged by eye and one they judged by a red suite. The app icon was a lit light bulb (ADR-0031), which said nothing about databases. The engine badges were hand-drawn silhouettes that read as a mushroom, a fish and a leaf rather than Slonik, Sakila and SQLite's feather, and MySQL and MariaDB shared one. Database rows in the sidebar drew `internaldrive` — literally a hard disk — by a raw symbol name, against the rule that no view names a symbol directly. And `DBGridTests` failed one transfer test in roughly three runs out of four.

**Decision.**
- The icon is a winged database: the open top rim of a cylinder, two wings of three blades a side, and two banded rings, on a light plate with one navy-to-teal gradient carrying the whole mark. `translucency` and `specular` are off in `icon.json`, because Icon Composer's frosted-glass treatment derives the layer from its luminance and throws the artwork's own colours away.
- The engine marks were redrawn from the real logos. What made the elephant work was not more detail but **separation**: Slonik's ears are held off the head by white lines, so the mark is three disjoint shapes and the plate shows through between them. Five earlier attempts drew one connected silhouette and every one of them read as a mushroom.
- MariaDB gets its own sea lion on a navy plate. `SQLDialect` cannot tell it from MySQL, so `SidebarModel` records each connection's `ServerFlavor` once the session reports connected and hands it to `EngineMark`. Everywhere without a live session keeps the MySQL dolphin.
- `Icon.database` is `cylinder.split.1x2` — the banded cylinder, not a drive — and the four raw symbol names left in `SidebarModel` now go through the token catalogue.

**The flake, and what it actually was.** A transfer declined at review, then repeated on the same leases, hit `cannot start a transaction within a transaction` on SQLite. Tracing the real transaction calls showed the first dump's `ROLLBACK` being issued on the right connection and the next `BEGIN` still being refused: the rollback ran **inside the task that had just been cancelled**, where cancelling a statement interrupts the SQLite connection, so the rollback was refused and `try?` swallowed it. `SQLConnection.rollbackForCleanup()` now runs the statement in an unstructured task — which does not inherit cancellation — and checks `isInTransaction` rather than assuming, retrying once. `DatabaseDump`, `ScriptExecutor` and `ConnectionSession.release` all use it. Two smaller holes were closed on the way: the dump's snapshot `BEGIN` sat outside its own `do/catch`, so a cancellation landing while it was in flight left the transaction open, and the executor's `ScriptExecutionError` path skipped the rollback its two sibling paths perform.

**Consequences.** `DBGridTests` ran clean five times in a row where it had been failing about three runs in four. `TinkerTests.GridInsertTypingTests` covers the grid rule added alongside: a row being added opens each cell for typing as the focus lands on it — no double-click — and Tab commits, moves and carries on, while an existing row still waits to be asked. The cross-engine, grid and DDL suites take one server per engine via `TestEnvironment.primaryServer(for:)`; the driver suites keep every server, which is where MariaDB earns its coverage.

## ADR-0051 — What a cross-engine translation loses, said out loud, and four things it got wrong
Date: 2026-09-17

**Context.** Data Transfer, Data Synchronization and Structure Synchronization all cross engines, and all three funnel their DDL through `SchemaTranslator`, which maps a source type to a canonical type and renders the target's nearest equivalent. The translation already reported what it could not carry — defaults, generated expressions, FULLTEXT/SPATIAL/GIN indexes, partial indexes, triggers, partitioning — but said nothing about the types themselves, which is where most of the loss actually happens. A reading of the whole path also turned up four outright defects.

**Decision.**
- `SchemaTranslator` now reports a lossy *type* conversion by name: `lostInTranslation` renders the type for the target, reads the result back as a canonical type, and notes the column when the kind changed. A zone dropped from a `timestamptz`, an array flattened to `json`, a geometry or a `tsvector` becoming `text`, an `interval` becoming `varchar` — each is named rather than discovered from the data afterwards. Narrowing inside one kind is deliberate and stays quiet, and so does an exact widening: PostgreSQL has no unsigned types and SQLite has one integer, so `int unsigned` → `bigint` and `smallint` → `INTEGER` hold every value and saying so each time would bury the notes that matter.
- **A boolean default crossed as a number.** MySQL writes a `tinyint(1)` default as `1`, and `translateDefault` never saw the column's type, so PostgreSQL was handed `boolean DEFAULT 1` and refused the whole `CREATE TABLE`. It now takes `columnType:` and renders a boolean default as the target's own truth literal.
- **A COPY'd array did not quote its elements.** `DatabaseDumper.copyText` fell through to the display rendering, so an element holding a comma, a brace, a quote, whitespace or the text `NULL` was written bare and `COPY` split it in the wrong place — on a same-engine PostgreSQL dump as much as a crossing one, since `DumpOptions.preferred(for: .postgresql)` is `.copy`. The quoting rule now lives once, in `SQLLiteral.postgresArray`, and both the dump and `PostgresParameterEncoder` use it.
- **Structure Synchronization threw the notes away.** `SchemaSynchronizer` read `.definition` and ignored `.notes`, so a lossy sync looked like a clean one. `SchemaSyncResult` carries them and the Tools wizard shows them above the script.
- **An unconstrained `numeric` collapsed to `decimal(10,0)`** on a MySQL target — every fractional digit gone and an overflow past ten digits. It takes MySQL's widest, `decimal(65,30)`, instead.

**Consequences.** Tests: `SchemaTranslatorTests` gains the lossy-note cases (zoned timestamp, array, interval, inet, SQLite enum), the "narrowing is not reported" case, and the boolean-default case; `ScriptStreamTests` gains the COPY array quoting. Known and deliberate: the translator has no failure path — an unmapped type becomes `text` and is noted, never refused — so a type the target genuinely cannot hold still surfaces as a server error when the statement runs. Data Synchronization compares and writes values through bound parameters and applies no type mapping at all; it is for two tables that already have compatible shapes, which is what `SchemaTranslator.comparable` normalises before the comparison.


## ADR-0052 — The designer offers the types the database itself declares
Date: 2026-09-17

**Context.** `ColumnTypeCatalog` is a fixed list per engine — 32 entries for MySQL, 31 for PostgreSQL, 14 for SQLite — and the Structure designer's type pop-up draws from it. A type the database's own users declared is not in it. An existing column keeps its type, because the picker puts an unknown base at the top of the menu as itself rather than rewriting it, but a **new** column could not be given one: the pop-up takes no typed text, so a PostgreSQL enum like the fixture's `mood` was unreachable from the designer and had to be written as SQL.

**Decision.** `SchemaIntrospector` gains `userTypes(in schema:)`, returning `UserTypeInfo` — name, kind (`enumeration`, `domain`, `composite`) and, for an enum, its labels in `enumsortorder`, which is the order the type compares in. It is a declared requirement with a defaulted extension returning `[]`, so MySQL and SQLite say nothing and only PostgreSQL implements it; declaring it in the protocol rather than only in the extension is what keeps the driver's own implementation reachable through the existential.

The PostgreSQL query reads `pg_type` for `typtype IN ('e','d','c')` in the schema, and excludes two things that would otherwise flood the list: every table's implicit row type (`typrelid` pointing at a relation whose `relkind` is not `c`) and array element types. On the fixture schema it returns exactly one row, `mood` with `sad, ok, happy`.

`StructureController` reads them once per table, beside the collations but from the tab's own `.task` rather than the detail panel's, because the type pop-up is on every row and not only on a selected column. The picker lists them above the built-in choices, and a base that matches one is no longer treated as unknown.

**Consequences.** `PostgresIntegrationTests.testUserDeclaredTypesAreReadFromTheCatalogue` asserts the enum, its label order, and that table row types are not offered. Verified in the app: with the designer in Edit mode on `tinker_test.public.all_types`, the type pop-up opens with `mood` at the top, above `smallint`. Domains and composites are read and offered too, though only enums have labels to show. MySQL and MariaDB have no user-defined types and SQLite has none, so their lists are unchanged.

## ADR-0053 — Collation across engines, a Chart pane, a splitter that turns, and Beautify on a selection
Date: 2026-09-17

**Context.** Four things at once: what a transfer does with a character set, and three places a competitor's feature list was ahead of us. Of the four claims checked — instant autocomplete, syntax highlighting, split panes, SQL reformatter — the first two were already present and richer than claimed (as-you-type completion with fuzzy matching, alias-aware qualification and a per-dialect function catalogue; dialect-aware highlighting that knows MySQL backticks, PostgreSQL dollar quoting and nested comments). The other two were partial.

**Decision.**
- **Collation travels within one engine family and is named when it cannot.** MySQL and MariaDB share a dialect, so `SchemaTranslator` already carried the character set and collation between them — but carrying them blind is a hazard: MariaDB reads MySQL's `utf8mb4_0900_ai_ci`, while MySQL refuses MariaDB's `utf8mb4_uca1400_ai_ci` with `ERROR 1273`. `translate` now takes `targetCollations`, drops a collation the receiving server does not have, and names each one. `SchemaSynchronizer` passes what the target reports; a dump, which writes a script for a server it never opens, passes nothing and keeps what the source said. Across families the name means nothing on the other side, so the column takes the target's default — and that is now a note rather than a silence, because the collation is what decides how a column compares, sorts and enforces uniqueness.
- **A Chart pane**, beside Rows. Bar, line, area and pie; scatter when a second measure can hold the x axis. The rule that earns its place: **a key is not a measure.** `ChartSpec.isIdentifier` refuses a primary key, a UUID, and a column named `id`, `rowid`, `oid` or `…_id` — and refuses only those, because a looser `hasSuffix("id")` would take `paid`, `valid` and `solid` with it, and those are real numbers. A result opens on its first real measure, labelled by the first column that is not one. Rows sharing a label are drawn one bar each, or summed, averaged or counted. A NULL measure is left out rather than drawn as a zero, which would be a different claim about the data. Hovering reads out the point. The pane hides entirely when nothing measures anything, the way Map hides without a geometry column. Capped at 5,000 points. Swift Charts, a system framework on the macOS 14 floor — no new dependency.
- **The splitter turns.** Editor above results by default; a control in the editor's bar puts them side by side, which is the better use of a wide screen. Stored as `editor.splitSideBySide`, so it survives a relaunch.
- **Beautify formats the selection** when there is one, the whole document otherwise — what every other editor does with a formatting command.

**Consequences.** Tests: `SchemaTranslatorTests` gains the three collation cases (carried in-family, dropped when the target lacks it, named when crossing); `ChartSpecTests` (7) pins the key rule, the `paid`/`valid` counter-case, which shapes each result supports, the default columns, the aggregates, and that a NULL is not a zero. Verified in the app against MySQL: `SELECT c.name, o.total, o.customer_id, o.id …` opens the Chart pane on `total` by `name` — neither `id` nor `customer_id` is offered as a value — and `SELECT id, name FROM customers` shows no Chart tab at all. Not done and deliberately so: two editors side by side, which would mean a second controller per tab and a second `sql` on the model, and is a different feature from splitting one tab's two panes.

## ADR-0054 — What a review of the session's work turned up, and what it changed
Date: 2026-09-17

**Context.** A full review of the uncommitted work, read against Swift 6 strict concurrency, the API design guidelines and plain correctness. Style was measured separately, with the repo's own `Scripts/swift-format.json`: linting every touched file against its committed baseline came to **76 findings against the baseline's 102**, with no file worse than before — the repo predates the current swift-format, and the rewritten parts are cleaner than what they replaced. Concurrency came back clean — the one construct that looks suspect, an unstructured `Task {}` inside `rollbackForCleanup`, is correct: it inherits no cancellation, is awaited rather than fire-and-forget, and its `await` releases the session actor. The defects were elsewhere.

**Decision.** Everything below was a real defect and is fixed.
- **Pruning a collation broke PostgreSQL.** `PostgresIntrospector.collations` deliberately omits `pg_catalog`, where all 1,284 of this server's collations live; it returns three. Pruning a PostgreSQL→PostgreSQL sync against that list would have stripped `en_US.utf8` from every column and quietly changed how it sorts. The prune is now MySQL-family only, where the names really do diverge and `information_schema.COLLATIONS` is complete. Introduced by ADR-0053 and caught before it shipped.
- **A cleanup rollback that failed said nothing.** `rollbackForCleanup` returned void, so `ConnectionSession.release` pooled a connection that was still inside a transaction; the next lease's `BEGIN` would implicitly commit the abandoned work on MySQL or join it on PostgreSQL. It now returns whether the transaction actually ended, `release` drops the connection when it did not, and the attempt is raced against a five-second clock so a black-holed socket cannot hold a pool slot open for ever.
- **A chart could present a fraction as the total.** A result pages, so the grid holds the rows around the reader; `ChartSpec` iterated the full row count and silently skipped what it could not read. Summing by category over a 4,000-row result that had loaded 1,000 drew the answer with no hint it was a quarter of it. `plot` now reports `rowsUsed` against `rowsTotal` and the pane says "N of M rows" whenever they differ.
- **Charts and text.** `NaN` and `Infinity` — which PostgreSQL's `numeric` and `double precision` really store, and which Swift's `Double(_: String)` really parses — are no longer values: they cannot scale an axis, and a NaN never equals itself, so such a point could never be highlighted either. Line and area now space their points along x by value when the category is a number, instead of drawing an ordered series as evenly spaced positions. The plot is computed once per change rather than on every hover event.
- **Editing an event's comment could move it by hours.** `information_schema.EVENTS` renders a schedule in the event's *own* time zone; `ALTER EVENT` reads a re-stated schedule in the *session's*. Re-emitting `ON SCHEDULE` for an edit that only touched a comment therefore moved the event. The schedule is now re-stated only when it actually changed, the sheet shows the event's zone rather than the session's, and it warns before a save that would rewrite one zone's times in another.
- Smaller, all real: a blank `renamedFrom` produced `ALTER EVENT \`db\`.\`\``; a compound interval accepted `-5:30` and `0:0`; a one-time schedule silently discarded a `STARTS` the caller passed; the Chart pane stayed blank after switching results because the reset bindings were never re-derived; the pane could stay selected on Chart after the tab stopped being offered; a cross-engine sync emitted one collation note per text column (300 for a 50-table sync) instead of one per table naming both the set and the collation; `formatSQL` on a selection left the selection describing the old text, so ⌘⏎ afterwards ran a truncated statement; and a refused read of `information_schema.EVENTS` made the Objects tab's Events section vanish with no explanation rather than saying the server refused; and starting the scheduler from the sheet swallowed a failed read-back with `try?`, leaving the banner still claiming it was off after it had been turned on — it now says the change went through and only the confirmation did not.

**Test quality.** Five tests were weaker than they looked. `testTurningTheSchedulerOnIsRefusedVerbatimWithoutThePrivilege` depended on the account lacking `SUPER`, and on a privileged account would have turned the scheduler on with `SET PERSIST` — which survives a restart — and left it that way; it now reads the value first and puts it back. The already-past hint probed dates decades either side of its fixed clock, so it would have passed in any time zone and could never have caught the zone bug beside it; it probes two days either side now. The span check tested only its column half. The "no notes" case used columns without a character set, which real introspection always sets. The COPY array test omitted the one element — a literal backslash — that exercises its nested escaping.

**A CI gate that could never run.** The app smoke test — the one check that drives the real `AppEnvironment`, `ConnectionSession` and tab controllers end to end — looked for its connection in the developer's own app store, and skipped with a warning when it found none. It had therefore been skipping on this machine ever since the real connections were deleted, which is exactly the silent pass CLAUDE.md forbids. `AppEnvironment.init` now takes a `storePath`, and `--smoke-test` builds its own connection from `TINKER_TEST_PG_URL` in a throwaway store with an `EphemeralSecretStore`, refusing any URL whose database is not `tinker_test`. `Scripts/ci.sh` owns the temporary file and deletes it afterwards. The run neither reads nor writes the developer's store or Keychain, and the pass — 134 checks over queries, the grid, structure, objects, transfer and the production guard — now actually runs.

**What the test suites left behind.** Two leaks, both found by looking at the machine rather than at the code. The SQLite fixture directory is named for the process so concurrent runs cannot share a database, which means nothing ever deletes it; with a million-row fixture inside, the temporary directory held 134 of them and **5.3 GB**. `TestEnvironment` now sweeps the directories whose process has exited, on each run, leaving only live ones. Separately, `MySQLIntegrationTests` cleaned its scratch tables with `defer { Task { ... } }` — which only *starts* the drop, and `withEachServer` closes the connection immediately after, so the close won the race and `tinker_bits` and `tinker_tiny` had been sitting in `tinker_test` on both servers. `withEachServer` now takes the scratch names and drops them, awaited, on the success and the failure path alike.

**Consequences.** `Scripts/ci.sh` green, smoke test included; release build and the whole suite green in release with zero first-party warnings; three consecutive debug runs clean. 769 package tests across nine suites — `DBSQLTests` 259, `DBGridTests` 186, `DBPostgresTests` 77, `DBCoreTests` 76, `DBMySQLTests` 47, `DBTunnelTests` 46, `DBSQLiteTests` 38, `DBStoreTests` 29, `DBTestKitTests` 11 — plus 27 app-hosted `TinkerTests`. Every MySQL-family suite ran twice, once against MySQL 9.4.0 and once against MariaDB 11.8.9. Two integration tests skip for want of a privilege the test account does not have (`testAKilledConnectionIsReportedAsLost`, `testWrongPasswordSurfacesAsAuthenticationFailure`); both predate this work.

## ADR-0055 — A connection remembers which engine answered, rather than guessing
Date: 2026-09-17

**Context.** MySQL and MariaDB share a dialect, a wire protocol and, as often as not, a port. `EngineMark` draws a dolphin for one and a seal for the other, but it was told which by `SidebarModel.flavor(of:)`, and that map was only filled when a session reached `.connected` and was never written anywhere. So a MariaDB connection showed MySQL's dolphin until it was opened, and again after every restart — which on a sidebar of closed connections means always. Two rows named "MariaDB" and "MySQL" sat there with the same badge.

**Decision.** `ConnectionConfig` gains `knownFlavor`, written when a server first says what it is and saved with the connection. `flavor(of:)` answers with the live server's word when there is one and the remembered word otherwise.

The alternative was to guess: MariaDB is often on another port here (3316), and the connection was even named "MariaDB". Both were rejected. A port is a local accident — the same server moves, and a MySQL instance can sit on 3316 just as easily — and a name is whatever someone typed. A badge that claims to identify an engine has to be right for the reason it says, which is that the server answered. The cost is that a connection never yet opened shows the dolphin once; after the first connection it is right for good.

**Consequences.** The field is optional, so a connection saved before it existed decodes with `knownFlavor` nil and behaves exactly as before — covered by `testTheFlavourAServerReportedSurvivesAReopenAndAnOlderRowStillLoads`, which also proves the answer survives a quit.
