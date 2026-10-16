// File: splitter_conformance_test.dart
// Purpose: Checks SqlStatementSplitter against a real server. For each
// script in the corpus below:
//   1. the whole script runs through the simple query protocol, where the
//      server does its own splitting (so the script itself is valid);
//   2. our split returns the expected number of statements;
//   3. each statement we return runs on its own through the extended query
//      protocol, and preparable ones also pass SQL `PREPARE`.
// The extended protocol's Parse message rejects a string holding more than
// one command (42601, "cannot insert multiple commands into a prepared
// statement"), and a statement cut in the wrong place fails to parse. So
// when every piece is accepted and the pieces tile the script, our
// statement count is the server's statement count.
//
// Everything runs inside BEGIN ... ROLLBACK, so the server is left clean
// and the test also works through PgBouncer in transaction mode.
// Run with `dart test -P integration` and DBASE_PG_URL set.
@Tags(['integration'])
library;

import 'package:dbase_postgresql/sql.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

import 'support/pg_server.dart';

/// One script of the conformance corpus.
final class _Script {
  const _Script(
    this.name,
    this.sql,
    this.statements, {
    this.minVersion = 130000,
  });

  final String name;
  final String sql;

  /// How many statements psql (and the server) see in [sql].
  final int statements;

  /// The lowest `server_version_num` that accepts [sql].
  final int minVersion;
}

// Rules exercised, from src/fe_utils/psqlscan.l and
// src/backend/parser/scan.l: `;` ends a statement only at paren depth 0,
// outside quotes, comments and dollar quotes, and outside BEGIN ... END of
// a CREATE FUNCTION/PROCEDURE body (begin_depth).
const _corpus = <_Script>[
  _Script(
    'plain statements and quoted semicolons',
    'CREATE TABLE dbase_it_t (id int PRIMARY KEY, body text);\n'
        "INSERT INTO dbase_it_t VALUES (1, 'a;b'), (2, E'c\\';d');\n"
        "SELECT * FROM dbase_it_t WHERE body <> 'x;y';\n"
        "UPDATE dbase_it_t SET body = 'z' WHERE id = 1;\n"
        'DELETE FROM dbase_it_t WHERE id = 2',
    5,
  ),
  _Script(
    'dollar quotes',
    'CREATE FUNCTION dbase_it_f() RETURNS int LANGUAGE plpgsql AS \$\$\n'
        'BEGIN\n  RETURN 1; -- ; inside\nEND\n\$\$;\n'
        r'SELECT $tag$ ; $$ ; $tag$ AS t, dbase_it_f();'
        '\n'
        r'DO $do$ BEGIN PERFORM 1; END $do$;'
        '\n'
        r'SELECT $a$$b$$a$;',
    4,
  ),
  _Script(
    'nested and line comments',
    '/* outer /* inner ; */ still ; */ SELECT 1;\n'
        '-- a line comment ; here\n'
        'SELECT /* ; */ 2 -- trailing ;\n;\n'
        '/* only a comment ; */',
    2,
  ),
  _Script(
    'parentheses, arrays and casts',
    "SELECT (SELECT 1); SELECT ARRAY[1, 2]::int[]; SELECT 'a' || ';' ;\n"
        'SELECT f.x FROM (VALUES (1), (2)) AS f(x) WHERE f.x IN (1, 2);',
    4,
  ),
  _Script(
    'quoted identifiers and string prefixes',
    'CREATE TABLE "dbase;it" ("a;b" int);\n'
        'INSERT INTO "dbase;it" VALUES (1);\n'
        r"SELECT U&'d\0061t', B'101', X'1F', N'n', E'\n;', 'it''s;';",
    3,
  ),
  _Script(
    'BEGIN ATOMIC function and procedure bodies',
    'CREATE TABLE dbase_it_t2 (a int);\n'
        'CREATE FUNCTION dbase_it_atomic(a int) RETURNS int LANGUAGE sql\n'
        'BEGIN ATOMIC\n'
        '  SELECT CASE WHEN a > 0 THEN a ELSE 0 END;\n'
        'END;\n'
        'CREATE PROCEDURE dbase_it_proc() LANGUAGE sql\n'
        'BEGIN ATOMIC\n'
        '  INSERT INTO dbase_it_t2 VALUES (1);\n'
        '  INSERT INTO dbase_it_t2 VALUES (CASE WHEN true THEN 2 END);\n'
        'END;\n'
        'CALL dbase_it_proc();\n'
        'SELECT dbase_it_atomic(5);',
    5,
    minVersion: 140000,
  ),
  _Script(
    'data-modifying CTE and savepoints',
    'CREATE TABLE dbase_it_t3 (a int);\n'
        'SAVEPOINT s1;\n'
        'WITH d AS (INSERT INTO dbase_it_t3 VALUES (1) RETURNING *) '
        'SELECT * FROM d;\n'
        'RELEASE SAVEPOINT s1',
    4,
  ),
  _Script(
    'PostgreSQL 16 numeric literals',
    'SELECT 0x1F, 0o17, 0b101, 1_000, 1_000.5e10;',
    1,
    minVersion: 160000,
  ),
];

/// Statement kinds that SQL `PREPARE` accepts (src/backend/parser/gram.y,
/// PreparableStmt). MERGE is preparable from PostgreSQL 15.
const Set<StatementKind> _preparable = {
  StatementKind.select,
  StatementKind.insert,
  StatementKind.update,
  StatementKind.delete,
};

void main() {
  const splitter = SqlStatementSplitter();
  const analyzer = SqlStatementAnalyzer();

  group('splitter agrees with the server', () {
    late pg.Connection connection;
    late int version;

    setUpAll(() async {
      connection = await openTestConnection();
      version = await serverVersionNum(connection);
    });

    tearDownAll(() => connection.close());

    Future<void> inRolledBackTransaction(Future<void> Function() body) async {
      await connection.execute('BEGIN');
      try {
        await body();
      } finally {
        await connection.execute('ROLLBACK');
      }
    }

    for (final script in _corpus) {
      test(script.name, () async {
        if (version < script.minVersion) {
          markTestSkipped('needs server_version_num >= ${script.minVersion}');
          return;
        }

        // 1. The server accepts the whole script (simple protocol).
        await inRolledBackTransaction(() async {
          await connection.execute(
            script.sql,
            queryMode: pg.QueryMode.simple,
            ignoreRows: true,
          );
        });

        // 2. Our statement count.
        final statements = splitter.split(script.sql);
        expect(statements, hasLength(script.statements));

        // 3. Each piece is exactly one statement the server accepts.
        await inRolledBackTransaction(() async {
          for (final (index, statement) in statements.indexed) {
            final kind = analyzer.analyzeStatement(statement).kind;
            if (_preparable.contains(kind)) {
              await connection.execute(
                'PREPARE dbase_it_p$index AS ${statement.text}',
              );
              await connection.execute('DEALLOCATE dbase_it_p$index');
            }
            try {
              await connection.execute(
                statement.text,
                queryMode: pg.QueryMode.extended,
                ignoreRows: true,
              );
            } on pg.ServerException catch (e) {
              fail(
                'statement #$index (${kind.name}, offsets '
                '${statement.start}..${statement.end}) was rejected: '
                'SQLSTATE ${e.code} ${e.message}',
              );
            }
          }
        });
      });
    }
  }, skip: skipReason);
}
