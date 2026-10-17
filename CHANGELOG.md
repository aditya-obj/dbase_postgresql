# Changelog

## 0.3.0 (unreleased)

### Added

- New `SafetyFindingCode`s:
  - `readOnlyEscape` (danger): statements that can turn a read-only
    session or transaction read-write. `SET [SESSION | LOCAL]
    default_transaction_read_only` / `transaction_read_only` to anything
    but `on`/`true`/`yes`/`1` (including `DEFAULT`), `SET [SESSION
    CHARACTERISTICS AS] TRANSACTION ... READ WRITE`, `BEGIN` / `START
    TRANSACTION ... READ WRITE`, `RESET` of either setting, `RESET ALL`,
    `DISCARD ALL`, and `set_config()` calls naming either setting or
    whose setting name isn't a plain string literal.
  - `explicitLock` (warning): `LOCK`, with the mode in the new
    `StatementAnalysis.lockMode`.
  - `sideEffectFunction` (warning): calls to built-ins with side effects
    (`pg_terminate_backend`, `pg_cancel_backend`, `pg_reload_conf`,
    advisory locks, `pg_notify`, `dblink*`, `set_config`,
    `pg_stat_reset*`, large-object writers, replication-slot functions,
    `nextval`, `setval` and more) in queries, DML, `CALL` and `EXECUTE`.
    Best effort; `writes` is unchanged.
  - `whereAlwaysTrue` (warning): `UPDATE`/`DELETE` whose top-level `WHERE`
    is a literal tautology (`true`, `'t'`, `1 = 1`, `NOT false`, `x = x`).
  - `mergeUnrestricted` (danger), `mergeDeletesUnmatched` (danger) and
    `mergeModifies` (warning, every `MERGE`).
- `TableLockMode`, ordered from `accessShare` to `accessExclusive`.
- `StatementAnalysis`:
  - `targets`: the tables or objects changed by `UPDATE`, `DELETE`,
    `MERGE`, `TRUNCATE`, `DROP`, `ALTER [FOREIGN] TABLE` and `LOCK`
    (also inside CTEs and `EXPLAIN ANALYZE`), in the form the server
    resolves.
  - `cascades`: `TRUNCATE ... CASCADE` / `DROP ... CASCADE`. Their
    finding messages also say that other objects are affected.
  - `lockMode` and `dropObjectType`.
  - `changesTransactionMode`: true when `readOnlyEscape` is reported.

### Changed

- `UPDATE`/`DELETE ... WHERE true` (and the other literal tautologies)
  now report `whereAlwaysTrue`; they reported no finding before.
- `COMMIT PREPARED` and `ROLLBACK PREPARED` now report `writes: true`:
  they finish another session's transaction and are allowed in a
  read-only transaction.
- `cannotRunInTransactionBlock` is now true for `REINDEX SCHEMA`, for
  `REINDEX (options) DATABASE | SYSTEM | SCHEMA`, and for an enabled
  `CONCURRENTLY` in the `REINDEX` option list (PostgreSQL 14+).
- Adding enum values is source-breaking for exhaustive `switch`es over
  `SafetyFindingCode`, and the `index` of values after the insertion
  points changes. Match on the value or name, not the index.

## 0.2.0 (unreleased)

### Added

- `package:dbase_postgresql/importers.dart`, also exported from
  `dbase_postgresql.dart`.
