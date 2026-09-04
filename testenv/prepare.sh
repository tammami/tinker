#!/usr/bin/env bash
# testenv/prepare.sh — create the isolated `tinker_test` database and user on the
# developer's EXISTING local PostgreSQL and/or MySQL servers, then load fixtures.
#
#   Reads:  TINKER_TEST_PG_ADMIN_URL     e.g. postgresql://me@localhost:5432/postgres
#           TINKER_TEST_MYSQL_ADMIN_URL  e.g. mysql://root:secret@127.0.0.1:3306/
#   Prints: the non-admin URLs to export as TINKER_TEST_PG_URL / TINKER_TEST_MYSQL_URL
#
# Guarantees (SPEC §16 Phase 0, §17.1):
#   - idempotent: safe to re-run at any time
#   - installs, starts, stops and reconfigures nothing
#   - touches only database `tinker_test` and user `tinker_test`
#   - the test user has rights only on that database
#
# Admin URLs are used here and nowhere else. Tests refuse admin users.
set -euo pipefail

TEST_DB="tinker_test"
TEST_USER="tinker_test"
TEST_PASSWORD="tinker_test"   # local-only, fixed so re-runs are idempotent (DECISIONS.md ADR-0004)

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURES="$HERE/fixtures"

log()  { printf '\033[1;34m[prepare]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[prepare] WARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[prepare] ERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# url_decode <string>  — minimal percent-decoding for credentials in URLs.
url_decode() { local s="${1//+/ }"; printf '%b' "${s//%/\\x}"; }

# parse_url <url> — sets URL_SCHEME URL_USER URL_PASS URL_HOST URL_PORT URL_DB
parse_url() {
    local url="$1"
    local re='^([A-Za-z]+)://(([^:@/]*)(:([^@/]*))?@)?([^:/?]+)(:([0-9]+))?(/([^?]*))?(\?.*)?$'
    [[ "$url" =~ $re ]] || die "cannot parse URL: $url"
    URL_SCHEME="${BASH_REMATCH[1]}"
    URL_USER="$(url_decode "${BASH_REMATCH[3]}")"
    URL_PASS="$(url_decode "${BASH_REMATCH[5]}")"
    URL_HOST="${BASH_REMATCH[6]}"
    URL_PORT="${BASH_REMATCH[8]}"
    URL_DB="${BASH_REMATCH[10]}"
}

did_anything=0
exports=()

# ---------------------------------------------------------------------------
# PostgreSQL
# ---------------------------------------------------------------------------
prepare_pg() {
    local admin="$1"
    command -v psql >/dev/null || die "psql not found on PATH (needed for PostgreSQL preparation)"
    parse_url "$admin"
    local host="$URL_HOST" port="${URL_PORT:-5432}"
    case "$URL_SCHEME" in postgres|postgresql) ;; *) die "TINKER_TEST_PG_ADMIN_URL must use postgresql://";; esac

    log "PostgreSQL: connecting as admin to $host:$port"
    local version
    version="$(psql "$admin" -Atqc 'SHOW server_version' 2>&1)" || die "PostgreSQL admin connection failed: $version"
    log "PostgreSQL: server version $version"

    # Role: create if missing, then normalise attributes. Never superuser.
    psql "$admin" -v ON_ERROR_STOP=1 -q <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '$TEST_USER') THEN
        CREATE ROLE $TEST_USER;
    END IF;
END
\$\$;
ALTER ROLE $TEST_USER WITH LOGIN PASSWORD '$TEST_PASSWORD' NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
SQL

    # Database: CREATE DATABASE cannot run inside a DO block, so check first.
    local exists
    exists="$(psql "$admin" -Atqc "SELECT 1 FROM pg_database WHERE datname = '$TEST_DB'")"
    if [[ "$exists" != "1" ]]; then
        log "PostgreSQL: creating database $TEST_DB"
        psql "$admin" -v ON_ERROR_STOP=1 -q -c "CREATE DATABASE $TEST_DB OWNER $TEST_USER ENCODING 'UTF8'"
    else
        log "PostgreSQL: database $TEST_DB already exists"
    fi
    psql "$admin" -v ON_ERROR_STOP=1 -q <<SQL
