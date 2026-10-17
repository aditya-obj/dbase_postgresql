# dbase_postgresql

A pure-Dart PostgreSQL toolkit with no runtime dependencies. It doesn't
use Flutter or `dart:io`, so it runs on Android, iOS, web, desktop and the
server.

It is the in-house library behind **dbase**, an Android-first PostgreSQL
client that connects from the device straight to the database. It
contains the parts a client needs before it opens a socket:

| Area | Entry point | What it does |
|---|---|---|
| Connection strings | `package:dbase_postgresql/connection_string.dart` | Parses `postgres://` URIs and libpq `key=value` strings with libpq semantics. Resolves `PG*` defaults on request, reports security warnings and formats output that is safe to log. |
| Importers | `package:dbase_postgresql/importers.dart` | Reads `.pgpass`, `pg_service.conf` and pgAdmin `servers.json` with libpq's and pgAdmin's own rules. Reports per-line diagnostics and never echoes passwords. |
| SQL lexer | `package:dbase_postgresql/sql.dart` | Lossless PostgreSQL tokenizer ported from `scan.l`. It never throws and reports lexical errors as diagnostics. |
| Statement splitter | same | Splits a script the way `psql` does, including `BEGIN ATOMIC` bodies and `COPY ... FROM STDIN` data. Also answers "which statement is under the cursor". |
| Safety analyzer | same | Classifies statements and flags `UPDATE`/`DELETE` without `WHERE` (or with `WHERE true`), `DROP`, `TRUNCATE`, risky `MERGE`, `EXPLAIN ANALYZE` of writes, ways out of a read-only session, `LOCK` and side-effect functions. Names the affected tables. It fails closed. |
| EXPLAIN analyzer | `package:dbase_postgresql/explain.dart` | Parses `EXPLAIN (FORMAT JSON)` output, computes self time and cost per node, ranks the top issues, and builds version-safe `EXPLAIN` options. |

`package:dbase_postgresql/dbase_postgresql.dart` exports everything.

> Status: 0.4.0 (unreleased), not published yet (`publish_to: none` until the
> repository URL is decided). Licensed under BSD-3-Clause (see `LICENSE`).
> Material ported from PostgreSQL, libpg_query and PEV2 keeps its own license;
> see `THIRD_PARTY_NOTICES`.

## Connection strings

```dart
import 'package:dbase_postgresql/connection_string.dart';

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
import 'package:dbase_postgresql/importers.dart';

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
import 'package:dbase_postgresql/sql.dart';

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
    `pg_advisory_lock`, `dblink_exec`, `nextval` or `lo_import`.
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

## EXPLAIN plans

```dart
import 'package:dbase_postgresql/explain.dart';

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

## Development

```sh
tool/check.sh             # the full local gate: format, analyze, test, fuzz
dart format --set-exit-if-changed .
dart analyze --fatal-infos
dart test                 # unit, invariant and third-party corpus tests
dart test -P fuzz         # seeded mutation fuzzing (FUZZ_SEED to replay)
dart test -P integration  # against a real server (DBASE_PG_URL)
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
