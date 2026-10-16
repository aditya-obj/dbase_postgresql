// File: transaction_block_conformance_test.dart
// Purpose: Checks StatementAnalysis.cannotRunInTransactionBlock against the
// server. Each statement runs inside BEGIN ... ROLLBACK; the server raises
// SQLSTATE 25001 (active_sql_transaction) exactly for the statements that
// call PreventInTransactionBlock() (src/backend/access/transam/xact.c).
// The analyzer must predict that, case by case.
//
// Statements that fail for other reasons (a missing object, missing
// privileges) are fine: only "25001 or not" is compared. The server runs
// PreventInTransactionBlock() before looking objects up for every
// statement listed here (src/backend/tcop/utility.c, commands/vacuum.c,
// commands/indexcmds.c, commands/dbcommands.c, commands/discard.c,
// commands/cluster.c / repack.c), so nothing needs to exist.
//
// Not covered, because the server's answer depends on state the lexer
// cannot see (documented limits of the analyzer): CREATE/ALTER/DROP
// SUBSCRIPTION with replication slots, and REINDEX or CLUSTER of a
// partitioned table.
//
// Run with `dart test -P integration` and DBASE_PG_URL set. Needs a
// superuser-like role only for the setup objects (a table, an index and a
// partitioned table, all prefixed dbase_it_ and dropped afterwards).
@Tags(['integration'])
library;

import 'package:dbase_postgresql/sql.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

import 'support/pg_server.dart';

/// SQLSTATE active_sql_transaction (src/backend/utils/errcodes.txt).
const _activeSqlTransaction = '25001';

/// One statement with the lowest server version that knows its syntax.
typedef _Case = ({String sql, int minVersion});

_Case _c(String sql, [int minVersion = 130000]) =>
    (sql: sql, minVersion: minVersion);

/// Statements the server refuses inside a transaction block.
final _refused = <_Case>[
  _c('VACUUM'),
  _c('VACUUM dbase_it_tx'),
  _c('VACUUM (ANALYZE) dbase_it_tx'),
  _c('VACUUM FULL dbase_it_tx'),
  _c('CREATE DATABASE dbase_it_db'),
  _c('DROP DATABASE dbase_it_db'),
  _c('DROP DATABASE IF EXISTS dbase_it_db'),
  _c('CREATE INDEX CONCURRENTLY dbase_it_tx_c ON dbase_it_tx (a)'),
  _c('CREATE UNIQUE INDEX CONCURRENTLY dbase_it_tx_u ON dbase_it_tx (a)'),
  _c('DROP INDEX CONCURRENTLY dbase_it_tx_i'),
  _c('REINDEX TABLE CONCURRENTLY dbase_it_tx'),
  _c('REINDEX INDEX CONCURRENTLY dbase_it_tx_i'),
  _c('REINDEX DATABASE {db}'),
  _c('REINDEX SYSTEM {db}'),
  _c("ALTER SYSTEM SET work_mem = '4MB'"),
  _c("CREATE TABLESPACE dbase_it_ts LOCATION '/nonexistent'"),
  _c('DROP TABLESPACE dbase_it_ts'),
  _c('ALTER DATABASE dbase_it_db SET TABLESPACE pg_default'),
  _c(
    'ALTER TABLE dbase_it_parent DETACH PARTITION dbase_it_child '
    'CONCURRENTLY',
    140000,
  ),
  _c('CLUSTER'),
  _c('CLUSTER VERBOSE'),
  _c('DISCARD ALL'),
  _c("COMMIT PREPARED 'dbase_it_gid'"),
  _c("ROLLBACK PREPARED 'dbase_it_gid'"),
];

