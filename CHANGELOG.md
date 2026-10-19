# Changelog

## 0.7.0 (unreleased)

### Changed

- Renamed the package from `dbase_postgresql` to `dabase_postgresql`
  (the app is now DaBase). Imports change from
  `package:dbase_postgresql/…` to `package:dabase_postgresql/…`, and the
  entry file is now `dabase_postgresql.dart`. No API changes. The package
  was never published under the old name.

## 0.6.0 (unreleased)

### Added

- `package:dabase_postgresql/psql.dart`, also exported from
  `dabase_postgresql.dart`: psql's console logic, pure Dart, ported from
  psql 18 (PostgreSQL License).
  - `parseMetaCommand`: backslash commands as `psqlscanslash.l` reads
    them: the name runs to whitespace or the next `\`, arguments split on
    unquoted whitespace, `'…'` with `''` and backslash escapes, `"…"`
    kept for name patterns, `\\` ends the command, backquotes refused.
    `MetaArg.value(semicolon: true)` strips unquoted trailing `;`;
    `sqlIdentifier()` dequotes and lower-cases.
  - `PsqlInputScanner`: psql's line handling. SQL collects in a query
    buffer until a top-level `;`; a `\` outside quotes and comments
    starts a command anywhere on a line; `\g` / `\gx` send (or repeat)
    the buffer, `\p` shows it, `\r` clears it; `promptState` gives the
    `%R` continuation character.
  - `patternToRegex` / `processNamePattern`: `\d` name patterns (`*`,
    `?`, `"Exact"`, `schema.name`, `db.schema.name`) to the same
    `OPERATOR(pg_catalog.~) '^(…)$' COLLATE pg_catalog.default` clauses
    and errors as psql's `processSQLNamePattern`.
  - `runDescribe` with `DescribeContext`: `\d[S+] [pattern]` (relation
    lists, and full table/view/index/sequence descriptions with indexes,
    constraints, references, policies, statistics, rules, publications,
    triggers, partitions and inheritance), `\dt \di \dv \dm \ds \dE`,
    `\df[anptw]` with argument-type patterns, `\dn`, `\du`/`\dg`, `\dx`,
    `\dT`, `\dD`, `\dp`/`\z` and `\l`, with `S`, `+` and `x`. Single
    read-only catalog SELECTs through a `PsqlQuery` callback,
    version-gated for PostgreSQL 13–18. The list builders
    (`listTablesSql`, …) are public and produce psql's SQL text.
  - `printTable` / `PrintTable` / `PrintOptions`: psql's aligned output
    (centred headers, `-+-` rules, numeric columns right-aligned by type
    OID, `(N rows)`, multi-line `+` marks, border 0/1/2, title, footer,
    tuples only), the wrapped format to a target width, expanded
    (`\x on|auto`) records, unaligned and CSV; `\pset null`. Display
    width follows psql's `ucs_wcwidth` tables (CJK and emoji take two
    columns, combining marks none, control characters escaped).
  - `PsqlConsole`: `\x`, `\timing`, `\pset` (format, border, columns,
    expanded, footer, null, title, tuples_only, fieldsep,
    csv_fieldsep), `\a`, `\t`, `\echo`, `\?`, `\conninfo`, `\q`, psql's
    `extra argument ignored` warnings and `invalid command` errors;
    `\copy`, `\!`, `\gexec`, `\i`, `\o`, `\e`, `\set` and friends are
    refused with a reason (`unsupportedCommands`).
  - `formatServerMessage`: errors and notices as psql prints them
    (`ERROR:  …`, `LINE n:` with the excerpt cut to about 60 columns
    and a `^` under the position, DETAIL, HINT); `formatTiming` for
    `\timing`; `formatConnInfo` (no password); `serverVersionNumber`.
- `package:dabase_postgresql/dump.dart`, also exported from
  `dabase_postgresql.dart`: plain-SQL export and restore helpers, pure
  Dart.
  - `SqlDumper` runs a pg_dump-like export over any `DumpConnection`:
    one `REPEATABLE READ, READ ONLY` transaction with pg_dump's settings
    (empty search_path, ISO dates, `extra_float_digits 3`, hex bytea,
    UTC, `row_security off`, 5 s lock wait, 2 min per statement),
    `ACCESS SHARE` locks on every dumped table before definitions are
    read, then pre-data, table data and post-data. Data is read through
    a `SCROLL` cursor in batches sized to about 4 MB and re-encoded as
    COPY text; a batch cut by the connection's memory cap is stepped
    back (`MOVE BACKWARD`) and read again in smaller batches, and a cut
    value fails the dump (`DumpRowTooLargeException`), never a silently
    corrupted file. Progress, per-table status, `checkpoint` and
    `isCancelled` hooks; errors roll back.
  - `DumpPlanner`: pg_dump's sections. Pre-data (schemas, extensions,
    types, routines, aggregates, sequences, tables, views, materialized
    views `WITH NO DATA`, sequence OWNED BY) in `pg_depend` order with
    object-type priority and name as tie-breakers; a column DEFAULT
    that calls a function caught in a cycle with its table becomes an
    `ALTER TABLE ... SET DEFAULT` after both; other cycles are written in
    priority order and reported. Data in foreign-key order plus
    `setval` (identity sequences through `pg_get_serial_sequence`).
    Post-data: indexes (partitioned ones recursing), keys, other
    constraints, foreign keys, triggers, rules, statistics, row-level
    security and policies, materialized view refreshes, comments and,
    optionally, grants and default privileges. No ownership. Schema
    only, data only, or both; `visibleRowsOnly` for tables whose
    row-level security applies to the exporting role (otherwise their
    data is left out and reported). Warnings as codes
    (`DumpWarningCode`).
  - `DumpWriter`: header comment (no host, user or connection string),
    pg_dump's SET preamble, `-- Name: …; Type: …; Schema: …` TOC
    comments, COPY blocks.
  - `encodeCopyTextRow` / `CopyTextEncoder` (COPY text format, as
    `CopyAttributeOutText` escapes) and `decodeCopyTextRow`.
  - `dependencyOrder`: deterministic topological sort with a
    comparator, cycles cut and reported (iterative Tarjan).
  - `SqlScriptReader`: streams a plain-SQL file (ours or pg_dump's) into
    statements, COPY data chunks of whole lines and backslash commands
    (`\restrict`/`\unrestrict` marked ignorable), with line numbers and
    the last TOC entry; any chunking gives the same items.
- `package:dabase_postgresql/catalog.dart`: `CatalogQuery` / `CatalogRow`,
  the catalog text parsers (`pgBool`, `pgInt`, `pgDouble`,
  `pgTextArray`, `requireText`, `oidArrayLiteral`) and `CatalogReader`,
  which reads a schema or table scope in bulk (one statement per kind,
  about 25 in all, version-gated for PostgreSQL 13–18) into an
  immutable `SchemaModel` with normalized `pg_depend` edges and counts
  of what a dump skips (large objects, publications, subscriptions,
  event triggers, foreign servers and tables, base types, collations,
  operators, text search configurations, extension configuration data).
- `package:dabase_postgresql/ddl.dart`: the DDL recipe queries, row
  parsers and assemblers of the DaBase app's object viewer, moved here
  (tables, views, materialized views, routines, sequences, indexes).
  Recipe queries take one OID or an OID array (`OidFilter`) and return a
  `relid` column; `TableDdlAssembler.parts` and `ViewDdlAssembler.parts`
  split the same statements by dump section. New: enum, composite, range
  and domain types (`TypeDdlAssembler`), `createAggregateStatement`,
  `createSchemaStatement`, `createExtensionStatement`,
  `defaultPrivilegeStatements`.
- `quoteIdent`, `qualifiedName`, `quoteLiteral`, `reloptionEntry`,
  `fdwOptionEntry` and `dollarQuote` in `package:dabase_postgresql/sql.dart`
  (moved from the DaBase app).

## 0.5.0 (unreleased)

### Added

- `package:dabase_postgresql/csv.dart`, also exported from
  `dabase_postgresql.dart`: CSV import for PostgreSQL, pure Dart.
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
  `package:dabase_postgresql/sql.dart`: mask secrets before SQL is stored
  (query history, logs). In `CREATE`/`ALTER` statements the string after
  `PASSWORD` (roles, users, groups; plaintext, SCRAM or MD5) and after a
  `password`/`sslpassword` option (`CREATE|ALTER SERVER`, `USER MAPPING
  ... OPTIONS`) becomes `'********'`; in any string constant, `password=`
  in a libpq connection string and the password of a
  `postgres://user:password@host` URI become `********`. Lexical, best
  effort; everything else is returned unchanged.
