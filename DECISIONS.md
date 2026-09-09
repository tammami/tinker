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
