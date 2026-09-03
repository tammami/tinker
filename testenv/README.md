# Test environment

Integration tests run against **your existing local servers**. Nothing is installed,
started, stopped, or reconfigured. No Docker.

The only things ever touched are database `dbstudio_test` and user `dbstudio_test`.

## 1. Prepare (once, idempotent)

Point `prepare.sh` at your servers with **admin** URLs. These are used only by this script.

```sh
export DBSTUDIO_TEST_PG_ADMIN_URL='postgresql://<your-macos-user>@localhost:5432/postgres'
export DBSTUDIO_TEST_MYSQL_ADMIN_URL='mysql://root:<password>@127.0.0.1:3306/'
testenv/prepare.sh
```

Either variable may be omitted; that engine is then skipped with a warning.

The script creates `dbstudio_test` (database + user with rights on that database only),
loads `fixtures/<dialect>/*.sql` as the test user, verifies the user is not a
superuser / has no global grants, and prints the **non-admin** URLs to export.

## 2. Point the tests at the servers

```sh
export DBSTUDIO_TEST_PG_URL='postgresql://dbstudio_test:dbstudio_test@localhost:5432/dbstudio_test'
export DBSTUDIO_TEST_MYSQL_URL='mysql://dbstudio_test:dbstudio_test@127.0.0.1:3306/dbstudio_test'
Scripts/ci.sh
```

Tip: put the exports in `testenv/.env` (git-ignored) and `source testenv/.env`.

Additional servers (other versions, MariaDB, remote) go in comma-separated lists:

```sh
export DBSTUDIO_TEST_PG_URLS='postgresql://dbstudio_test:pw@pg13.example:5432/dbstudio_test,...'
export DBSTUDIO_TEST_MYSQL_URLS='mysql://dbstudio_test:pw@mariadb.example:3306/dbstudio_test,...'
```

Run `prepare.sh` against each of them too (one admin URL at a time).

## Safety rules enforced by the tests

- A URL whose database is not `dbstudio_test` **fails** the suite (it does not skip).
- A URL whose user is `root`, `postgres`, `admin` or `mysql` **fails** the suite.
- From Phase 1 on, the drivers additionally verify at connect time that the PG user is not
  a superuser and the MySQL user has no global grants.
- Unset variables **skip** the engine, and `Scripts/ci.sh` prints a visible warning plus a
  coverage summary at the end saying which engines actually ran.

## SSH

Tunnel tests need nothing set up: they start an SSH server inside the test process and
forward through it to the local PostgreSQL (see DECISIONS.md ADR-0014). That covers the
client's protocol path but not interoperability with OpenSSH's `sshd`.

To also test against a real server, enable
*System Settings → General → Sharing → Remote Login* and set:

```sh
export DBSTUDIO_TEST_SSH_PASSWORD_URL='ssh://user:password@host:22'
export DBSTUDIO_TEST_SSH_JUMP_URL='ssh://user@bastion:22'
```

Both are optional; when unset, those paths are reported as gaps rather than passing.