- `package:dabase_postgresql/binary.dart`, also exported from
  `dabase_postgresql.dart`:
  - `decodeByteaText`: `bytea` text output in hex (`\x…`) and escape
    format to bytes; `allowTruncated` accepts values cut by a client size
    cap. `bytesToHex` for the reverse.
  - `detectBinaryKind`: PNG, JPEG, GIF, WebP, BMP, HEIF, AVIF, PDF, ZIP,
    gzip, zstd and SQLite by magic bytes, with MIME type and extension.
  - `readImageSize`: an image's declared width and height from its header
    (PNG, GIF, JPEG, WebP, BMP, HEIF/AVIF) without decoding, so callers
    can refuse decompression bombs.
- `package:dabase_postgresql/geo.dart`, also exported from
  `dabase_postgresql.dart`: `decodeEwkbHex` / `decodeEwkb` decode PostGIS
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

- `package:dabase_postgresql/explain.dart`, also exported from
  `dabase_postgresql.dart`: an `EXPLAIN (FORMAT JSON)` analyzer for
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

- `package:dabase_postgresql/importers.dart`, also exported from
  `dabase_postgresql.dart`.
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
- Entry points: `dabase_postgresql.dart`, `connection_string.dart` and
  `sql.dart`.

### Security

- Parse errors, `toString()` and `redacted()` never contain passwords or
  other secret keywords. CR/LF are percent-encoded in `redacted()`.
- NUL is rejected, both raw and as `%00`.
- Keyword names must look like keywords, so a mistyped URI scheme can't
  turn a password into a stored parameter name. The mutation fuzzer found
  this before release.