- `PgPassFile` / `PgPassEntry`: parses libpq password files and looks up
  passwords with `passwordFromFile()`'s exact rules: first match wins,
  whole-field `*`, `\` escapes, `localhost` for an empty host or the
  default socket directory, `hostaddr` fallback, and unescaped colons
  matching colons in the value. Includes `lookupForConfig` (one result per
  host) and `toConfig` for wildcard-free entries. Per-line diagnostics
  (`PgPassDiagnosticCode`). No file-permission check.
- `PgServiceFile` / `PgService`: parses every section of a connection
  service file with `parseServiceFile()`'s rules and reports, per service,
  what a libpq lookup would do (`isValid`, `diagnostics`,
  `PgServiceDiagnosticCode`). Adds `PgServiceFile.merge` (the user file
  wins per name) and `PgService.applyTo` (connection string wins over the
  service).
- `PgAdminServersFile` / `PgAdminServer`: parses pgAdmin 4 `servers.json`
  in both the 6.20+ `ConnectionParameters` layout and the legacy flat
  layout, with pgAdmin's validation. Maps name, group, SSH tunnel
  (`PgAdminSshTunnel`), tags, colours, role, comment and database
  restrictions. Typed `PgAdminWarningCode` warnings cover file paths,
  `Service`, Kerberos, `PasswordExecCommand`, `PostConnectionSQL`,
  `hostaddr`, `sslnegotiation=direct` and secrets in the file. Rejected
  entries are reported in `errors` (`PgAdminErrorCode`).
- `PgLineDiagnostic`, `PgImportSeverity` and `PgImportException` (offset
  only, never echoes input).
- Tests: a literal port of libpq's matcher as an oracle (20,000 generated
  files in the unit suite, more under `-P fuzz`), libpq's edge cases
  (escapes, wildcards, CRLF, BOM, whitespace, empty fields, long lines),
  servers.json fixtures for both layouts, and importer mutation fuzzing.

### Security

- Nothing in an imported file is executed. `PasswordExecCommand` is
  dropped, and `PostConnectionSQL` is only stored and flagged.
- Diagnostics, warnings, exceptions and `toString()` never contain values
  from the file. Messages quote only known libpq keywords and pgAdmin field
  names.

## 0.1.0 (unreleased)

### Added

- `PgConnectionConfig`: parses `postgres://` / `postgresql://` URIs and
  libpq `key=value` strings with libpq semantics. Supports percent-decoding,
  bracketed IPv6, multi-host lists with parallel ports, Unix-socket hosts,
  quoted values and `ssl=true`. Unknown keywords are kept. Also adds
  `tryParse`, `toUri`, `redacted`, `copyWith`, `effectiveDatabase`,
  `resolveDefaults` (injectable `PG*` environment) and `securityWarnings`.
- `SslMode`, `PgHost`, `PgSecurityWarning`, `PgConfigParseException`
  (offset only, never echoes input).
- `SqlLexer` / `SqlToken`: a lossless PostgreSQL lexer ported from
  `scan.l`. Includes PostgreSQL 16 numeric literals and junk rules, nested
  comments, every string form, dollar quotes, the operator trailing `+`/`-`
  rule, token diagnostics and a `standardConformingStrings` option.
- `SqlTokenKind.psqlMetaCommand` and `SqlTokenKind.psqlVariable` are
  **reserved** for a future `psqlMode` lexer option (psql backslash
  commands and `:var` interpolation). They are never produced in 0.1.
  They exist now so that adding psql support later is not a breaking
  change; handle them in exhaustive switches over `SqlTokenKind`.
- The full keyword table generated from `kwlist.h`, with
  `SqlKeywordCategory` and `isHighlightKeyword`.
- `SqlStatementSplitter`: psql-compatible splitting ported from
  `psqlscan.l`, with `BEGIN ATOMIC` bodies, `COPY ... FROM STDIN` data
  blocks and `statementAtOffset`.
- `SqlStatementAnalyzer` / `StatementAnalysis`: statement kind, `writes`,
  `cannotRunInTransactionBlock` and `SafetyFinding`s. Fails closed.
  `cannotRunInTransactionBlock` follows the server's
  `PreventInTransactionBlock()` call sites, including `DISCARD ALL` and
  `COMMIT/ROLLBACK PREPARED`.
- `resolveDefaults` follows libpq's `conninfo_add_defaults()`: the `PG*`
  table matches `PQconninfoOptions` in `fe-connect.c` (adds
  `sslkeylogfile`, and `oauth_ca_file`/`PGOAUTHCAFILE` from PostgreSQL
  19), the deprecated `PGREQUIRESSL=1` means `sslmode=require`, and
  `sslrootcert=system` raises the default sslmode to `verify-full`.
- Integration tests against PostgreSQL 13 to 18 (`dart test -P
  integration`, `test/docker/compose.yml`). The `postgres` driver is a dev
  dependency only; the package still has no runtime dependencies.
- `LICENSE` (BSD-3-Clause), `SECURITY.md`, `CONTRIBUTING.md`, issue and
  pull request templates, and `tool/check.sh`.
- Entry points: `dbase_postgresql.dart`, `connection_string.dart` and
  `sql.dart`.

### Security

- Parse errors, `toString()` and `redacted()` never contain passwords or
  other secret keywords. CR/LF are percent-encoded in `redacted()`.
- NUL is rejected, both raw and as `%00`.
- Keyword names must look like keywords, so a mistyped URI scheme can't
  turn a password into a stored parameter name. The mutation fuzzer found
  this before release.
