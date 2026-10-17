// File: sql_statement_analyzer_guards_test.dart
// Purpose: Unit tests for the 0.3 analyzer guards: read-only escapes,
// LOCK, side-effect functions, always-true WHERE, MERGE findings, targets,
// CASCADE, two-phase commit writes and REINDEX transaction rules.

import 'package:dbase_postgresql/sql.dart';
import 'package:test/test.dart';

const _analyzer = SqlStatementAnalyzer();

StatementAnalysis _a(String sql) => _analyzer.analyze(sql);

List<SafetyFindingCode> _codes(String sql) =>
    _a(sql).findings.map((f) => f.code).toList();

const _using = 'MERGE INTO t USING s ';

// Statements too long for one line (lists can't hold adjacent strings).
const _long1 =
    'SET SESSION CHARACTERISTICS AS TRANSACTION ISOLATION LEVEL '
    'SERIALIZABLE, READ WRITE';
const _long2 =
    "SELECT set_config('default_' || 'transaction_read_only', 'off', "
    'false)';
const _long3 =
    "SELECT 1 FROM t WHERE set_config('transaction_read_only', 'off', "
    'true) IS NOT NULL';
const _long4 =
    "EXPLAIN ANALYZE SELECT set_config('default_transaction_read_only', "
    "'off', false)";
const _long5 =
    'WITH x AS (SELECT 1) '
    "SELECT set_config('default_transaction_read_only', 'off', false)";
const _long6 =
    "EXPLAIN SELECT set_config('default_transaction_read_only', 'off', "
    'false)';
const _long7 =
    'CREATE FUNCTION f() RETURNS void AS '
    r'$$ SELECT pg_terminate_backend(1) $$ LANGUAGE sql';
const _long8 =
    '${_using}ON (1 = 1) WHEN NOT MATCHED THEN INSERT VALUES (s.a) '
    'WHEN MATCHED THEN DELETE';
const _long9 =
    'MERGE INTO t USING s JOIN u ON s.id = u.id ON true '
    'WHEN MATCHED THEN DELETE';
const _long10 =
    'MERGE INTO t USING (SELECT * FROM s WHERE x) AS s ON true '
    'WHEN MATCHED THEN UPDATE SET a = CASE WHEN s.a THEN 1 END';
const _long11 =
    'WITH s AS (SELECT 1 AS a) '
    'MERGE INTO t USING s ON true WHEN MATCHED THEN DELETE';
const _long12 =
    'MERGE INTO t USING s JOIN u ON true ON t.id = s.id '
    'WHEN MATCHED THEN DELETE';
const _long13 =
    '${_using}ON t.id = s.id WHEN NOT MATCHED BY SOURCE AND t.old '
    'THEN DELETE';
const _long14 =
    '${_using}ON t.id = s.id WHEN MATCHED THEN UPDATE SET a = s.a '
    'WHEN NOT MATCHED BY SOURCE THEN DELETE';
const _long15 =
    '${_using}ON t.id = s.id WHEN NOT MATCHED BY SOURCE THEN '
    'UPDATE SET gone = true';
const _long16 =
    '${_using}ON t.id = s.id WHEN NOT MATCHED BY TARGET THEN '
    'INSERT VALUES (s.a)';
const _long17 =
    '${_using}ON t.id = s.id WHEN NOT MATCHED BY SOURCE AND '
    'CASE WHEN t.a THEN true END THEN DO NOTHING';

