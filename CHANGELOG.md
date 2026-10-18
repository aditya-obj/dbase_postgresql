# Changelog

## 0.5.0 (unreleased)

### Added

- `package:dbase_postgresql/csv.dart`, also exported from
  `dbase_postgresql.dart`: CSV import for PostgreSQL, pure Dart.
  - `sniffCsv`: encoding (BOM, UTF-16 by zero bytes, UTF-8 validity, else
    Windows-1252), delimiter (`,` `;` tab `|`, Excel's `sep=` line),
    header (known column names or names above typed data), the modal
    column count, a 0–1 `confidence` and `CsvSniffNote`s.
  - `CsvDecoder`: a streaming bytes → `CsvRecord` transformer with
    lenient RFC 4180 rules (mixed CRLF/LF/CR, literal quotes in unquoted
    fields, stray text after a closing quote kept, empty lines skipped,
    BOM and `sep=` stripped, optional escape character). Records keep
    which fields were quoted, their number and starting line. Typed
    `CsvFormatException`s with the line; `CsvLimits` cap field, record
    and field-count sizes; UTF-8, UTF-16 LE/BE, Windows-1252 and Latin-1
    (`CsvTextEncoding`), strict by default.
  - `fieldValue` with `EmptyFieldRule` (PostgreSQL's NULL vs `""` rule,
    always NULL, always empty) and an optional NULL marker.
  - `CopyCsvWriter` / `CopyCsvEncoder`: canonical PostgreSQL CSV for
    `COPY ... FROM STDIN` (UTF-8, LF, NULL unquoted empty, `""` empty
    string, `\.` quoted, quotes only when needed), with per-record line
    counts to map server error lines back to records.
  - `copyFromStdinSql` (version-gated `ON_ERROR ignore` and
    `REJECT_LIMIT`), `insertFromUnnestSql` and `pgArrayLiteral` for the
    row-level-security fallback.
  - `checkPgText` (client-side type pre-checks) and `inferPgType` (column
    types for a new table).
- `redactSecrets(sql)` and `containsSecrets(sql)` in
  `package:dbase_postgresql/sql.dart`: mask secrets before SQL is stored
  (query history, logs). In `CREATE`/`ALTER` statements the string after
  `PASSWORD` (roles, users, groups; plaintext, SCRAM or MD5) and after a
  `password`/`sslpassword` option (`CREATE|ALTER SERVER`, `USER MAPPING
  ... OPTIONS`) becomes `'********'`; in any string constant, `password=`
  in a libpq connection string and the password of a
  `postgres://user:password@host` URI become `********`. Lexical, best
  effort; everything else is returned unchanged.
- `package:dbase_postgresql/binary.dart`, also exported from
  `dbase_postgresql.dart`:
  - `decodeByteaText`: `bytea` text output in hex (`\x…`) and escape
    format to bytes; `allowTruncated` accepts values cut by a client size
    cap. `bytesToHex` for the reverse.
  - `detectBinaryKind`: PNG, JPEG, GIF, WebP, BMP, HEIF, AVIF, PDF, ZIP,
    gzip, zstd and SQLite by magic bytes, with MIME type and extension.
  - `readImageSize`: an image's declared width and height from its header
    (PNG, GIF, JPEG, WebP, BMP, HEIF/AVIF) without decoding, so callers
    can refuse decompression bombs.
- `package:dbase_postgresql/geo.dart`, also exported from
  `dbase_postgresql.dart`: `decodeEwkbHex` / `decodeEwkb` decode PostGIS
  EWKB (as `geometry_out` and `geography_out` print it) and ISO WKB into
  `Geometry` values (`GeoPoint`, `GeoLineString`, `GeoPolygon`, Multi*,
  `GeoCollection`) with SRID, Z/M ordinates and `GeoBounds`. Both byte
  orders; curved and surface types come back as `GeoUnsupported`.
  Malformed input throws `FormatException` without echoing it; counts are
  checked against the remaining bytes and nesting is capped at 32.

### Changed

- pg_cron job changes count as writes: `SELECT cron.schedule(...)`,
  `cron.schedule_in_database`, `cron.unschedule` and `cron.alter_job`
  (qualified with `cron.`) now set `StatementAnalysis.writes` and get a
  `sideEffectFunction` finding, so read-only sessions refuse them.

## 0.4.0 (unreleased)

### Added

- `package:dbase_postgresql/explain.dart`, also exported from
  `dbase_postgresql.dart`: an `EXPLAIN (FORMAT JSON)` analyzer for
  PostgreSQL 13–18.
  - `ExplainPlan.parse` / `ExplainPlan.parseAll`: typed plans
    (`PlanNode`, `NodeActuals`, `BufferCounts`, `TriggerTiming`,
    `JitSummary`). Nodes are numbered in pre-order, get a composed
    `displayName` (`Parallel Hash Left Join`, `Partial HashAggregate`,
    `Index Scan Backward`, `Update`) and a `target` label, and keep every
    raw key in `properties`. Numbers parse the same from PostgreSQL 17
    (`1000`) and 18 (`1000.00`). Disabled nodes are detected from
    `"Disabled": true` (18+) or `disable_cost` (17 and older). Bad input
    throws `FormatException` without repeating it.
  - `PlanMetrics.compute`: inclusive and self time per node (loops,
    parallel workers, CTE and InitPlan fix-ups), self cost, row totals,
    estimate factors, self buffers, trigger time and unattributed time.
  - `PlanIssues.find`: up to three ranked `PlanIssue`s (15
    `PlanIssueCode`s: slow node, row estimate, missing index, index
    filtering, sort/hash spills, many loops, lossy bitmap, heap fetches,
    cache misses, JIT, missing workers, planning time, trigger time,
    disabled nodes) with the numbers the app needs in `facts`. No
    wording: the app words issues from codes and facts. Thresholds are
    named constants.
  - `ExplainOptions.toSql(serverVersionNum)`: the option list, with
    options the server or the other options don't allow left out.
- The metrics are ported from PEV2 (PostgreSQL-style license); its test
  plans are in `test/explain/fixtures/`. See `THIRD_PARTY_NOTICES`.

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
