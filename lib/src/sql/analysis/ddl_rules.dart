// File: ddl_rules.dart
// Purpose: Analysis rules for DDL (CREATE/ALTER/DROP/GRANT...) and
// maintenance statements (VACUUM/REINDEX/CLUSTER...) (internal).

import 'package:dbase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_analysis.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dbase_postgresql/src/sql/analysis/token_scan.dart';

/// Words after `ALTER TABLE ... DROP` that do not drop a column.
const _nonColumnDrops = {
  'constraint',
  'default',
  'not',
  'expression',
  'identity',
};

/// Rule for DDL statements; [first] is the lower-cased leading keyword.
StatementAnalysis ddlRule(TokenScan scan, int start, String first) {
  final findings = <SafetyFinding>[];
  var noTransaction = false;
  final second = scan.word(start + 1);

  switch (first) {
    case 'drop':
      if (second == 'database') {
        noTransaction = true;
        findings.add(
          SafetyFinding(
            SafetyFindingCode.dropDatabase,
            'DROP DATABASE permanently deletes the entire database.',
            offset: scan.offsetAt(start),
          ),
        );
      } else {
        noTransaction = second == 'tablespace';
        findings.add(
          SafetyFinding(
            SafetyFindingCode.dropObject,
            'DROP permanently removes database objects and any data in '
            'them.',
            offset: scan.offsetAt(start),
          ),
        );
      }
    case 'create':
      noTransaction = second == 'database' || second == 'tablespace';
    case 'alter':
      noTransaction = _alterNeedsNoTransaction(scan, start, second);
      final third = scan.word(start + 2);
      if (second == 'table' || (second == 'foreign' && third == 'table')) {
        findings.addAll(_columnDrops(scan, start));
      } else if (second == 'type' && _hasAddValue(scan, start)) {
        findings.add(
          SafetyFinding(
            SafetyFindingCode.alterTypeAddValue,
            'ALTER TYPE ... ADD VALUE cannot run inside a transaction block '
            'on PostgreSQL 11 and older, and the new value cannot be used '
            'until the transaction commits.',
            offset: scan.offsetAt(start),
          ),
        );
      }
    case 'grant' || 'revoke':
      findings.add(
        SafetyFinding(
          SafetyFindingCode.grantRevoke,
          '${first.toUpperCase()} changes who can access or modify data.',
          offset: scan.offsetAt(start),
        ),
      );
  }

  // CREATE/DROP INDEX CONCURRENTLY, ALTER TABLE ... DETACH PARTITION
  // ... CONCURRENTLY.
  if ((first == 'create' || first == 'drop' || first == 'alter') &&
      scan.hasTopLevelWord(const {'concurrently'}, from: start)) {
    noTransaction = true;
  }
  return StatementAnalysis(
    kind: StatementKind.ddl,
    writes: true,
    cannotRunInTransactionBlock: noTransaction,
    findings: findings,
  );
}

/// Rule for maintenance statements; [first] is the leading keyword.
StatementAnalysis maintenanceRule(TokenScan scan, int start, String first) {
  final second = scan.word(start + 1);
  final noTransaction = switch (first) {
    'vacuum' => true,
    'reindex' =>
      second == 'database' ||
          second == 'system' ||
          scan.hasTopLevelWord(const {'concurrently'}, from: start),
    // CLUSTER with no table name processes every table and cannot run in a
    // transaction block.
    'cluster' => !_hasTableArgument(scan, start + 1),
    _ => false,
  };
  return StatementAnalysis(
    kind: StatementKind.maintenance,
    writes: true,
    cannotRunInTransactionBlock: noTransaction,
  );
}

bool _alterNeedsNoTransaction(TokenScan scan, int start, String? second) {
  if (second == 'system') return true;
  if (second != 'database') return false;
  // ALTER DATABASE ... SET TABLESPACE.
  return scan
      .topLevelIndexes(from: start)
      .any((i) => scan.isWord(i, 'set') && scan.isWord(i + 1, 'tablespace'));
}

Iterable<SafetyFinding> _columnDrops(TokenScan scan, int start) sync* {
  for (final i in scan.topLevelIndexes(from: start + 2)) {
    if (!scan.isWord(i, 'drop')) continue;
    if (_nonColumnDrops.contains(scan.word(i + 1))) continue;
    yield SafetyFinding(
      SafetyFindingCode.alterTableDropColumn,
      'ALTER TABLE ... DROP COLUMN permanently deletes the column and its '
      'data.',
      offset: scan.offsetAt(i),
    );
  }
}

bool _hasAddValue(TokenScan scan, int start) => scan
    .topLevelIndexes(from: start)
    .any((i) => scan.isWord(i, 'add') && scan.isWord(i + 1, 'value'));

/// Whether CLUSTER names a table (skipping `VERBOSE` and an option list).
bool _hasTableArgument(TokenScan scan, int from) {
  var i = from;
  if (scan.isPunctuation(i, '(')) i = scan.matchingClose(i) + 1;
  if (scan.isWord(i, 'verbose')) i++;
  return i > 0 && i < scan.length;
}
