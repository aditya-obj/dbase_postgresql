# dabase_postgresql

A pure-Dart PostgreSQL toolkit with no runtime dependencies. It doesn't
use Flutter or `dart:io`, so it runs on Android, iOS, web, desktop and the
server.

It is the in-house library behind **dabase**, an Android-first PostgreSQL
client that connects from the device straight to the database. It
contains the parts a client needs before it opens a socket:

| Area | Entry point | What it does |
|---|---|---|
| Connection strings | `package:dabase_postgresql/connection_string.dart` | Parses `postgres://` URIs and libpq `key=value` strings with libpq semantics. Resolves `PG*` defaults on request, reports security warnings and formats output that is safe to log. |
| Importers | `package:dabase_postgresql/importers.dart` | Reads `.pgpass`, `pg_service.conf` and pgAdmin `servers.json` with libpq's and pgAdmin's own rules. Reports per-line diagnostics and never echoes passwords. |
| SQL lexer | `package:dabase_postgresql/sql.dart` | Lossless PostgreSQL tokenizer ported from `scan.l`. It never throws and reports lexical errors as diagnostics. `redactSecrets` masks passwords before SQL is stored. |
| Statement splitter | same | Splits a script the way `psql` does, including `BEGIN ATOMIC` bodies and `COPY ... FROM STDIN` data. Also answers "which statement is under the cursor". |
| Safety analyzer | same | Classifies statements and flags `UPDATE`/`DELETE` without `WHERE` (or with `WHERE true`), `DROP`, `TRUNCATE`, risky `MERGE`, `EXPLAIN ANALYZE` of writes, ways out of a read-only session, `LOCK` and side-effect functions. Names the affected tables. It fails closed. |
| EXPLAIN analyzer | `package:dabase_postgresql/explain.dart` | Parses `EXPLAIN (FORMAT JSON)` output, computes self time and cost per node, ranks the top issues, and builds version-safe `EXPLAIN` options. |
| Binary values | `package:dabase_postgresql/binary.dart` | Decodes `bytea` text output (hex and escape formats), detects common file formats by magic bytes and reads image sizes from headers without decoding. |
| PostGIS geometry | `package:dabase_postgresql/geo.dart` | Decodes the hex EWKB PostGIS prints for `geometry`/`geography` (and ISO WKB) into typed geometries with SRID and Z/M, rejecting malformed input safely. |
| CSV import | `package:dabase_postgresql/csv.dart` | Sniffs a file's encoding, delimiter and header, decodes records from a byte stream leniently, re-encodes them as canonical PostgreSQL CSV for `COPY ... FROM STDIN`, builds the `COPY` and `INSERT ... unnest` SQL, and pre-checks values against column types. |
| psql console | `package:dabase_postgresql/psql.dart` | psql's backslash-command parser and line handling, `\d`-style name patterns, the `describe.c` queries behind `\d`, `\dt`, `\df`, `\du`, `\l` and friends (PostgreSQL 13–18), and psql's aligned, wrapped, expanded, unaligned and CSV table printer. |
| Catalog | `package:dabase_postgresql/catalog.dart` | Reads a schema or table scope of the catalog in bulk (about 25 statements, PostgreSQL 13–18) into an immutable `SchemaModel` with `pg_depend` edges, through a `CatalogQuery` callback. |
| DDL | `package:dabase_postgresql/ddl.dart` | pg_dump-like DDL from catalog rows: tables, views, materialized views, routines, aggregates, sequences, indexes, types, domains, schemas, extensions, grants. |
| SQL export | `package:dabase_postgresql/dump.dart` | A pg_dump-style plain-SQL export over any connection (one snapshot, locks, dependency order, data as COPY text through a cursor) and a streaming reader for restoring plain-SQL files. |

`package:dabase_postgresql/dabase_postgresql.dart` exports everything.