/// Statements the server allows inside a transaction block.
final _allowed = <_Case>[
  _c('SELECT 1'),
  _c('ANALYZE dbase_it_tx'),
  _c('CREATE INDEX dbase_it_tx_n ON dbase_it_tx (a)'),
  _c('DROP INDEX dbase_it_tx_i'),
  _c('REINDEX TABLE dbase_it_tx'),
  _c('REINDEX INDEX dbase_it_tx_i'),
  _c('CLUSTER dbase_it_tx USING dbase_it_tx_i'),
  _c('ALTER DATABASE dbase_it_db SET work_mem = 1024'),
  _c('REFRESH MATERIALIZED VIEW dbase_it_mv'),
  _c('DISCARD PLANS'),
  _c('DISCARD TEMP'),
  _c('DISCARD SEQUENCES'),
  _c('ALTER TABLE dbase_it_parent DETACH PARTITION dbase_it_child'),
  _c('CREATE TABLE dbase_it_new (a int)'),
  _c('DROP TABLE dbase_it_tx'),
  _c('TRUNCATE dbase_it_tx'),
  _c("ALTER TYPE dbase_it_enum ADD VALUE 'c'"),
  _c('LOCK TABLE dbase_it_tx'),
  _c('SAVEPOINT s'),
];

const _createChild =
    'CREATE TABLE dbase_it_child PARTITION OF dbase_it_parent '
    'FOR VALUES FROM (0) TO (10)';

const _setup = <String>[
  'DROP TABLE IF EXISTS dbase_it_tx, dbase_it_parent CASCADE',
  'DROP TYPE IF EXISTS dbase_it_enum',
  'CREATE TABLE dbase_it_tx (a int)',
  'CREATE INDEX dbase_it_tx_i ON dbase_it_tx (a)',
  'CREATE TABLE dbase_it_parent (a int) PARTITION BY RANGE (a)',
  _createChild,
  "CREATE TYPE dbase_it_enum AS ENUM ('a', 'b')",
];

const _teardown = [
  'DROP TABLE IF EXISTS dbase_it_tx, dbase_it_parent CASCADE',
  'DROP TYPE IF EXISTS dbase_it_enum',
];

void main() {
  const analyzer = SqlStatementAnalyzer();

  group('cannotRunInTransactionBlock agrees with SQLSTATE 25001', () {
    late pg.Connection connection;
    late int version;
    late String database;

    setUpAll(() async {
      connection = await openTestConnection();
      version = await serverVersionNum(connection);
      final row = await connection.execute('SELECT current_database()::text');
      database = row.single.single! as String;
      for (final sql in _setup) {
        await connection.execute(sql);
      }
    });

    tearDownAll(() async {
      for (final sql in _teardown) {
        await connection.execute(sql);
      }
      await connection.close();
    });

    /// Runs [sql] inside BEGIN ... ROLLBACK and returns the SQLSTATE of
    /// the error it raised, or `null` when it succeeded.
    Future<String?> stateInTransaction(String sql) async {
      await connection.execute('BEGIN');
      try {
        await connection.execute(sql, queryMode: pg.QueryMode.simple);
        return null;
      } on pg.ServerException catch (e) {
        return e.code;
      } finally {
        await connection.execute('ROLLBACK');
      }
    }

    for (final (cases, refused) in [(_refused, true), (_allowed, false)]) {
      for (final c in cases) {
        test('${refused ? 'refused' : 'allowed'}: ${c.sql}', () async {
          if (version < c.minVersion) {
            markTestSkipped('needs server_version_num >= ${c.minVersion}');
            return;
          }
          final sql = c.sql.replaceAll('{db}', '"$database"');
          final predicted = analyzer.analyze(sql).cannotRunInTransactionBlock;
          final state = await stateInTransaction(sql);
          printOnFailure('server SQLSTATE: ${state ?? 'none (succeeded)'}');
          expect(
            state == _activeSqlTransaction,
            refused,
            reason: 'server behaviour differs from this test case',
          );
          expect(predicted, refused, reason: 'analyzer disagrees with server');
        });
      }
    }
  }, skip: skipReason);
}