ALTER DATABASE $TEST_DB OWNER TO $TEST_USER;
REVOKE ALL ON DATABASE $TEST_DB FROM PUBLIC;
GRANT ALL ON DATABASE $TEST_DB TO $TEST_USER;
SQL

    # The test user owns `public` in its own database (PG 15+: pg_database_owner). Make it explicit for older servers.
    local admin_test_db
    admin_test_db="$(printf '%s' "$admin" | sed -E "s#^([a-z]+://[^/]+)(/[^?]*)?(\?.*)?\$#\1/$TEST_DB\3#")"
    psql "$admin_test_db" -v ON_ERROR_STOP=1 -q -c "ALTER SCHEMA public OWNER TO $TEST_USER" 2>/dev/null || true

    local test_url="postgresql://$TEST_USER:$TEST_PASSWORD@$host:$port/$TEST_DB"

    # Load fixtures AS the test user so every object is owned by it.
    local f
    for f in "$FIXTURES"/pg/*.sql; do
        [[ -e "$f" ]] || continue
        log "PostgreSQL: loading $(basename "$f")"
        psql "$test_url" -v ON_ERROR_STOP=1 -q -f "$f"
    done

    # Prove the user is not a superuser.
    local super
    super="$(psql "$test_url" -Atqc "SELECT rolsuper FROM pg_roles WHERE rolname = current_user")"
    [[ "$super" == "f" ]] || die "PostgreSQL: $TEST_USER is superuser; refusing to hand out this URL"

    exports+=("export TINKER_TEST_PG_URL='$test_url'")
    did_anything=1
}

# ---------------------------------------------------------------------------
# MySQL / MariaDB
# ---------------------------------------------------------------------------
prepare_mysql() {
    local admin="$1"
    command -v mysql >/dev/null || die "mysql client not found on PATH (needed for MySQL preparation)"
    parse_url "$admin"
    local host="$URL_HOST" port="${URL_PORT:-3306}" user="$URL_USER" pass="$URL_PASS"
    case "$URL_SCHEME" in mysql|mariadb) ;; *) die "TINKER_TEST_MYSQL_ADMIN_URL must use mysql://";; esac

    # MYSQL_PWD keeps the password off the process list and silences the CLI warning.
    admin_mysql() { MYSQL_PWD="$pass" mysql --protocol=tcp -h "$host" -P "$port" -u "$user" "$@"; }
    test_mysql()  { MYSQL_PWD="$TEST_PASSWORD" mysql --protocol=tcp -h "$host" -P "$port" -u "$TEST_USER" "$@"; }

    log "MySQL: connecting as admin to $host:$port"
    local version
    version="$(admin_mysql -Nse 'SELECT VERSION()' 2>&1)" || die "MySQL admin connection failed: $version"
    log "MySQL: server version $version"

    admin_mysql <<SQL
CREATE DATABASE IF NOT EXISTS \`$TEST_DB\` CHARACTER SET utf8mb4;
CREATE USER IF NOT EXISTS '$TEST_USER'@'%' IDENTIFIED BY '$TEST_PASSWORD';
ALTER USER '$TEST_USER'@'%' IDENTIFIED BY '$TEST_PASSWORD';
REVOKE ALL PRIVILEGES, GRANT OPTION FROM '$TEST_USER'@'%';
GRANT ALL PRIVILEGES ON \`$TEST_DB\`.* TO '$TEST_USER'@'%';
FLUSH PRIVILEGES;
SQL

    local f
    for f in "$FIXTURES"/mysql/*.sql; do
        [[ -e "$f" ]] || continue
        log "MySQL: loading $(basename "$f")"
        test_mysql "$TEST_DB" < "$f"
    done

    # Prove there are no global grants: every grant line must be USAGE on *.* or scoped to the test db.
    local grants bad
    grants="$(test_mysql -Nse "SHOW GRANTS FOR CURRENT_USER()")"
    bad="$(printf '%s\n' "$grants" | grep -v -E "^GRANT USAGE ON \*\.\* TO" | grep -v -E "ON \`?$TEST_DB\`?\.\* TO" || true)"
    [[ -z "$bad" ]] || die "MySQL: $TEST_USER has grants beyond $TEST_DB:\n$bad"

    exports+=("export TINKER_TEST_MYSQL_URL='mysql://$TEST_USER:$TEST_PASSWORD@$host:$port/$TEST_DB'")
    did_anything=1
}

# ---------------------------------------------------------------------------
if [[ -n "${TINKER_TEST_PG_ADMIN_URL:-}" ]]; then
    prepare_pg "$TINKER_TEST_PG_ADMIN_URL"
else
    warn "TINKER_TEST_PG_ADMIN_URL not set — skipping PostgreSQL"
fi

if [[ -n "${TINKER_TEST_MYSQL_ADMIN_URL:-}" ]]; then
    prepare_mysql "$TINKER_TEST_MYSQL_ADMIN_URL"
else
    warn "TINKER_TEST_MYSQL_ADMIN_URL not set — skipping MySQL"
fi

[[ "$did_anything" == 1 ]] || die "nothing to do: set TINKER_TEST_PG_ADMIN_URL and/or TINKER_TEST_MYSQL_ADMIN_URL (see testenv/README.md)"

echo
log "Done. Export these before running Scripts/ci.sh (or save them to testenv/.env, which is git-ignored):"
echo
printf '%s\n' "${exports[@]}"
echo