> Status: 0.7.0 (unreleased), not published yet (`publish_to: none` until the
> repository URL is decided). Licensed under BSD-3-Clause (see `LICENSE`).
> Material ported from PostgreSQL, libpg_query and PEV2 keeps its own license;
> see `THIRD_PARTY_NOTICES`.

## Connection strings

```dart
import 'package:dabase_postgresql/connection_string.dart';

final config = PgConnectionConfig.parse(
  'postgres://alice:s3cret@db1:5432,db2:5433/shop?sslmode=verify-full',
);
config.hosts;           // [db1:5432, db2:5433]
config.database;        // 'shop'
config.redacted();      // postgresql://alice:****@db1:5432,db2:5433/shop?...
config.securityWarnings // [passwordInConnectionString]

PgConnectionConfig.parse("host=db port=5432 password='it\\'s'");
PgConnectionConfig.tryParse('not a connection string'); // null
```

- **Both grammars.** URIs support percent-decoding, bracketed IPv6 hosts
  (with zone ids), multi-host lists, query parameters and Unix-socket
  hosts (`%2Fvar%2Frun`, `?host=/path`). The libpq conninfo form supports
  quoted values with `\'` escapes.
- **Parallel host/port lists.** A single port applies to every host, and
  an empty item means the default. `PgHost.port` is `null` when no port
  was given, and `effectivePort` returns 5432 in that case.
- **SSL.** `SslMode` covers `disable` through `verify-full`. When
  `sslmode` is absent the libpq default `prefer` applies and
  `sslModeWasExplicit` is `false`. Upgrade with
  `copyWith(sslMode: SslMode.verifyFull)`. `ssl=true` means `require`.
- **Defaults.** Parsing never reads the environment.
  `resolveDefaults(environment: {...}, defaultUser: ...)` applies libpq's
  `PG*` variables, user and `dbname = user` fallbacks. It never defaults
  the database to `postgres`.
- **Secrets.** Errors (`PgConfigParseException`, with an `offset`) never
  repeat the input. `toString()` and `redacted()` mask passwords and other
  secret keywords. `toUri()` leaves secrets out unless you pass
  `includePassword: true`. NUL characters (raw or `%00`) are rejected.
- **Unknown keywords** are kept in `parameters`.

Deliberate differences from libpq are listed in
[`doc/adr/0001-libpq-divergences.md`](doc/adr/0001-libpq-divergences.md).

## Importers

All three importers take the file's text. They never read the file
system or the environment, never run anything, and never put a password
in an error, a diagnostic or `toString()`.

```dart
import 'package:dabase_postgresql/importers.dart';

// .pgpass: libpq's matcher, first match wins.
final pgpass = PgPassFile.parse(text);
pgpass.lookup(host: 'db', port: 5432, database: 'shop', user: 'alice')
    ?.password;
pgpass.lookupForConfig(config);   // one result per host, like libpq
pgpass.entries;                   // for listing; entry.toConfig() drafts one
pgpass.diagnostics;               // PgLineDiagnostic<PgPassDiagnosticCode>

// pg_service.conf: every section, each valid or not.
final services = PgServiceFile.parse(text);
services.lookup('prod')?.config;  // PgConnectionConfig, or null if broken
final all = PgServiceFile.merge(user: userFile, system: systemFile);
service.applyTo(PgConnectionConfig.parse('dbname=other')); // string wins

// pgAdmin 4 servers.json, both layouts.
final export = PgAdminServersFile.parse(json);
for (final server in export.servers) {
  server.name; server.group; server.config; server.sshTunnel;
  server.warnings; // PgAdminWarning(code: PgAdminWarningCode.filePath, ...)
}
export.errors;     // entries pgAdmin's validation rejects
```

- **`.pgpass`** follows `passwordFromFile()`: `*` is a wildcard only as a
  whole field, `\` escapes `:` and `\`, only a `#` in column 0 starts a
  comment, and an empty host or the default socket directory means
  `localhost` (`127.0.0.1` does not match it). Like libpq, an unescaped
  `:` in the file also matches a `:` in the value looked up, so an
  unescaped IPv6 host still matches. File permissions are not checked;
  the caller decides.
