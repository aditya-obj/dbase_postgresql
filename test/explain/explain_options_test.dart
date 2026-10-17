// File: explain_options_test.dart
// Purpose: Unit tests for ExplainOptions.toSql: version gating and the
// ANALYZE-only / not-with-ANALYZE option rules.

import 'package:dbase_postgresql/explain.dart';
import 'package:test/test.dart';

const _all = ExplainOptions(
  verbose: true,
  wal: true,
  serialize: true,
  memory: true,
  genericPlan: true,
  timing: false,
);

void main() {
  test('defaults: plan only with BUFFERS and SETTINGS', () {
    expect(
      const ExplainOptions().toSql(170000),
      '(FORMAT JSON, BUFFERS, SETTINGS)',
    );
  });

  test('ANALYZE defaults', () {
    expect(
      const ExplainOptions(analyze: true).toSql(130000),
      '(FORMAT JSON, ANALYZE, BUFFERS, SETTINGS)',
    );
    expect(
      const ExplainOptions(analyze: true).toSql(180000),
      '(FORMAT JSON, ANALYZE, BUFFERS, SETTINGS)',
    );
  });

  group('everything on, by version', () {
    final analyze = _all.copyWith(analyze: true);
    final cases = <int, (String, String)>{
      130000: (
        '(FORMAT JSON, BUFFERS, VERBOSE, SETTINGS)',
        '(FORMAT JSON, ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL, TIMING OFF)',
      ),
      150004: (
        '(FORMAT JSON, BUFFERS, VERBOSE, SETTINGS)',
        '(FORMAT JSON, ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL, TIMING OFF)',
      ),
      160000: (
        '(FORMAT JSON, BUFFERS, VERBOSE, SETTINGS, GENERIC_PLAN)',
        '(FORMAT JSON, ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL, TIMING OFF)',
      ),
      170002: (
        '(FORMAT JSON, BUFFERS, VERBOSE, SETTINGS, MEMORY, GENERIC_PLAN)',
        '(FORMAT JSON, ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL, SERIALIZE, '
            'MEMORY, TIMING OFF)',
      ),
      180000: (
        '(FORMAT JSON, BUFFERS, VERBOSE, SETTINGS, MEMORY, GENERIC_PLAN)',
        '(FORMAT JSON, ANALYZE, BUFFERS, VERBOSE, SETTINGS, WAL, SERIALIZE, '
            'MEMORY, TIMING OFF)',
      ),
    };
    for (final MapEntry(key: version, value: (plain, analyzed))
        in cases.entries) {
      test('$version', () {
        expect(_all.toSql(version), plain);
        expect(analyze.toSql(version), analyzed);
      });
    }
  });

  test('BUFFERS OFF is sent to 18+ with ANALYZE only', () {
    const off = ExplainOptions(analyze: true, buffers: false);
    expect(off.toSql(170000), '(FORMAT JSON, ANALYZE, SETTINGS)');
    expect(off.toSql(180001), '(FORMAT JSON, ANALYZE, BUFFERS OFF, SETTINGS)');
    expect(
      const ExplainOptions(buffers: false).toSql(180000),
      '(FORMAT JSON, SETTINGS)',
    );
  });

  test('before 13: no BUFFERS without ANALYZE, no WAL; SETTINGS from 12', () {
    expect(
      const ExplainOptions(wal: true).toSql(120000),
      '(FORMAT JSON, SETTINGS)',
    );
    expect(
      const ExplainOptions(analyze: true, wal: true).toSql(120000),
      '(FORMAT JSON, ANALYZE, BUFFERS, SETTINGS)',
    );
    expect(const ExplainOptions().toSql(110000), '(FORMAT JSON)');
  });

  test('GENERIC_PLAN is dropped with ANALYZE', () {
    expect(
      const ExplainOptions(analyze: true, genericPlan: true).toSql(170000),
      isNot(contains('GENERIC_PLAN')),
    );
    expect(
      const ExplainOptions(genericPlan: true).toSql(159999),
      isNot(contains('GENERIC_PLAN')),
    );
  });

  test('TIMING ON is never sent', () {
    expect(
      const ExplainOptions(analyze: true).toSql(170000),
      isNot(contains('TIMING')),
    );
    expect(
      const ExplainOptions(timing: false).toSql(170000),
      isNot(contains('TIMING')),
    );
  });

  test('copyWith, == and hashCode', () {
    const a = ExplainOptions(analyze: true);
    expect(const ExplainOptions().copyWith(analyze: true), a);
    expect(a.hashCode, const ExplainOptions(analyze: true).hashCode);
    expect(a, isNot(const ExplainOptions()));
    expect(a.copyWith(), a);
  });
}
