# Test environment

Integration tests run against **your existing local servers**. Nothing is installed,
started, stopped, or reconfigured. No Docker.

The only things ever touched are database `tinker_test` and user `tinker_test`.

## 1. Prepare (once, idempotent)

Point `prepare.sh` at your servers with **admin** URLs. These are used only by this script.

```sh
export TINKER_TEST_PG_ADMIN_URL='postgresql://<your-macos-user>@localhost:5432/postgres'
export TINKER_TEST_MYSQL_ADMIN_URL='mysql://root:<password>@127.0.0.1:3306/'
testenv/prepare.sh
```

Either variable may be omitted; that engine is then skipped with a warning.

The script creates `tinker_test` (database + user with rights on that database only),
loads `fixtures/<dialect>/*.sql` as the test user, verifies the user is not a
superuser / has no global grants, and prints the **non-admin** URLs to export.

## 2. Point the tests at the servers

```sh
export TINKER_TEST_PG_URL='postgresql://tinker_test:tinker_test@localhost:5432/tinker_test'
export TINKER_TEST_MYSQL_URL='mysql://tinker_test:tinker_test@127.0.0.1:3306/tinker_test'
Scripts/ci.sh
```

Tip: put the exports in `testenv/.env` (git-ignored) and `source testenv/.env`.

Additional servers (other versions, MariaDB, remote) go in comma-separated lists:

```sh
export TINKER_TEST_PG_URLS='postgresql://tinker_test:pw@pg13.example:5432/tinker_test,...'
export TINKER_TEST_MYSQL_URLS='mysql://tinker_test:pw@mariadb.example:3306/tinker_test,...'
```

Run `prepare.sh` against each of them too (one admin URL at a time).

## Safety rules enforced by the tests

- A URL whose database is not `tinker_test` **fails** the suite (it does not skip).
- A URL whose user is `root`, `postgres`, `admin` or `mysql` **fails** the suite.
- From Phase 1 on, the drivers additionally verify at connect time that the PG user is not
  a superuser and the MySQL user has no global grants.
- Unset variables **skip** the engine, and `Scripts/ci.sh` prints a visible warning plus a
  coverage summary at the end saying which engines actually ran.

## SSH

Tunnel tests need nothing set up. Two servers are used:

- an SSH server inside the test process, which forwards to the local PostgreSQL and
  covers the client's protocol path, password authentication and the port forward
  (DECISIONS.md ADR-0014);
- the machine's own `/usr/sbin/sshd`, started unprivileged on a free port in a temporary
  directory by `OpenSSHInteropTests`, which covers interoperability with OpenSSH for every
  key type and file format (ADR-0039). Nothing on the machine is changed and no
  administrator rights are needed; the suite skips only when `sshd` is missing.

Jump hosts have no test yet; `dbcli --ssh` reaches one by hand. (Earlier revisions of
this file named `TINKER_TEST_SSH_PASSWORD_URL` and `TINKER_TEST_SSH_JUMP_URL`; nothing ever
read them, and they are gone.)
