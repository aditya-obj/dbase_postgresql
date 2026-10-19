# Integration test servers

Test-only Docker setup for `dart test -P integration`. Every password and
certificate here is a throwaway. Ports are bound to `127.0.0.1` only.

> Status: written without Docker available, so this file set has not been
> run yet. Report anything that fails on the first run.

## Services

| Service | Image | Host port | What it is |
|---|---|---|---|
| `pg13` … `pg18` | `postgres:13.23` … `postgres:18.6` | `54313` … `54318` | One server per supported major. SCRAM-SHA-256 for TCP. |
| `pg18-tls` | `postgres:18.6` | `54328` | TLS required (`hostssl` + SCRAM, plain TCP rejected). |
| `tls-certs` | `alpine/openssl:3.5.9` | none | Makes a throwaway CA and server certificate for `pg18-tls` and copies the CA to `.generated/ca.crt`. |
| `pgbouncer` | `edoburu/pgbouncer:v1.26.0-p0` | `56432` | PgBouncer in **transaction** pooling mode in front of `pg18`. |
| `openssh` | `linuxserver/openssh-server` | `2222` | OpenSSH with TCP forwarding, on the same network as `pg18` and `pg18-tls`. |

All servers use user `dabase`, password `dabase`, database `dabase`.

## Running

From `packages/dabase_postgresql`:

```sh
docker compose -f test/docker/compose.yml up -d --wait          # everything
docker compose -f test/docker/compose.yml up -d --wait pg18     # just one

DABASE_PG_URL='postgresql://dabase:dabase@localhost:54318/dabase?sslmode=disable' \
  dart test -P integration

docker compose -f test/docker/compose.yml down -v               # clean up
```

`--wait` returns once every started service passes its healthcheck.

## Environment variables

| Variable | Meaning |
|---|---|
| `DABASE_PG_URL` | Connection string of the server under test (URI or `key=value`). Unset: integration tests are skipped with a message. On CI (`CI=true`) a missing URL fails the run. |
| `PGPASSWORD` and other `PG*` | Applied through `PgConnectionConfig.resolveDefaults`, as libpq would, for keywords missing from `DABASE_PG_URL`. |

`sslmode` in the URL picks the driver's TLS mode: `disable`, `allow` and
`prefer` (the default) connect without TLS; `require` uses TLS without
verifying the certificate; `verify-ca` and `verify-full` verify it.

## URLs per service

```sh
# PostgreSQL 13 .. 18
postgresql://dabase:dabase@localhost:54313/dabase?sslmode=disable
# ...
postgresql://dabase:dabase@localhost:54318/dabase?sslmode=disable

# TLS (self-signed chain; the driver does not verify it in require mode)
postgresql://dabase:dabase@localhost:54328/dabase?sslmode=require

# PgBouncer, transaction mode
postgresql://dabase:dabase@localhost:56432/dabase?sslmode=disable

# Through the SSH server: open a tunnel, then use the local port
ssh -p 2222 -N -L 55432:pg18:5432 dabase@localhost        # password: dabase
postgresql://dabase:dabase@localhost:55432/dabase?sslmode=disable
```

The integration tests themselves only need `DABASE_PG_URL`. The TLS,
PgBouncer and SSH services exist so the same servers can be used for the
app's TLS and SSH-tunnel spikes.

## What the tests check

- `keywords_conformance_test.dart`: our keyword table against
  `SELECT word, catcode FROM pg_get_keywords()`, with cited per-version
  differences.
- `splitter_conformance_test.dart`: every statement the splitter returns
  is accepted on its own by the server (extended protocol, plus SQL
  `PREPARE` for preparable statements), and the statement counts match.
- `transaction_block_conformance_test.dart`:
  `cannotRunInTransactionBlock` agrees with SQLSTATE 25001 inside
  `BEGIN ... ROLLBACK`.

Every test runs in a rolled-back transaction, or cleans up objects
prefixed `dabase_it_`, so a shared development server is left unchanged.
Still, prefer the containers here over any shared server.
