// File: sql_statement_analyzer_test.dart
// Purpose: Unit tests for SqlStatementAnalyzer: classification, WHERE
// detection, CTEs, EXPLAIN ANALYZE, transaction-block rules, fail-closed.

import 'package:dbase_postgresql/sql.dart';
import 'package:test/test.dart';

const _analyzer = SqlStatementAnalyzer();

StatementAnalysis _a(String sql) => _analyzer.analyze(sql);

List<SafetyFindingCode> _codes(String sql) =>
    _a(sql).findings.map((f) => f.code).toList();

void main() {
  group('classification', () {
    final cases = <String, StatementKind>{
      'SELECT 1': StatementKind.select,
      'select * from t;': StatementKind.select,
      'VALUES (1), (2)': StatementKind.select,
      'TABLE t': StatementKind.select,
      '(SELECT 1) UNION (SELECT 2)': StatementKind.select,
      'INSERT INTO t VALUES (1)': StatementKind.insert,
      'UPDATE t SET a = 1 WHERE id = 2': StatementKind.update,
      'DELETE FROM t WHERE id = 2': StatementKind.delete,
      'MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE':
          StatementKind.merge,
      'CREATE TABLE t (id int)': StatementKind.ddl,
      'ALTER TABLE t ADD COLUMN b int': StatementKind.ddl,
      'DROP VIEW v': StatementKind.ddl,
      "COMMENT ON TABLE t IS 'x'": StatementKind.ddl,
      'GRANT SELECT ON t TO r': StatementKind.ddl,
      'REVOKE ALL ON t FROM r': StatementKind.ddl,
      'TRUNCATE t': StatementKind.truncate,
      'BEGIN': StatementKind.transactionControl,
      'START TRANSACTION READ ONLY': StatementKind.transactionControl,
      'COMMIT': StatementKind.transactionControl,
      'ROLLBACK TO SAVEPOINT s': StatementKind.transactionControl,
      'SAVEPOINT s': StatementKind.transactionControl,
      'RELEASE s': StatementKind.transactionControl,
      'END': StatementKind.transactionControl,
      'ABORT': StatementKind.transactionControl,
      "PREPARE TRANSACTION 'x'": StatementKind.transactionControl,
      'VACUUM t': StatementKind.maintenance,
      'ANALYZE t': StatementKind.maintenance,
      'REINDEX TABLE t': StatementKind.maintenance,
      'CLUSTER t USING i': StatementKind.maintenance,
      'CHECKPOINT': StatementKind.maintenance,
      'REFRESH MATERIALIZED VIEW mv': StatementKind.maintenance,
      'SET search_path = public': StatementKind.utility,
      'SHOW work_mem': StatementKind.utility,
      'RESET ALL': StatementKind.utility,
      'EXPLAIN SELECT 1': StatementKind.utility,
      'LISTEN ch': StatementKind.utility,
      "NOTIFY ch, 'x'": StatementKind.utility,
      'LOCK TABLE t': StatementKind.utility,
      'PREPARE q AS SELECT 1': StatementKind.utility,
      'DEALLOCATE q': StatementKind.utility,
      'DISCARD ALL': StatementKind.utility,
      '   ': StatementKind.empty,
      '-- just a comment': StatementKind.empty,
      'FOO BAR': StatementKind.unknown,
      '42': StatementKind.unknown,
    };
    for (final MapEntry(key: sql, value: kind) in cases.entries) {
      test('$sql -> ${kind.name}', () => expect(_a(sql).kind, kind));
    }

    test('read-only statements', () {
      for (final sql in ['SELECT 1', 'SHOW x', 'EXPLAIN DELETE FROM t']) {
        expect(_a(sql).isReadOnly, isTrue, reason: sql);
      }
    });
  });

  group('UPDATE / DELETE without WHERE', () {
    test('DELETE without WHERE is flagged at the DELETE keyword', () {
      final a = _a('  DELETE FROM t');
      expect(a.findings.single.code, SafetyFindingCode.deleteWithoutWhere);
      expect(a.findings.single.offset, 2);
      expect(a.requiresConfirmation, isTrue);
    });

    test('UPDATE without WHERE is flagged', () {
      expect(_codes('UPDATE t SET a = 1'), [
        SafetyFindingCode.updateWithoutWhere,
      ]);
    });

    test('DELETE ... WHERE true is not flagged', () {
      expect(_a('DELETE FROM t WHERE true').findings, isEmpty);
    });

    test('WHERE CURRENT OF counts as a WHERE', () {
      expect(_a('DELETE FROM t WHERE CURRENT OF c').findings, isEmpty);
    });

    test('a WHERE only inside a subquery still flags', () {
      expect(_codes('UPDATE t SET a = (SELECT b FROM u WHERE u.id = 1)'), [
        SafetyFindingCode.updateWithoutWhere,
      ]);
      expect(_codes('DELETE FROM t USING (SELECT * FROM u WHERE x) s'), [
        SafetyFindingCode.deleteWithoutWhere,
      ]);
    });

    test('a WHERE inside a comment does not count', () {
      expect(_codes('DELETE FROM t /* WHERE id = 1 */'), [
        SafetyFindingCode.deleteWithoutWhere,
      ]);
      expect(_codes('DELETE FROM t -- WHERE id = 1'), [
        SafetyFindingCode.deleteWithoutWhere,
      ]);
    });

    test('a WHERE inside a string literal does not count', () {
      expect(_codes("UPDATE t SET note = 'WHERE id = 1'"), [
        SafetyFindingCode.updateWithoutWhere,
      ]);
      expect(_codes(r'UPDATE t SET note = $$ WHERE $$'), [
        SafetyFindingCode.updateWithoutWhere,
      ]);
    });

    test('a quoted identifier named "where" does not count', () {
      expect(_codes('DELETE FROM "where"'), [
        SafetyFindingCode.deleteWithoutWhere,
      ]);
    });
  });

  group('WITH clauses', () {
    test('classified by the main statement', () {
      expect(
        _a('WITH x AS (SELECT 1) SELECT * FROM x').kind,
        StatementKind.select,
      );
      expect(
        _a('WITH x AS (SELECT 1) DELETE FROM t WHERE id IN (TABLE x)').kind,
        StatementKind.delete,
      );
    });

    test('CTE delete without WHERE is flagged', () {
      final a = _a('WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d');
      expect(a.kind, StatementKind.select);
      expect(a.writes, isTrue);
      expect(a.findings.map((f) => f.code), [
        SafetyFindingCode.dataModifyingCte,
        SafetyFindingCode.deleteWithoutWhere,
      ]);
    });

    test('a WHERE inside a CTE does not cover the main UPDATE', () {
      expect(
        _codes('WITH x AS (SELECT id FROM u WHERE ok) UPDATE t SET a = 1'),
        [SafetyFindingCode.updateWithoutWhere],
      );
    });

    test('RECURSIVE, column lists, MATERIALIZED and SEARCH clauses', () {
      final a = _a(
        'WITH RECURSIVE t(n) AS NOT MATERIALIZED (VALUES (1) UNION ALL '
        'SELECT n + 1 FROM t WHERE n < 5) SEARCH DEPTH FIRST BY n, m SET o, '
        '"y" AS MATERIALIZED (INSERT INTO log VALUES (1) RETURNING 1) '
        'SELECT * FROM t',
      );
      expect(a.kind, StatementKind.select);
      expect(a.writes, isTrue);
      expect(a.hasFinding(SafetyFindingCode.dataModifyingCte), isTrue);
    });

    test('malformed WITH fails closed', () {
      final a = _a('WITH x SELECT 1');
      expect(a.kind, StatementKind.unknown);
      expect(a.writes, isTrue);
      expect(a.findings.first.code, SafetyFindingCode.unparseable);
    });
  });

  group('EXPLAIN', () {
    test('plain EXPLAIN of a DELETE is read-only with no findings', () {
      final a = _a('EXPLAIN DELETE FROM t');
      expect(a.writes, isFalse);
      expect(a.findings, isEmpty);
    });

    test('EXPLAIN ANALYZE of a DELETE writes and is flagged', () {
      final a = _a('EXPLAIN ANALYZE DELETE FROM t');
      expect(a.writes, isTrue);
      expect(a.findings.map((f) => f.code), [
        SafetyFindingCode.explainAnalyzeWrites,
        SafetyFindingCode.deleteWithoutWhere,
      ]);
    });

    test('option-list forms', () {
      expect(
        _a('EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET a = 1 WHERE x').writes,
        isTrue,
      );
      expect(_a('EXPLAIN (ANALYZE false) DELETE FROM t').writes, isFalse);
      expect(_a("EXPLAIN (ANALYZE 'off') DELETE FROM t").writes, isFalse);
      expect(_a('EXPLAIN (FORMAT JSON) DELETE FROM t').writes, isFalse);
      expect(_a('EXPLAIN (ANALYZE maybe) DELETE FROM t').writes, isTrue);
      expect(
        _a('EXPLAIN VERBOSE ANALYSE INSERT INTO t VALUES (1)').writes,
        isTrue,
      );
    });

    test('EXPLAIN ANALYZE of a SELECT stays read-only', () {
      final a = _a('EXPLAIN ANALYZE SELECT 1');
      expect(a.writes, isFalse);
      expect(a.findings, isEmpty);
    });

    test('EXPLAIN ANALYZE EXECUTE fails closed', () {
      expect(_a('EXPLAIN ANALYZE EXECUTE q').writes, isTrue);
    });
  });

  group('DDL findings', () {
    test('DROP TABLE and DROP DATABASE', () {
      expect(_codes('DROP TABLE t'), [SafetyFindingCode.dropObject]);
      final db = _a('DROP DATABASE prod');
      expect(db.findings.single.code, SafetyFindingCode.dropDatabase);
      expect(db.cannotRunInTransactionBlock, isTrue);
    });

    test('ALTER TABLE DROP COLUMN, with or without COLUMN', () {
      expect(_codes('ALTER TABLE t DROP COLUMN a'), [
        SafetyFindingCode.alterTableDropColumn,
      ]);
      expect(_codes('ALTER TABLE t DROP a, DROP IF EXISTS b'), [
        SafetyFindingCode.alterTableDropColumn,
        SafetyFindingCode.alterTableDropColumn,
      ]);
    });

    test('ALTER TABLE drops that are not column drops', () {
      expect(_codes('ALTER TABLE t DROP CONSTRAINT c'), isEmpty);
      expect(_codes('ALTER TABLE t ALTER COLUMN a DROP NOT NULL'), isEmpty);
      expect(_codes('ALTER TABLE t ALTER a DROP DEFAULT'), isEmpty);
    });

    test('GRANT and REVOKE are warnings', () {
      final a = _a('GRANT ALL ON t TO public');
      expect(a.findings.single.code, SafetyFindingCode.grantRevoke);
      expect(a.highestSeverity, SafetySeverity.warning);
      expect(a.requiresConfirmation, isFalse);
    });

    test('ALTER TYPE ... ADD VALUE warns', () {
      expect(_codes("ALTER TYPE mood ADD VALUE 'meh'"), [
        SafetyFindingCode.alterTypeAddValue,
      ]);
    });

    test('TRUNCATE is dangerous', () {
      expect(_a('TRUNCATE t CASCADE').requiresConfirmation, isTrue);
    });
  });

  group('cannotRunInTransactionBlock', () {
    for (final sql in [
      'VACUUM',
      'VACUUM FULL t',
      'CREATE DATABASE d',
      'DROP DATABASE d',
      'CREATE INDEX CONCURRENTLY i ON t (a)',
      'CREATE UNIQUE INDEX CONCURRENTLY i ON t (a)',
      'DROP INDEX CONCURRENTLY i',
      'REINDEX TABLE CONCURRENTLY t',
      'REINDEX DATABASE d',
      'ALTER SYSTEM SET work_mem = 1',
      "CREATE TABLESPACE ts LOCATION '/x'",
      'DROP TABLESPACE ts',
      'ALTER TABLE p DETACH PARTITION c CONCURRENTLY',
      'ALTER DATABASE d SET TABLESPACE ts',
      'CLUSTER',
      'CLUSTER VERBOSE',
    ]) {
      test(sql, () => expect(_a(sql).cannotRunInTransactionBlock, isTrue));
    }

    for (final sql in [
      'CREATE INDEX i ON t (a)',
      'REINDEX TABLE t',
      'CLUSTER t',
      'REFRESH MATERIALIZED VIEW CONCURRENTLY mv',
      'ALTER DATABASE d SET work_mem = 1',
    ]) {
      test(
        'not: $sql',
        () => expect(_a(sql).cannotRunInTransactionBlock, isFalse),
      );
    }
  });

  group('SELECT side effects', () {
    test('SELECT INTO writes', () {
      final a = _a('SELECT * INTO new_t FROM t');
      expect(a.writes, isTrue);
      expect(a.findings.single.code, SafetyFindingCode.selectInto);
    });

    test('FOR UPDATE is noted', () {
      expect(_codes('SELECT * FROM t FOR UPDATE'), [
        SafetyFindingCode.rowLocking,
      ]);
      expect(_codes('SELECT * FROM t FOR NO KEY UPDATE SKIP LOCKED'), [
        SafetyFindingCode.rowLocking,
      ]);
    });

    test('INTO inside a subquery is not SELECT INTO', () {
      expect(_a('SELECT (SELECT 1) FROM t').writes, isFalse);
    });
  });

  group('utility statements', () {
    test('DO, CALL, EXECUTE are opaque and writing', () {
      for (final sql in [r'DO $$ BEGIN END $$', 'CALL p()', 'EXECUTE q']) {
        final a = _a(sql);
        expect(a.writes, isTrue, reason: sql);
        expect(a.findings.single.code, SafetyFindingCode.opaqueExecution);
      }
    });

    test('COPY directions', () {
      expect(_a('COPY t TO STDOUT').writes, isFalse);
      expect(_a('COPY t (a, b) FROM STDIN').writes, isTrue);
      expect(_a("COPY t TO '/tmp/x'").writes, isTrue);
      expect(_codes("COPY t FROM PROGRAM 'cat x'"), [
        SafetyFindingCode.opaqueExecution,
      ]);
    });

    test('COPY (query) TO STDOUT inherits the query', () {
      expect(_a('COPY (SELECT 1) TO STDOUT').writes, isFalse);
      final a = _a('COPY (DELETE FROM t RETURNING *) TO STDOUT');
      expect(a.writes, isTrue);
      expect(a.hasFinding(SafetyFindingCode.deleteWithoutWhere), isTrue);
    });

    test('COPY without direction fails closed', () {
      expect(_a('COPY t').kind, StatementKind.unknown);
    });
  });

  group('fail closed', () {
    test('unterminated string', () {
      final a = _a("DELETE FROM t WHERE name = 'x");
      expect(a.kind, StatementKind.unknown);
      expect(a.writes, isTrue);
      expect(a.findings.single.code, SafetyFindingCode.unterminated);
      expect(a.findings.single.severity, SafetySeverity.danger);
    });

    test('unterminated trailing comment', () {
      expect(
        _a('SELECT 1 /* oops').findings.single.code,
        SafetyFindingCode.unterminated,
      );
    });

    test('unbalanced parentheses', () {
      expect(_codes('DELETE FROM t WHERE (a = 1'), [
        SafetyFindingCode.unparseable,
      ]);
      expect(_codes('SELECT 1)'), [SafetyFindingCode.unparseable]);
    });

    test('malformed number', () {
      expect(_codes('DELETE FROM t WHERE id = 1abc'), [
        SafetyFindingCode.unparseable,
      ]);
    });

    test('unknown statements require confirmation', () {
      final a = _a('FROBNICATE everything');
      expect(a.requiresConfirmation, isTrue);
      expect(a.isReadOnly, isFalse);
    });

    test('multiple statements are unknown with merged findings', () {
      final a = _a('SELECT 1; DELETE FROM t');
      expect(a.kind, StatementKind.unknown);
      expect(a.findings.map((f) => f.code), [
        SafetyFindingCode.multipleStatements,
        SafetyFindingCode.deleteWithoutWhere,
      ]);
      expect(a.findings.first.offset, 10);
    });
  });

  test('analyzeStatement reports script-relative offsets', () {
    const script = 'SELECT 1;\nUPDATE t SET a = 1;';
    final statements = const SqlStatementSplitter().split(script);
    final a = _analyzer.analyzeStatement(statements.last);
    expect(a.findings.single.offset, 10);
  });
}
