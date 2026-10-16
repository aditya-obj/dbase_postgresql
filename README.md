# dbase_postgresql

A pure-Dart PostgreSQL toolkit with no runtime dependencies. It doesn't
use Flutter or `dart:io`, so it runs on Android, iOS, web, desktop and the
server.

It is the in-house library behind **dbase**, an Android-first PostgreSQL
client that connects from the device straight to the database. Version
0.1 contains the parts a client needs before it opens a socket:

| Area | Entry point | What it does |
|---|---|---|
| Connection strings | `package:dbase_postgresql/connection_string.dart` | Parses `postgres://` URIs and libpq `key=value` strings with libpq semantics. Resolves `PG*` defaults on request, reports security warnings and formats output that is safe to log. |
| SQL lexer | `package:dbase_postgresql/sql.dart` | Lossless PostgreSQL tokenizer ported from `scan.l`. It never throws and reports lexical errors as diagnostics. |
| Statement splitter | same | Splits a script the way `psql` does, including `BEGIN ATOMIC` bodies and `COPY ... FROM STDIN` data. Also answers "which statement is under the cursor". |
| Safety analyzer | same | Classifies statements and flags `UPDATE`/`DELETE` without `WHERE`, `DROP`, `TRUNCATE`, `EXPLAIN ANALYZE` of writes and more. It fails closed. |

`package:dbase_postgresql/dbase_postgresql.dart` exports everything.

> Status: 0.1.0, not published yet (`publish_to: none` until the
> repository URL is decided). Licensed under BSD-3-Clause (see `LICENSE`).
> Material ported from PostgreSQL and libpg_query keeps its own license;
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
and are never produced in 0.1; handle them in exhaustive switches so
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
  `... CONCURRENTLY`, `ALTER SYSTEM`, tablespaces, `DISCARD ALL`,
  `COMMIT/ROLLBACK PREPARED`, and so on. Subscription commands and
  `REINDEX`/`CLUSTER` of partitioned tables depend on server state and
  are not detected.
- `findings`: `SafetyFinding(code, severity, message, offset)` with
  severities `info`, `warning` and `danger`.
- **Fails closed.** Unterminated tokens, malformed numbers, unbalanced
  parentheses, unrecognised statements and multiple statements passed to
  `analyze` all give `unknown`, with a `danger` finding.

**Limitation:** the analysis is lexical. A `SELECT` can still write
through volatile functions (`nextval`, `pg_terminate_backend`, user
functions). Use a `READ ONLY` transaction when read-only must be
guaranteed.

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
`test/third_party/`. Each case that deliberately diverges carries a
`diverges:` reason. Treat these corpora as the specification: change the
code to satisfy them, never the expectations to satisfy the code.
