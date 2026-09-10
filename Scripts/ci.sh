#!/usr/bin/env bash
# Scripts/ci.sh — the definition-of-done gate (SPEC §16 Phase 0, §18).
#
#   1. Build every package and test target (Swift 6, strict concurrency, warnings are errors).
#   2. Lint the dependency direction (App → DB* → DBCore; DBCore imports only Foundation + swift-log).
#   3. Run unit tests. Integration tests run for each engine whose TINKER_TEST_*_URL is set,
#      otherwise they are skipped with a VISIBLE warning — never a silent pass.
#   4. Build the macOS app with warnings as errors.
#   5. Print a coverage summary: which engines actually ran.
#
# Usage: Scripts/ci.sh [--skip-app]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SKIP_APP=0
# Strict mode (--strict or TINKER_CI_STRICT=1): a run that skipped anything is not green.
# Every engine URL must be set, no test may skip, and the app smoke test must run. This
# is what a release or a "the driver feature is done" claim has to pass (CLAUDE.md: a
# skipped test is not a passing test).
STRICT="${TINKER_CI_STRICT:-0}"
for arg in "$@"; do
    case "$arg" in
        --skip-app) SKIP_APP=1 ;;
        --strict) STRICT=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

bold()  { printf '\n\033[1m== %s\033[0m\n' "$*"; }
warn()  { printf '\033[1;33mWARNING:\033[0m %s\n' "$*"; }
fail()  { printf '\033[1;31mFAIL:\033[0m %s\n' "$*"; exit 1; }

# ---------------------------------------------------------------------------
bold "Build (swift build --build-tests, zero warnings in first-party code)"
# Touch first-party sources so llbuild recompiles them (cached dependencies stay), so that
# every warning is actually emitted on this run and can be caught below.
find Packages Tools -name '*.swift' -exec touch {} +
BUILD_LOG="$(mktemp -t tinker-ci-build)"
if ! swift build --build-tests 2>&1 | tee "$BUILD_LOG"; then
    fail "build failed (log: $BUILD_LOG)"
fi
if grep -E "^$ROOT/(Packages|Tools)/.*: warning:" "$BUILD_LOG" >/dev/null; then
    grep -E "^$ROOT/(Packages|Tools)/.*: warning:" "$BUILD_LOG"
    fail "first-party code produced warnings"
fi
echo "  no warnings"

# ---------------------------------------------------------------------------
bold "Dependency direction lint"
# Allowed imports per first-party module (macOS ships bash 3.2, so no associative arrays).
allowed_imports() {
    case "$1" in
        DBCore)     echo "Foundation Logging" ;;
        DBSQL)      echo "Foundation Logging DBCore" ;;
        DBPostgres) echo "Foundation Logging DBCore DBSQL PostgresNIO NIO NIOCore NIOPosix NIOSSL NIOConcurrencyHelpers" ;;
        DBMySQL)    echo "Foundation Logging DBCore DBSQL MySQLNIO NIO NIOCore NIOPosix NIOSSL NIOConcurrencyHelpers" ;;
    DBSQLite)   echo "Foundation Logging DBCore DBSQL SQLite3" ;;
        DBTunnel)   echo "Foundation Logging DBCore Citadel Crypto _CryptoExtras CTinkerBcrypt NIO NIOCore NIOPosix NIOSSH os" ;;
        DBStore)    echo "Foundation Logging DBCore SQLite3 Security" ;;
        # Observation is the toolchain's own framework (the @Observable write queue that
        # views watch), not a package dependency.
        DBGrid)     echo "Foundation Logging Observation DBCore DBSQL os zlib" ;;
        DBTestKit)  echo "Foundation Logging DBCore XCTest" ;;
        *)          echo "" ;;
    esac
}
lint_failed=0
for module in DBCore DBSQL DBPostgres DBMySQL DBSQLite DBTunnel DBStore DBGrid DBTestKit; do
    dir="Packages/$module/Sources/$module"
    [[ -d "$dir" ]] || continue
    allowed="$(allowed_imports "$module")"
    imports="$(grep -rhoE '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+[A-Za-z_][A-Za-z0-9_]*' "$dir" \
        | awk '{print $NF}' | sort -u || true)"
    for imp in $imports; do
        if [[ " $allowed " != *" $imp "* ]]; then
            echo "  $module imports $imp — not allowed (allowed: $allowed)"
            lint_failed=1
        fi
    done
done
# Drivers never import each other, DBStore never imports drivers — covered by the lists above.
[[ $lint_failed == 0 ]] || fail "dependency direction violated"
echo "  ok"