- **`pg_service.conf`** follows `parseServiceFile()`: no whitespace before
  `=`, no inline comments, only libpq keywords, no nested `service=`, the
  first value of a keyword wins, only the first section of a name counts,
  and lines of 1023 bytes or more are an error. A section libpq would
  reject is kept with `isValid == false` and its diagnostics.
  `PgServiceFile.merge` lets the user file win per service name, as libpq
  does.
- **`servers.json`** reads the 6.20+ `ConnectionParameters` layout and the
  older flat keys (`SSLMode`, `HostAddr`, `Timeout`, ...), with pgAdmin's
  required-field rules. It maps `Name`, `Group`, the SSH tunnel, tags,
  colours and comments. It warns (typed `PgAdminWarningCode`) about
  file-path parameters, `Service`, Kerberos, `PasswordExecCommand` (never
  run, not kept) and `PostConnectionSQL` (kept, but flagged).

[`doc/adr/0001-libpq-divergences.md`](doc/adr/0001-libpq-divergences.md)
lists where the importers deliberately differ from libpq and pgAdmin.

## SQL lexer

```dart
import 'package:dabase_postgresql/sql.dart';

for (final token in const SqlLexer().tokenize(r"SELECT $1::int, 'a''b'")) {
  print('${token.kind.name} ${token.start}..${token.end}');
}
```

Token kinds cover whitespace, line comments, nested block comments,
`'...'`, `E'...'`, `U&'...'`, `B'...'`/`X'...'`, dollar quotes,
identifiers, quoted identifiers, keywords (the full `kwlist.h` table with
categories), `$n` parameters, PostgreSQL 16 numbers (`0x1F`, `1_000`),
operators and punctuation. The tokens tile the input exactly.
`token.diagnostic` reports `unterminated`, `malformedNumber` or
`malformedParameter` instead of throwing. Use `isHighlightKeyword(word,
categories: ...)` to choose which keyword categories an editor
highlights. Pass `SqlLexer(standardConformingStrings: false)` for servers
with that setting off.

The lexer is pure SQL: psql meta-commands (`\d`) and variables (`:var`)
are not recognised. `SqlTokenKind.psqlMetaCommand` and
`SqlTokenKind.psqlVariable` are reserved for a future `psqlMode` option
and are never produced yet; handle them in exhaustive switches so
adding psql support later is not a breaking change.

## Statement splitter

```dart
const splitter = SqlStatementSplitter();
final statements = splitter.split(script);          // List<SqlStatement>
final current = splitter.statementAtOffset(script, cursorOffset);
```

A `;` ends a statement only outside strings, comments and parentheses, and
outside `BEGIN ... END` blocks of `CREATE FUNCTION`/`PROCEDURE`. These are
psql's rules, ported from `psqlscan.l`. Comment-only statements are
skipped. Each `SqlStatement` has `text`, `start`/`end` offsets,
`terminatorOffset` and its tokens. For `COPY ... FROM STDIN` it also has
the inline data block (`copyDataStart`/`copyDataEnd`).

## Safety analyzer

```dart
const analyzer = SqlStatementAnalyzer();
final result = analyzer.analyze('WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d');
result.kind;                        // StatementKind.select
result.writes;                      // true
result.requiresConfirmation;        // true
result.findings.map((f) => f.code); // [dataModifyingCte, deleteWithoutWhere]
```

- `kind`: one of `select`, `insert`, `update`, `delete`, `merge`, `ddl`,
  `truncate`, `transactionControl`, `maintenance`, `utility`, `empty` or
  `unknown`.
- `writes` / `isReadOnly`. This accounts for data-modifying CTEs,
  `EXPLAIN ANALYZE`, `SELECT INTO`, `COPY` direction, and `DO`/`CALL`
  (counted as writing).