void main() {
  group('readOnlyEscape', () {
    for (final sql in [
      'SET default_transaction_read_only = off',
      'SET default_transaction_read_only TO OFF',
      'set Default_Transaction_Read_Only = false',
      "SET default_transaction_read_only = 'off'",
      'SET default_transaction_read_only = 0',
      'SET default_transaction_read_only = no',
      'SET default_transaction_read_only TO DEFAULT',
      'SET default_transaction_read_only = DEFAULT;',
      'SET SESSION default_transaction_read_only = off',
      'SET LOCAL transaction_read_only = off',
      'SET transaction_read_only TO false',
      'SET "default_transaction_read_only" = off',
      "SET default_transaction_read_only = E'on'",
      'SET default_transaction_read_only = on, off',
      'SET default_transaction_read_only = maybe',
      'SET SESSION CHARACTERISTICS AS TRANSACTION READ WRITE',
      _long1,
      'SET TRANSACTION READ WRITE',
      'SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ WRITE',
      'BEGIN READ WRITE',
      'BEGIN TRANSACTION ISOLATION LEVEL SERIALIZABLE, READ WRITE',
      'begin work read write',
      'START TRANSACTION READ WRITE',
      'RESET default_transaction_read_only',
      'RESET transaction_read_only',
      'RESET ALL',
      'DISCARD ALL',
      "SELECT set_config('default_transaction_read_only', 'off', false)",
      "SELECT pg_catalog.set_config('transaction_read_only', 'off', true)",
      "SELECT set_config('DEFAULT_TRANSACTION_READ_ONLY', 'off', false)",
      "select SET_CONFIG('default_transaction_read_only', 'off', false)",
      'SELECT set_config(name, value, false) FROM settings',
      _long2,
      r"SELECT set_config($$default_transaction_read_only$$, 'off', false)",
      "SELECT set_config(E'default_transaction_read_only', 'off', false)",
      "SELECT set_config('default_transaction_read_only', v, false) FROM t",
      _long3,
      _long4,
      _long5,
    ]) {
      test(sql, () {
        final a = _a(sql);
        expect(a.hasFinding(SafetyFindingCode.readOnlyEscape), isTrue);
        expect(a.changesTransactionMode, isTrue);
        expect(a.requiresConfirmation, isTrue);
      });
    }

    for (final sql in [
      'SET default_transaction_read_only = on',
      'SET default_transaction_read_only TO true',
      "SET default_transaction_read_only = 'on'",
      "SET default_transaction_read_only = 'YES'",
      'SET default_transaction_read_only = 1',
      'SET SESSION default_transaction_read_only = on;',
      'SET LOCAL transaction_read_only = on',
      'SET search_path = public',
      'SET work_mem TO DEFAULT',
      'SET SESSION CHARACTERISTICS AS TRANSACTION READ ONLY',
      'SET TRANSACTION ISOLATION LEVEL READ COMMITTED',
      'SET TRANSACTION READ ONLY',
      'SET SESSION AUTHORIZATION DEFAULT',
      'BEGIN',
      'BEGIN READ ONLY',
      'BEGIN ISOLATION LEVEL READ UNCOMMITTED',
      'START TRANSACTION READ ONLY',
      'COMMIT',
      'RESET search_path',
      'RESET SESSION AUTHORIZATION',
      'DISCARD PLANS',
      'DISCARD TEMP',
      "SELECT set_config('search_path', 'public', false)",
      "SELECT set_config('default_transaction_read_only', 'on', false)",
      "SELECT 'set_config(''default_transaction_read_only'', ''off'', f)'",
      r"SELECT $$ set_config('transaction_read_only', 'off', true) $$",
      "SELECT 1 /* set_config('transaction_read_only', 'off', true) */",
      "SELECT 1 -- set_config('transaction_read_only', 'off', true)",
      "SELECT \"set_config('transaction_read_only')\" FROM t",
      _long6,
      'SHOW default_transaction_read_only',
    ]) {
      test('not: $sql', () {
        final a = _a(sql);
        expect(a.hasFinding(SafetyFindingCode.readOnlyEscape), isFalse);
        expect(a.changesTransactionMode, isFalse);
      });
    }

    test('SET and BEGIN keep their kinds and do not count as writes', () {
      expect(
        _a('SET default_transaction_read_only = off').kind,
        StatementKind.utility,
      );
      final begin = _a('BEGIN READ WRITE');
      expect(begin.kind, StatementKind.transactionControl);
      expect(begin.writes, isFalse);
      expect(begin.findings.single.offset, 0);
    });

    test('an escaping set_config is not also a sideEffectFunction', () {
      expect(
        _codes(
          "SELECT set_config('default_transaction_read_only', 'off', false)",
        ),
        [SafetyFindingCode.readOnlyEscape],
      );
    });

    test('DISCARD ALL still cannot run in a transaction block', () {
      expect(_a('DISCARD ALL').cannotRunInTransactionBlock, isTrue);
    });

    test('several statements keep the flag', () {
      expect(
        _a('SELECT 1; SET default_transaction_read_only = off')
            .changesTransactionMode,
        isTrue,
      );
    });
  });

  group('explicitLock', () {
    final modes = <String, TableLockMode>{
      'LOCK t': TableLockMode.accessExclusive,
      'LOCK TABLE t': TableLockMode.accessExclusive,
      'LOCK TABLE t NOWAIT': TableLockMode.accessExclusive,
      'LOCK TABLE t IN ACCESS SHARE MODE': TableLockMode.accessShare,
      'lock table t in row share mode': TableLockMode.rowShare,
      'LOCK t IN ROW EXCLUSIVE MODE': TableLockMode.rowExclusive,
      'LOCK t IN SHARE UPDATE EXCLUSIVE MODE':
          TableLockMode.shareUpdateExclusive,
      'LOCK t IN SHARE MODE NOWAIT': TableLockMode.share,
      'LOCK t IN SHARE ROW EXCLUSIVE MODE': TableLockMode.shareRowExclusive,
      'LOCK t IN EXCLUSIVE MODE': TableLockMode.exclusive,
      'LOCK t IN ACCESS EXCLUSIVE MODE': TableLockMode.accessExclusive,
      'LOCK t IN SILLY MODE': TableLockMode.accessExclusive,
    };
    for (final MapEntry(key: sql, value: mode) in modes.entries) {
      test('$sql -> ${mode.name}', () {
        final a = _a(sql);
        expect(a.lockMode, mode);
        expect(a.findings.single.code, SafetyFindingCode.explicitLock);
        expect(a.findings.single.severity, SafetySeverity.warning);
        expect(a.findings.single.message, contains(mode.sql));
        expect(a.kind, StatementKind.utility);
        expect(a.writes, isFalse);
      });
    }

    test('lock modes are ordered by strength', () {
      expect(TableLockMode.values.map((m) => m.sql), [
        'ACCESS SHARE',
        'ROW SHARE',
        'ROW EXCLUSIVE',
        'SHARE UPDATE EXCLUSIVE',
        'SHARE',
        'SHARE ROW EXCLUSIVE',
        'EXCLUSIVE',
        'ACCESS EXCLUSIVE',
      ]);
      expect(
        _a('LOCK t IN SHARE MODE').lockMode!.index >
            TableLockMode.rowExclusive.index,
        isTrue,
      );
    });

    test('targets list every table', () {
      expect(_a('LOCK TABLE ONLY public.a, "B" *, c IN SHARE MODE').targets, [
        'public.a',
        'B',
        'c',
      ]);
    });

    test('other statements have no lockMode', () {
      expect(_a('SELECT * FROM t FOR UPDATE').lockMode, isNull);
      expect(_a("SELECT 'LOCK t'").findings, isEmpty);
    });
  });

  group('sideEffectFunction', () {
    for (final sql in [
      'SELECT pg_terminate_backend(123)',
      'SELECT pg_cancel_backend(pid) FROM pg_stat_activity',
      'SELECT pg_reload_conf()',
      'SELECT pg_rotate_logfile()',
      'SELECT pg_switch_wal()',
      'SELECT pg_promote()',
      "SELECT pg_create_restore_point('x')",
      'SELECT pg_advisory_lock(1)',
      'SELECT pg_advisory_lock_shared(1)',
      'SELECT pg_advisory_xact_lock(1, 2)',
      'SELECT pg_try_advisory_lock(1)',
      'SELECT pg_try_advisory_xact_lock_shared(1)',
      "SELECT pg_notify('ch', 'x')",
      "SELECT * FROM dblink('db', 'SELECT 1') AS t(a int)",
      "SELECT dblink_exec('db', 'UPDATE t SET a = 1')",
      "SELECT dblink_connect('c', 'dbname=x')",
      "SELECT set_config('work_mem', '1MB', false)",
      'SELECT pg_stat_reset()',
      'SELECT pg_stat_reset_shared(NULL)',
      "SELECT lo_import('/etc/passwd')",
      "SELECT lo_export(1, '/tmp/x')",
      'SELECT lo_unlink(1)',
      'SELECT lo_create(0)',
      'SELECT lo_creat(-1)',
      'SELECT lo_open(1, 131072)',
      r"SELECT lo_put(1, 0, '\x00')",
      "SELECT lo_from_bytea(0, 'x')",
      'SELECT lo_truncate(0, 1)',
      "SELECT pg_create_logical_replication_slot('s', 'pgoutput')",
      "SELECT pg_drop_replication_slot('s')",
      "SELECT nextval('s')",
      "SELECT setval('s', 1)",
      "SELECT pg_catalog.nextval('s')",
      "SELECT \"nextval\"('s')",
      "SELECT NEXTVAL('s')",
      "SELECT nextval ('s')",
      "SELECT a FROM t WHERE b = (SELECT max(nextval('s')))",
      "INSERT INTO t VALUES (nextval('s'))",
      "UPDATE t SET a = nextval('s') WHERE id = 1",
      'DELETE FROM t WHERE pg_try_advisory_lock(id) AND id = 1',
      "VALUES (setval('s', 1))",
      'WITH x AS (SELECT pg_terminate_backend(1)) SELECT * FROM x',
      "COPY (SELECT nextval('s')) TO STDOUT",
      "EXPLAIN ANALYZE SELECT nextval('s')",
      "CALL p(nextval('s'))",
    ]) {
      test(sql, () {
        final a = _a(sql);
        expect(a.hasFinding(SafetyFindingCode.sideEffectFunction), isTrue);
        expect(a.hasFinding(SafetyFindingCode.readOnlyEscape), isFalse);
      });
    }

    for (final sql in [
      "SELECT 'pg_terminate_backend(1)'",
      r"SELECT $$ nextval('s') $$",
      r'SELECT $f$ pg_reload_conf() $f$',
      'SELECT 1 /* pg_reload_conf() */',
      'SELECT 1 -- pg_reload_conf()',
      'SELECT "pg_reload_conf()" FROM t',
      'SELECT nextval FROM t',
      'SELECT * FROM pg_replication_slots',
      'SELECT pg_advisory_unlock(1)',
      'SELECT now()',
      'INSERT INTO lo_files (a) VALUES (1)',
      "EXPLAIN SELECT nextval('s')",
      "CREATE TABLE t (id int DEFAULT nextval('s'))",
      "ALTER TABLE t ALTER id SET DEFAULT nextval('s')",
      _long7,
      "PREPARE q AS SELECT nextval('s')",
    ]) {
      test('not: $sql', () {
        expect(
          _a(sql).hasFinding(SafetyFindingCode.sideEffectFunction),
          isFalse,
        );
      });
    }

    test('is a warning that does not change writes', () {
      final a = _a("SELECT nextval('s')");
      expect(a.findings.single.severity, SafetySeverity.warning);
      expect(a.findings.single.offset, 7);
      expect(a.writes, isFalse);
    });

    test('each call is reported', () {
      expect(_codes('SELECT pg_cancel_backend(1), pg_terminate_backend(2)'), [
        SafetyFindingCode.sideEffectFunction,
        SafetyFindingCode.sideEffectFunction,
      ]);
    });

    test('prefix families keep the message to fixed text', () {
      final message = _a('SELECT pg_advisory_lock_secret_suffix(1)')
          .findings
          .single
          .message;
      expect(message, contains('pg_advisory_lock*'));
      expect(message, isNot(contains('secret')));
    });
  });

  group('whereAlwaysTrue', () {
    for (final sql in [
      'DELETE FROM t WHERE true',
      'DELETE FROM t WHERE TRUE',
      "DELETE FROM t WHERE 't'",
      "DELETE FROM t WHERE 'true'",
      "DELETE FROM t WHERE 'yes'",
      "DELETE FROM t WHERE 'on'",
      "DELETE FROM t WHERE 't'::bool",
      "DELETE FROM t WHERE 'true'::boolean",
      'DELETE FROM t WHERE 1=1',
      'DELETE FROM t WHERE 1 = 1',
      'DELETE FROM t WHERE 42 = 42',
      'DELETE FROM t WHERE NOT false',
      'DELETE FROM t WHERE x = x',
      'DELETE FROM t WHERE "Col" = "Col"',
      'DELETE FROM t WHERE name = name',
      'DELETE FROM t WHERE (1 = 1)',
      'DELETE FROM t WHERE ((true))',
      'DELETE FROM t WHERE true RETURNING *',
      'UPDATE t SET a = 1 WHERE true',
      'UPDATE t SET a = 1 WHERE 1 = 1 RETURNING id',
      'UPDATE t SET a = 1 FROM s WHERE true',
      'WITH d AS (DELETE FROM t WHERE true RETURNING *) SELECT * FROM d',
      'EXPLAIN ANALYZE DELETE FROM t WHERE 1 = 1',
    ]) {
      test(sql, () {
        final a = _a(sql);
        expect(a.hasFinding(SafetyFindingCode.whereAlwaysTrue), isTrue);
        expect(a.hasFinding(SafetyFindingCode.deleteWithoutWhere), isFalse);
        expect(a.hasFinding(SafetyFindingCode.updateWithoutWhere), isFalse);
      });
    }

    for (final sql in [
      'DELETE FROM t WHERE id = 1',
      'DELETE FROM t WHERE a = b',
      'DELETE FROM t WHERE 1 = 2',
      'DELETE FROM t WHERE 1.0 = 1.0',
      'DELETE FROM t WHERE x = "X"',
      'DELETE FROM t WHERE NULL = NULL',
      'DELETE FROM t WHERE t.x = t.x',
      'DELETE FROM t WHERE false',
      "DELETE FROM t WHERE 'f'",
      'DELETE FROM t WHERE NOT true',
      'DELETE FROM t WHERE true AND id = 1',
      'DELETE FROM t WHERE 1 = 1 AND id = 1',
      'DELETE FROM t WHERE (1 = 1) OR id = 1',
      'DELETE FROM t WHERE x = x + 1',
      'DELETE FROM t WHERE CURRENT OF c',
      "DELETE FROM t WHERE 'true' = x",
      'DELETE FROM t WHERE id IN (SELECT id FROM t WHERE true)',
      "UPDATE t SET note = 'WHERE true' WHERE id = 1",
      'UPDATE t SET a = 1 WHERE id = 1 /* WHERE true */',
      'UPDATE t SET a = (SELECT 1 WHERE true) WHERE id = 2',
    ]) {
      test('not: $sql', () {
        expect(_a(sql).hasFinding(SafetyFindingCode.whereAlwaysTrue), isFalse);
      });
    }

    test('is a warning at the WHERE keyword', () {
      final a = _a('UPDATE t SET a = 1 WHERE 1 = 1');
      expect(a.findings.single.code, SafetyFindingCode.whereAlwaysTrue);
      expect(a.findings.single.severity, SafetySeverity.warning);
      expect(a.findings.single.offset, 19);
    });
  });

  group('MERGE', () {
    test('any MERGE is mergeModifies (warning)', () {
      final a = _a('${_using}ON t.id = s.id WHEN MATCHED THEN DELETE');
      expect(a.findings.single.code, SafetyFindingCode.mergeModifies);
      expect(a.findings.single.severity, SafetySeverity.warning);
      expect(a.findings.single.offset, 0);
      expect(a.requiresConfirmation, isFalse);
      expect(a.targets, ['t']);
    });

    for (final sql in [
      '${_using}ON true WHEN MATCHED THEN DELETE',
      '${_using}ON 1=1 WHEN MATCHED THEN UPDATE SET a = s.a',
      _long8,
      "${_using}ON 't' WHEN MATCHED THEN DELETE",
      '${_using}ON NOT false WHEN MATCHED THEN DELETE',
      _long9,
      _long10,
      _long11,
    ]) {
      test('unrestricted: $sql', () {
        final a = _a(sql);
        expect(a.hasFinding(SafetyFindingCode.mergeUnrestricted), isTrue);
        expect(a.hasFinding(SafetyFindingCode.mergeModifies), isTrue);
        expect(a.requiresConfirmation, isTrue);
      });
    }

    for (final sql in [
      '${_using}ON t.id = s.id WHEN MATCHED THEN DELETE',
      '${_using}ON true WHEN MATCHED AND s.del THEN DELETE',
      '${_using}ON true WHEN MATCHED THEN DO NOTHING',
      '${_using}ON true WHEN NOT MATCHED THEN INSERT VALUES (s.a)',
      '${_using}ON t.id = s.id AND true WHEN MATCHED THEN DELETE',
      '${_using}ON 1 = 2 WHEN MATCHED THEN DELETE',
      _long12,
      "${_using}ON t.id = s.id WHEN MATCHED THEN UPDATE SET n = 'ON true'",
    ]) {
      test('not unrestricted: $sql', () {
        expect(
          _a(sql).hasFinding(SafetyFindingCode.mergeUnrestricted),
          isFalse,
        );
      });
    }

    test('WHEN NOT MATCHED BY SOURCE ... THEN DELETE', () {
      for (final sql in [
        '${_using}ON t.id = s.id WHEN NOT MATCHED BY SOURCE THEN DELETE',
        _long13,
        _long14,
      ]) {
        final a = _a(sql);
        expect(
          a.hasFinding(SafetyFindingCode.mergeDeletesUnmatched),
          isTrue,
          reason: sql,
        );
        expect(a.requiresConfirmation, isTrue, reason: sql);
      }
      for (final sql in [_long15, _long16, _long17]) {
        expect(
          _a(sql).hasFinding(SafetyFindingCode.mergeDeletesUnmatched),
          isFalse,
          reason: sql,
        );
      }
    });

    test('finding order and offsets', () {
      const sql =
          '${_using}ON true WHEN MATCHED THEN DELETE '
          'WHEN NOT MATCHED BY SOURCE THEN DELETE';
      final a = _a(sql);
      expect(a.findings.map((f) => f.code), [
        SafetyFindingCode.mergeUnrestricted,
        SafetyFindingCode.mergeDeletesUnmatched,
        SafetyFindingCode.mergeModifies,
      ]);
      expect(a.findings[0].offset, sql.indexOf('ON true'));
      expect(a.findings[1].offset, sql.lastIndexOf('WHEN'));
    });
  });

  group('targets', () {
    final cases = <String, List<String>>{
      'UPDATE orders SET a = 1 WHERE id = 1': ['orders'],
      'UPDATE ONLY public.orders AS o SET a = 1': ['public.orders'],
      'UPDATE Public.Orders SET a = 1': ['public.orders'],
      'UPDATE "My Table" SET a = 1': ['My Table'],
      'UPDATE "a""b" SET a = 1': ['a"b'],
      'DELETE FROM t WHERE id = 1': ['t'],
      'DELETE FROM ONLY s."T" * WHERE id = 1': ['s.T'],
      'MERGE INTO app.t AS x USING s ON true WHEN MATCHED THEN DELETE': [
        'app.t',
      ],
      'TRUNCATE a': ['a'],
      'TRUNCATE TABLE ONLY a, public.b *, "C" RESTART IDENTITY CASCADE': [
        'a',
        'public.b',
        'C',
      ],
      'DROP TABLE a, b CASCADE': ['a', 'b'],
      'DROP TABLE IF EXISTS public.a': ['public.a'],
      'DROP INDEX CONCURRENTLY IF EXISTS i': ['i'],
      'DROP MATERIALIZED VIEW mv': ['mv'],
      'DROP SCHEMA s1, s2': ['s1', 's2'],
      'DROP DATABASE IF EXISTS prod WITH (FORCE)': ['prod'],
      'DROP FUNCTION f(int), g(text, int)': ['f', 'g'],
      'DROP TRIGGER trg ON t': ['trg'],
      'DROP OWNED BY r1, r2 CASCADE': ['r1', 'r2'],
      'DROP TEXT SEARCH CONFIGURATION cfg': ['cfg'],
      'DROP CAST (int AS text)': [],
      'DROP OPERATOR + (int, int)': [],
      'DROP FROBNICATOR x': [],
      'ALTER TABLE t ADD COLUMN b int': ['t'],
      'ALTER TABLE IF EXISTS ONLY public.t DROP COLUMN b': ['public.t'],
      'ALTER FOREIGN TABLE ft DROP COLUMN b': ['ft'],
      'ALTER TABLE ALL IN TABLESPACE a SET TABLESPACE b': [],
      'WITH d AS (DELETE FROM a RETURNING *) UPDATE b SET x = 1': ['a', 'b'],
      'EXPLAIN ANALYZE DELETE FROM t': ['t'],
      'EXPLAIN DELETE FROM t': [],
      'COPY (DELETE FROM t RETURNING *) TO STDOUT': ['t'],
      'SELECT * FROM t': [],
      'INSERT INTO t VALUES (1)': [],
      'CREATE TABLE t (a int)': [],
    };
    for (final MapEntry(key: sql, value: targets) in cases.entries) {
      test(sql, () => expect(_a(sql).targets, targets));
    }

    test('DROP object type', () {
      expect(_a('DROP TABLE t').dropObjectType, 'TABLE');
      expect(
        _a('drop materialized view mv').dropObjectType,
        'MATERIALIZED VIEW',
      );
      expect(
        _a('DROP OPERATOR CLASS c USING btree').dropObjectType,
        'OPERATOR CLASS',
      );
      expect(_a('DROP OPERATOR + (int, int)').dropObjectType, 'OPERATOR');
      expect(_a('DROP FROBNICATOR x').dropObjectType, isNull);
      expect(_a('TRUNCATE t').dropObjectType, isNull);
    });

    test('targets are unmodifiable', () {
      expect(() => _a('TRUNCATE a').targets.add('b'), throwsUnsupportedError);
    });

    test('several statements collect every target', () {
      expect(_a('DELETE FROM a; TRUNCATE b, c').targets, ['a', 'b', 'c']);
    });
  });

  group('CASCADE', () {
    test('TRUNCATE ... CASCADE', () {
      final a = _a('TRUNCATE t CASCADE');
      expect(a.cascades, isTrue);
      expect(a.findings.single.message, contains('foreign key'));
      expect(_a('TRUNCATE t').cascades, isFalse);
      expect(_a('TRUNCATE t RESTRICT').cascades, isFalse);
    });

    test('DROP ... CASCADE', () {
      final a = _a('DROP TABLE t CASCADE');
      expect(a.cascades, isTrue);
      expect(a.findings.single.code, SafetyFindingCode.dropObject);
      expect(a.findings.single.message, contains('depends'));
      expect(_a('DROP TABLE t').cascades, isFalse);
    });

    test('CASCADE in a string, comment or other statement does not count', () {
      expect(_a('DROP TABLE t -- CASCADE').cascades, isFalse);
      expect(_a('DROP TABLE "cascade"').cascades, isFalse);
      expect(_a('ALTER TABLE t DROP CONSTRAINT c CASCADE').cascades, isFalse);
      expect(_a("SELECT 'CASCADE'").cascades, isFalse);
    });
  });

  group('two-phase commit', () {
    test('COMMIT PREPARED and ROLLBACK PREPARED count as writing', () {
      for (final sql in ["COMMIT PREPARED 'gid'", "ROLLBACK PREPARED 'gid'"]) {
        final a = _a(sql);
        expect(a.writes, isTrue, reason: sql);
        expect(a.kind, StatementKind.transactionControl, reason: sql);
        expect(a.cannotRunInTransactionBlock, isTrue, reason: sql);
      }
    });

    test('PREPARE TRANSACTION, COMMIT and ROLLBACK do not', () {
      for (final sql in ["PREPARE TRANSACTION 'gid'", 'COMMIT', 'ROLLBACK']) {
        expect(_a(sql).writes, isFalse, reason: sql);
      }
    });
  });

  group('REINDEX transaction blocks', () {
    for (final sql in [
      'REINDEX SCHEMA s',
      'REINDEX SCHEMA CONCURRENTLY s',
      'REINDEX (VERBOSE) SCHEMA s',
      'REINDEX SYSTEM',
      'REINDEX (VERBOSE) DATABASE d',
      'REINDEX (CONCURRENTLY) TABLE t',
      'REINDEX (CONCURRENTLY true) INDEX i',
      "REINDEX (CONCURRENTLY 'on') TABLE t",
      'REINDEX (VERBOSE, CONCURRENTLY) TABLE t',
      'REINDEX (CONCURRENTLY maybe) TABLE t',
      'REINDEX (VERBOSE) TABLE CONCURRENTLY t',
      'REINDEX (CONCURRENTLY false) DATABASE d',
    ]) {
      test(sql, () => expect(_a(sql).cannotRunInTransactionBlock, isTrue));
    }

    for (final sql in [
      'REINDEX TABLE t',
      'REINDEX INDEX i',
      'REINDEX (VERBOSE) TABLE t',
      'REINDEX (CONCURRENTLY false) TABLE t',
      'REINDEX (CONCURRENTLY off) INDEX i',
      'REINDEX (TABLESPACE ts) TABLE t',
      'REINDEX TABLE "schema"',
    ]) {
      test(
        'not: $sql',
        () => expect(_a(sql).cannotRunInTransactionBlock, isFalse),
      );
    }
  });
}
