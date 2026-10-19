// File: cron_writes_test.dart
// Purpose: pg_cron job changes (cron.schedule, schedule_in_database,
// unschedule, alter_job) are writes with a sideEffectFunction finding.

import 'package:dabase_postgresql/sql.dart';
import 'package:test/test.dart';

const _analyzer = SqlStatementAnalyzer();

void main() {
  group('cron job changes are writes', () {
    for (final sql in [
      r"SELECT cron.schedule('nightly', '0 3 * * *', $$VACUUM t$$)",
      "SELECT cron.schedule_in_database('j', '* * * * *', 'SELECT 1', 'db')",
      "SELECT cron.unschedule('nightly')",
      'SELECT cron.unschedule(42::bigint)',
      'SELECT cron.alter_job(job_id := 42, active := false)',
      'SELECT "cron"."schedule"(\'j\', \'@daily\', \'SELECT 1\')',
      'SELECT * FROM CRON.UNSCHEDULE(1)',
      "WITH j AS (SELECT cron.unschedule('x')) SELECT * FROM j",
      "VALUES (cron.schedule('j', '@daily', 'SELECT 1'))",
    ]) {
      test(sql, () {
        final a = _analyzer.analyze(sql);
        expect(a.writes, isTrue);
        expect(a.kind, StatementKind.select);
        expect(
          a.findings.map((f) => f.code),
          contains(SafetyFindingCode.sideEffectFunction),
        );
      });
    }
  });

  test('the finding names the function and points at cron', () {
    const sql = "SELECT cron.unschedule('x')";
    final f = _analyzer
        .analyze(sql)
        .findings
        .singleWhere((f) => f.code == SafetyFindingCode.sideEffectFunction);
    expect(f.message, startsWith('cron.unschedule()'));
    expect(f.offset, sql.indexOf('cron'));
  });

  group('not cron writes', () {
    for (final sql in [
      'SELECT * FROM cron.job',
      'SELECT * FROM cron.job_run_details WHERE jobid = 1',
      "SELECT schedule('x')",
      "SELECT app.schedule('x')",
      "SELECT 'cron.schedule(1)'",
      'SELECT cron.schedule_count FROM t',
    ]) {
      test(sql, () {
        final a = _analyzer.analyze(sql);
        expect(a.writes, isFalse);
        expect(
          a.findings.map((f) => f.code),
          isNot(contains(SafetyFindingCode.sideEffectFunction)),
        );
      });
    }
  });

  test('CALL with a cron call stays an opaque write', () {
    final a = _analyzer.analyze("CALL p(cron.unschedule('x'))");
    expect(a.writes, isTrue);
    expect(
      a.findings.map((f) => f.code),
      containsAll([
        SafetyFindingCode.opaqueExecution,
        SafetyFindingCode.sideEffectFunction,
      ]),
    );
  });
}
