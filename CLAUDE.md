# CLAUDE.md — working rules for this repository

You are implementing Tinker, a native macOS PostgreSQL/MySQL client. `SPEC.md` is the source of truth. Read it fully before any task. This file covers how to work, not what to build.

## Order of operations
1. Locate the current phase in `PROGRESS.md`. Work only on that phase.
2. Before writing code for a section, re-read that section of `SPEC.md` and its acceptance criteria.
3. Write or update tests alongside the code, not after.
4. Run `Scripts/ci.sh` (or the narrower script for the package you touched) before declaring anything done.
5. Append to `PROGRESS.md`: what was completed, what tests cover it, what was deferred and why.

## When the spec is unclear or wrong
- Do not guess silently. Record the ambiguity in `DECISIONS.md` with the option you chose and why, then proceed.
- If a spec requirement is impossible with the chosen library, do not weaken the requirement. Try the fallback named in the spec; if none, stop and report.
- Never expand scope. Anything listed as deferred in SPEC §16 stays unbuilt and unstubbed.

## Code rules (non-negotiable)
- Swift 6, `-strict-concurrency=complete`, zero warnings. Fix warnings; do not suppress them.
- Dependency direction: App → DB* packages → DBCore. DBCore imports only Foundation and swift-log. Drivers never import each other or the App.
- No `try!`, no force unwrap outside tests, no `DispatchQueue`, no `print`, no `Task.detached` unless justified in a comment.
- All DB I/O in actors. `@MainActor` only on views and view models.
- Server error messages are shown verbatim. Never rewrite, translate, or summarise them.
- Values that carry precision (decimal, timestamp) keep their server text. Never route them through Double or Date.
- Every generated UPDATE/DELETE uses primary-key WHERE with original values and checks affectedRows == 1 inside a transaction.
- Secrets live only in Keychain. Grep the store file in a test to prove it.
- Data grid = AppKit `NSTableView`. SQL editor = AppKit `NSTextView`. Not negotiable; SwiftUI equivalents fail the performance criteria.

## Testing rules
- Unit tests need no network. Integration tests run against the developer's existing local servers via `TINKER_TEST_*` env vars after `testenv/prepare.sh`. Never install, start, stop, or reconfigure a database server. Never use Docker. Never point tests at a database not named `tinker_test`, and never use a superuser/root URL for tests (admin URLs are for `prepare.sh` only).
- A driver feature without an integration test that actually ran against at least the local instance is not done. Skipped tests are not passing tests; report them as gaps in `PROGRESS.md`.
- Performance criteria in SPEC §12.6 are tested with signposts/XCTMetric, not by eye.

## Style
- Small, focused commits with messages describing behaviour, not files.
- Doc comments on all public API in packages.
- Prefer plain structs and enums over class hierarchies. Prefer protocols with one clear responsibility.
- No new dependencies without a `DECISIONS.md` entry.

## Reporting
When you finish a task, summarise in this shape:
- Done: …
- Tests: … (names, what they prove)
- Not done / deferred: … (with reason)
- Spec deviations: … (link to DECISIONS.md entry) or "none"