- `cannotRunInTransactionBlock`: `VACUUM`, `CREATE/DROP DATABASE`,
  `... CONCURRENTLY` (including `REINDEX (CONCURRENTLY)`), `REINDEX
  SCHEMA/DATABASE/SYSTEM`, `ALTER SYSTEM`, tablespaces, `DISCARD ALL`,
  `COMMIT/ROLLBACK PREPARED`, and so on. Subscription commands and
  `REINDEX`/`CLUSTER` of partitioned tables depend on server state and
  are not detected.
- `findings`: `SafetyFinding(code, severity, message, offset)` with
  severities `info`, `warning` and `danger`. Besides missing `WHERE`,
  `DROP`, `TRUNCATE` and the like, the codes cover:
  - `readOnlyEscape` (danger): `SET default_transaction_read_only = off`,
    `BEGIN READ WRITE`, `RESET ALL`, `DISCARD ALL`, `set_config(...)` on
    those settings, and other ways to undo a read-only session. Also
    exposed as `changesTransactionMode`.
  - `whereAlwaysTrue` (warning): `WHERE true`, `WHERE 1 = 1`, `WHERE x = x`
    and other literal tautologies.
  - `mergeUnrestricted` and `mergeDeletesUnmatched` (danger), and
    `mergeModifies` (warning) for any `MERGE`.
  - `explicitLock` (warning) with the parsed `lockMode` (`TableLockMode`,
    ordered by strength; a bare `LOCK t` is `ACCESS EXCLUSIVE`).
  - `sideEffectFunction` (warning): calls such as `pg_terminate_backend`,
    `pg_advisory_lock`, `dblink_exec`, `nextval` or `lo_import`. pg_cron
    job changes (`cron.schedule`, `cron.schedule_in_database`,
    `cron.unschedule`, `cron.alter_job`) get it too and also count as
    `writes`.
- `targets`: the tables or objects the statement changes, in the form the
  server resolves (`Public.Orders` gives `public.orders`, `"My Table"`
  gives `My Table`), for `UPDATE`/`DELETE`/`MERGE`, `TRUNCATE`, `DROP`,
  `ALTER TABLE` and `LOCK`. `dropObjectType` says what a `DROP` removes,
  and `cascades` is true for `TRUNCATE ... CASCADE` and `DROP ... CASCADE`.
- **Fails closed.** Unterminated tokens, malformed numbers, unbalanced
  parentheses, unrecognised statements and multiple statements passed to
  `analyze` all give `unknown`, with a `danger` finding.

**Limitation:** the analysis is lexical. A `SELECT` can still write
through volatile functions (`nextval`, `pg_terminate_backend`, user
functions); well-known built-ins are reported as `sideEffectFunction`, but
calls made inside user functions, views and `DO` bodies are not seen. Use
a `READ ONLY` transaction (and check the server's
`default_transaction_read_only` after each statement) when read-only must
be guaranteed.

### Redacting secrets

```dart
redactSecrets("ALTER ROLE app PASSWORD 's3cret'");
// ALTER ROLE app PASSWORD '********'
redactSecrets("SELECT dblink_connect('host=h password=pw')");
// SELECT dblink_connect('host=h password=********')
containsSecrets('SELECT 1'); // false
```

Use it before keeping SQL anywhere (history, logs). The result is for
storage and display only: running it would set `********` as the password.

## EXPLAIN plans

```dart
import 'package:dabase_postgresql/explain.dart';

const options = ExplainOptions(analyze: true); // BUFFERS, SETTINGS on
final sql = 'EXPLAIN ${options.toSql(serverVersionNum)} $statement';
// ... run it (ANALYZE executes: wrap it in BEGIN/ROLLBACK or a savepoint)

final plan = ExplainPlan.parse(jsonCell);    // FormatException if not a plan
final metrics = PlanMetrics.compute(plan);
for (final node in plan.nodes) {             // pre-order, nodes[i].id == i
  final m = metrics[node.id];
  print('${'  ' * node.depth}${node.displayName} ${node.target ?? ''} '
      '${m.selfMs} ms (${m.selfPercent} %)');
}
for (final issue in PlanIssues.find(plan, metrics)) {  // ≤ 3, ranked
  print('${issue.code.name} at node ${issue.nodeId}: ${issue.facts}');
}
```