# ---------------------------------------------------------------------------
bold "Tests"
PG_SET=0;    [[ -n "${TINKER_TEST_PG_URL:-}${TINKER_TEST_PG_URLS:-}" ]]       && PG_SET=1
MYSQL_SET=0; [[ -n "${TINKER_TEST_MYSQL_URL:-}${TINKER_TEST_MYSQL_URLS:-}" ]] && MYSQL_SET=1
if [[ $STRICT == 1 ]]; then
    [[ $PG_SET == 1 ]]    || fail "strict: TINKER_TEST_PG_URL not set — PostgreSQL integration tests would be skipped"
    [[ $MYSQL_SET == 1 ]] || fail "strict: TINKER_TEST_MYSQL_URL not set — MySQL integration tests would be skipped"
else
    [[ $PG_SET == 1 ]]    || warn "TINKER_TEST_PG_URL not set — PostgreSQL integration tests will be SKIPPED"
    [[ $MYSQL_SET == 1 ]] || warn "TINKER_TEST_MYSQL_URL not set — MySQL integration tests will be SKIPPED"
fi

TEST_LOG="$(mktemp -t tinker-ci-tests)"
# `swift test` reports skipped tests as "skipped" with the XCTSkip reason; keep the full log.
if ! swift test --skip-build 2>&1 | tee "$TEST_LOG"; then
    fail "tests failed (log: $TEST_LOG)"
fi

# ---------------------------------------------------------------------------
if [[ $SKIP_APP == 0 ]]; then
    bold "App build (xcodebuild; warnings-as-errors is set on the app target in the project)"
    APP_LOG="$(mktemp -t tinker-ci-app)"
    if ! xcodebuild \
            -project App/Tinker.xcodeproj \
            -scheme Tinker \
            -configuration Debug \
            -destination 'platform=macOS,arch=arm64' \
            -derivedDataPath .build/DerivedData \
            CODE_SIGNING_ALLOWED=NO \
            -quiet build 2>&1 | tee "$APP_LOG"; then
        fail "app build failed (log: $APP_LOG)"
    fi
    if grep -E '^[^ ]+: warning:' "$APP_LOG" >/dev/null; then
        grep -E '^[^ ]+: warning:' "$APP_LOG"
        fail "app build produced warnings"
    fi
    echo "  ok"

    bold "App smoke test"
    # Drives the objects the views drive — environment, session, table tab, query tab —
    # against whichever connection the store holds (SPEC §17, DECISIONS.md ADR-0019).
    APP_BINARY=".build/DerivedData/Build/Products/Debug/Tinker.app/Contents/MacOS/Tinker"
    if [[ ! -x "$APP_BINARY" ]]; then
        warn "app binary not found — smoke test SKIPPED"
    else
        set +e
        "$APP_BINARY" --smoke-test
        SMOKE_STATUS=$?
        set -e
        case $SMOKE_STATUS in
            0) echo "  ok" ;;
            2)
                if [[ $STRICT == 1 ]]; then
                    fail "strict: no tinker_test connection in the app store — smoke test did not run"
                else
                    warn "no tinker_test connection configured in the app store — smoke test SKIPPED"
                fi
                ;;
            *) fail "app smoke test failed" ;;
        esac
    fi
fi

# ---------------------------------------------------------------------------
bold "Coverage summary"
skipped_count="$(grep -cE "skipped \([0-9.]+ seconds\)" "$TEST_LOG" || true)"
echo "  skipped tests: $skipped_count"
grep -E "Test skipped" "$TEST_LOG" | sed -E 's/^.*: (Test skipped.*)$/    \1/' | sort -u || true
if [[ $STRICT == 1 && "$skipped_count" != "0" ]]; then
    fail "strict: $skipped_count test(s) were skipped; a skipped test is not a passing test"
fi
echo
echo "  PostgreSQL integration: $([[ $PG_SET == 1 ]] && echo "configured: ${TINKER_TEST_PG_URL:-<PG_URLS>}" | sed -E 's#://([^:@/]+):[^@]*@#://\1:***@#' || echo "NOT RUN (env unset)")"
echo "  MySQL integration:      $([[ $MYSQL_SET == 1 ]] && echo "configured: ${TINKER_TEST_MYSQL_URL:-<MYSQL_URLS>}" | sed -E 's#://([^:@/]+):[^@]*@#://\1:***@#' || echo "NOT RUN (env unset)")"
echo "  SQLite integration:     $([[ -n "${TINKER_TEST_SQLITE_DISABLED:-}" ]] && echo "NOT RUN (TINKER_TEST_SQLITE_DISABLED set)" || echo "ran against a temporary database file (no setup needed)")"
echo "  engines that actually connected (reported by driver tests from Phase 1 on):"
grep -E "server version" "$TEST_LOG" | sed "s/^/    /" | sort -u || echo "    none (no driver yet)"
echo
echo "CI green."