- **Parsing.** `ExplainPlan.parseAll` reads every plan of the array.
  Nodes keep every raw key in `properties`, so new server keys still
  show up. `displayName` is composed the way the text format and PEV2
  show it (`Parallel Hash Left Join`, `Partial HashAggregate`, `Index
  Scan Backward`, `Update`). `analyzed`, `timed` and `hasBuffers` say
  which options the plan was run with. PostgreSQL 17 and 18 number
  formats parse alike, and `disabled` covers both 18's `Disabled` key
  and 17's `disable_cost`.
- **Metrics.** Inclusive time is `Actual Total Time × loops ÷ (workers
  launched + 1)`. Self time subtracts the children (not InitPlans, except
  under `Result`), moves a CTE's time out of the `CTE Scan`s that read it
  and an InitPlan's time out of the nodes that use its result, and is
  clamped at 0. `selfPercent` is of `Execution Time`. `selfCost` (for
  plan-only bars) is `Total Cost` minus the children's. `otherMs` is the
  execution time no node or trigger accounts for, when above 5 %.
- **Issues.** Each `PlanIssue` has a `code`, an optional `nodeId`, an
  `impact` (share of execution time a fix could save), a 0–5 `score`
  and `facts` (numbers and names such as `percent`, `ms`, `estimated`,
  `actual`, `column`, `setting`). Issues below 10 % impact are dropped,
  queries under 10 ms get none, and without `ANALYZE` only plan-only
  checks (disabled nodes) run. The library has no wording.
- **Options.** `ExplainOptions.toSql(serverVersionNum)` drops
  `GENERIC_PLAN` before 16, `SERIALIZE`/`MEMORY` before 17, `WAL`,
  `SERIALIZE` and `TIMING OFF` without `ANALYZE`, and `GENERIC_PLAN`
  with it. It sends `BUFFERS` explicitly so 13–17 match 18.

The metrics are ported from [PEV2](https://github.com/dalibo/pev2)
(`plan-service.ts`), and PEV2's test plans run in
`test/explain/pev2_metrics_test.dart`.

## CSV import

```dart
import 'package:dabase_postgresql/csv.dart';

final sniff = sniffCsv(first64k);        // encoding, delimiter, header
if (sniff.confidence < 0.6) { /* ask the user to check */ }

final writer = CopyCsvWriter();
await for (final record in file.transform(
  CsvDecoder(sniff.dialect, encoding: sniff.encoding),
)) {
  if (record.isHeader) continue;         // number 0
  writer.add([fieldValue(record, 0), fieldValue(record, 2)]);
}
final sql = copyFromStdinSql('public', 'orders', ['qty', 'note'],
    serverVersionNum: 170000);
// COPY "public"."orders" ("qty", "note") FROM STDIN (FORMAT csv)
send(sql, writer.takeBytes());
```

- **Sniffing.** `sniffCsv` reads a byte order mark (UTF-8, UTF-16 LE/BE),
  else spots UTF-16 by its zero bytes, else takes UTF-8 when the bytes
  are valid and Windows-1252 when not. The delimiter is the candidate
  (`,` `;` tab `|`) with the most consistent field count above one; an
  Excel `sep=X` first line wins. The header is guessed from names that
  match `knownColumns`, or a first row of distinct non-empty text above
  typed data. `confidence` below 0.6 means "ask"; `notes` say why.
- **Decoding.** `CsvDecoder` is a streaming transformer with lenient
  RFC 4180 rules: CRLF, LF and CR line ends (mixed), a quote inside an
  unquoted field is literal (`5" pipe`), text after a closing quote is
  kept and noted, empty lines are skipped, and a BOM and `sep=` line are
  stripped. Each `CsvRecord` has its fields, which were quoted (so `""`
  can stay an empty string while an empty field is NULL), its record
  number and the physical line it starts on. Malformed input throws a
  `CsvFormatException` subtype with the line (unterminated quote, size
  limits from `CsvLimits`, and invalid bytes in strict decoding).
- **Values.** `fieldValue` applies PostgreSQL's rule (unquoted empty is
  NULL, `""` is empty text) or `EmptyFieldRule.alwaysNull` /
  `emptyString`, plus an optional NULL marker such as `\N`.
- **Encoding for COPY.** `CopyCsvWriter` (and the `CopyCsvEncoder`
  transformer) write UTF-8 with LF line ends, NULL as an unquoted empty
  field, an empty string as `""`, and quotes only when needed (delimiter,
  quote, CR, LF, leading or trailing space or tab, and a value equal to
  `\.`). `add` returns the physical lines a record took, because the
  server counts line breaks inside quoted values when it reports an
  error's line.
- **SQL.** `copyFromStdinSql` quotes every name and adds `ON_ERROR
  ignore` (17+) and `REJECT_LIMIT` (18+) only on servers that know them.
  `insertFromUnnestSql` and `pgArrayLiteral` build the fallback for
  tables where COPY is refused (row-level security): one `text[]`
  parameter per column, each element cast to its column type.
- **Checks.** `checkPgText(type, value)` pre-checks integers (with
  range), numeric and floats, booleans, uuid, json and ISO dates and
  timestamps; it returns `null` when only the server can tell.
  `inferPgType` proposes a column type for a new table that every sample
  value fits (`007` stays text).

## psql console

```dart
import 'package:dabase_postgresql/psql.dart';

final console = PsqlConsole();
for (final item in console.feedLine(r'select 1 as x; \d users')) {
  switch (item) {
    case PsqlQueryItem(:final sql):
      final result = await run(sql); // your connection
      print(printTable(
        PrintTable.fromResult(
          columns: result.columns,
          typeOids: result.typeOids,
          rows: result.rows,
          nullDisplay: console.options.nullDisplay,
        ),
        console.options,
      ));
    case PsqlMetaItem(:final command):
      if (console.run(command) case PsqlDescribeRequest()) {
        final outputs = await runDescribe(
          DescribeContext(version: 170002, query: catalogQuery),
          command,
        );
        // PsqlTableOutput -> printTable, PsqlMessageOutput -> text
      }
    case PsqlTextItem(:final text):
      print(text);
  }
}
```

- **Input.** `PsqlInputScanner` (inside `PsqlConsole`) follows psql's main
  loop: SQL collects in a buffer until a top-level `;` (not inside
  strings, comments, dollar quotes or parentheses), and a backslash
  outside those starts a command anywhere on the line. `\g`/`\gx` send
  or repeat the buffer, `\p` shows it, `\r` clears it, and
  `promptState` is psql's `%R` (`=`, `-`, `'`, `"`, `$`, `*`, `(`).
- **Commands.** `parseMetaCommand` reads names and arguments like
  `psqlscanslash.l`, including `'…'` escapes, kept `"…"` for patterns,
  `\\` terminators and trailing-semicolon stripping; backquotes (shell)
  are refused. `PsqlConsole.run` applies `\x`, `\timing`, `\pset`, `\a`,
  `\t`, `\echo` and `\?`, and hands describe commands, `\conninfo` and
  `\q` back to the caller. Commands that need a shell, files or
  variables are refused with a reason.
- **Describe.** `runDescribe` runs psql 18's `describe.c` queries through
  a `PsqlQuery` callback, as single read-only SELECTs, version-gated for
  PostgreSQL 13–18. Name patterns translate exactly as
  `processSQLNamePattern` does, with user text always quoted as SQL
  literals. Tests compare the generated SQL with what `psql -E` sends and
  the printed text with psql's own output.
- **Printing.** `printTable` reproduces psql's aligned format byte for
  byte (golden-tested against psql), plus wrapped (fit to
  `PrintOptions.columns`), expanded (`\x on`/`auto`), unaligned and CSV.
  Widths use psql's Unicode tables, so CJK and emoji line up.
- **Messages.** `formatServerMessage` prints errors and notices like psql,
  with the `LINE n:` excerpt and caret under the error position;
  `formatTiming` prints `\timing` lines.

## SQL export

`SqlDumper` writes a plain-SQL file that `psql -X -v ON_ERROR_STOP=1 -f`
restores, like `pg_dump --format=plain --no-owner`:

```dart
final result = await SqlDumper(
  connection: myConnection, // implements DumpConnection
  options: const DumpOptions(
    scope: CatalogScope.schemas([2200]), // or CatalogScope.tables([...])
    content: DumpContent.schemaAndData,
  ),
  write: (chunk) async => sink.write(chunk),
).run();
print('${result.rows} rows, failed: ${result.failedTables.length}');
```

- **Snapshot.** One `REPEATABLE READ, READ ONLY` transaction with
  pg_dump's settings; every dumped table gets an `ACCESS SHARE` lock
  before its definition is read, so schema changes wait for the export.
- **Catalog.** `CatalogReader` reads each kind of object with one
  statement (not one per object) into a `SchemaModel`; the DDL is
  assembled by the same code as the dabase object viewer.
- **Order.** Pre-data follows `pg_depend` (with type priority and name
  as tie-breakers); keys, foreign keys, indexes and triggers come after
  the data, so circular foreign keys need nothing special. A default
  that calls a function in a cycle with its table is split out; other
  cycles are reported (`DumpWarningCode.dependencyCycle`).
- **Data.** A `SCROLL` cursor is read in batches of about 4 MB and each
  row is re-encoded as COPY text (`encodeCopyTextRow`). The connection
  must never cut a value: `DumpConnection.fetch` throws instead, or
  reports a batch it could not hold (`FetchedRows.serverRows`) so the
  dump steps back and reads it again in smaller batches.
- **Row-level security.** With `row_security = off`, a table whose
  policies apply to the exporting role is left out and reported, unless
  `DumpOptions.visibleRowsOnly` asks for the rows that role can see.
- **Not covered:** ownership, roles, tablespaces, large objects,
  publications, subscriptions, event triggers, foreign servers and
  tables, C-language types and operators, collations, text search
  configurations; their counts are in `DumpResult.skipped` and the file
  header.

`SqlScriptReader` streams such a file (or pg_dump's plain format) back
as statements, COPY data in whole-line chunks and backslash commands,
with line numbers and the TOC entry each item belongs to.

## Development

```sh
tool/check.sh             # the full local gate: format, analyze, test, fuzz
dart format --set-exit-if-changed .
dart analyze --fatal-infos
dart test                 # unit, invariant and third-party corpus tests
dart test -P fuzz         # seeded mutation fuzzing (FUZZ_SEED to replay)
dart test -P integration  # against a real server (DABASE_PG_URL)
dart run example/main.dart
dart run tool/generate_keywords.dart path/to/kwlist.h   # refresh keywords
```

The integration tests compare the keyword table with
`pg_get_keywords()`, run every statement the splitter returns on the
server, and check `cannotRunInTransactionBlock` against SQLSTATE 25001.
`test/docker/compose.yml` starts PostgreSQL 13 to 18, a TLS server,
PgBouncer and an SSH server; see `test/docker/README.md`. The `postgres`
driver they use is a dev dependency only.

See `CONTRIBUTING.md` for the contribution rules and `SECURITY.md` for
reporting vulnerabilities.

The tests include libpq's `001_uri.pl` corpus (63 cases) and
libpg_query's split vectors, ported with their licenses under
`test/third_party/`, and PEV2's plan tests under `test/explain/`. Each case that deliberately diverges carries a
`diverges:` reason. Treat these corpora as the specification: change the
code to satisfy them, never the expectations to satisfy the code.
