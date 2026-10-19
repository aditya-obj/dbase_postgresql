// File: ddl_rules.dart
// Purpose: Analysis rules for DDL (CREATE/ALTER/DROP/GRANT...) and
// maintenance statements (VACUUM/REINDEX/CLUSTER...) (internal).

import 'package:dabase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dabase_postgresql/src/sql/analysis/statement_analysis.dart';
import 'package:dabase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dabase_postgresql/src/sql/analysis/token_scan.dart';

/// Words after `ALTER TABLE ... DROP` that do not drop a column.
const _nonColumnDrops = {
  'constraint',
  'default',
  'not',
  'expression',
  'identity',
};

/// `DROP` object types, longest phrase first where one is a prefix of
/// another.
final List<List<String>> _dropTypes = [
  for (final phrase in const [
    'access method',
    'aggregate',
    'cast',
    'collation',
    'conversion',
    'database',
    'domain',
    'event trigger',
    'extension',
    'foreign data wrapper',
    'foreign table',
    'function',
    'group',
    'index',
    'procedural language',
    'language',
    'materialized view',
    'operator class',
    'operator family',
    'operator',
    'owned',
    'policy',
    'procedure',
    'publication',
    'role',
    'routine',
    'rule',
    'schema',
    'sequence',
    'server',
    'statistics',
    'subscription',
    'tablespace',
    'table',
    'text search configuration',
    'text search dictionary',
    'text search parser',
    'text search template',
    'transform',
    'trigger',
    'type',
    'user mapping',
    'user',
    'view',
  ])
    phrase.split(' '),
];

/// `DROP` types whose names the analyzer does not read: their syntax is
/// not a plain name list (`DROP CAST (a AS b)`, `DROP OPERATOR + (a, b)`).
const _unreadDropTypes = {'cast', 'operator', 'transform', 'user mapping'};

/// Rule for DDL statements; [first] is the lower-cased leading keyword.
StatementAnalysis ddlRule(TokenScan scan, int start, String first) {
  final findings = <SafetyFinding>[];
  var noTransaction = false;
  var targets = const <String>[];
  var cascades = false;
  String? dropType;
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
        cascades = scan.hasTopLevelWord(const {'cascade'}, from: start);
        findings.add(
          SafetyFinding(
            SafetyFindingCode.dropObject,
            cascades
                ? 'DROP ... CASCADE permanently removes the objects, any '
                      'data in them, and every object that depends on them, '
                      'which can include views, constraints and columns of '
                      'other tables.'
                : 'DROP permanently removes database objects and any data '
                      'in them.',
            offset: scan.offsetAt(start),
          ),
        );
      }
      final drop = _dropTargets(scan, start);
      dropType = drop?.type;
      targets = drop?.names ?? const [];
    case 'create':
      noTransaction = second == 'database' || second == 'tablespace';
    case 'alter':
      noTransaction = _alterNeedsNoTransaction(scan, start, second);
      final third = scan.word(start + 2);
      if (second == 'table' || (second == 'foreign' && third == 'table')) {
        findings.addAll(_columnDrops(scan, start));
        targets = _alterTableTarget(scan, second == 'table' ? 2 : 3, start);
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
    targets: targets,
    cascades: cascades,
    dropObjectType: dropType,
  );
}

/// The object type (upper case) and names of a `DROP`, or `null` for an
/// unknown type. Grammar:
/// `DROP type [CONCURRENTLY] [IF EXISTS] name [, ...]`.
({String type, List<String> names})? _dropTargets(TokenScan scan, int start) {
  final typeWords = _dropTypes
      .where(
        (words) => words.indexed.every(
          (entry) => scan.isWord(start + 1 + entry.$1, entry.$2),
        ),
      )
      .firstOrNull;
  if (typeWords == null) return null;
  final type = typeWords.join(' ');
  if (_unreadDropTypes.contains(type)) {
    return (type: type.toUpperCase(), names: const []);
  }
  var i = start + 1 + typeWords.length;
  if (type == 'index' && scan.isWord(i, 'concurrently')) i++;
  if (type == 'owned' && scan.isWord(i, 'by')) i++;
  if (scan.isWord(i, 'if') && scan.isWord(i + 1, 'exists')) i += 2;
  return (type: type.toUpperCase(), names: scan.nameList(i).names);
}

/// The table of `ALTER [FOREIGN] TABLE [IF EXISTS] [ONLY] name`, where the
/// name starts [offset] tokens after [start]. Empty for `ALTER TABLE ALL
/// IN TABLESPACE`.
List<String> _alterTableTarget(TokenScan scan, int offset, int start) {
  var i = start + offset;
  if (scan.isWord(i, 'all') && scan.isWord(i + 1, 'in')) return const [];
  if (scan.isWord(i, 'if') && scan.isWord(i + 1, 'exists')) i += 2;
  if (scan.isWord(i, 'only') && scan.isName(i + 1)) i++;
  final name = scan.qualifiedName(i)?.name;
  return [?name];
}

/// Rule for maintenance statements; [first] is the leading keyword.
StatementAnalysis maintenanceRule(TokenScan scan, int start, String first) {
  final noTransaction = switch (first) {
    'vacuum' => true,
    'reindex' => _reindexNeedsNoTransaction(scan, start),
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

/// Whether `REINDEX` must run outside a transaction block. Grammar:
/// `REINDEX [(options)] {INDEX | TABLE | SCHEMA | DATABASE | SYSTEM}`
/// `[CONCURRENTLY] name`. SCHEMA, DATABASE and SYSTEM always refuse a
/// transaction block (ReindexMultipleTables in
/// src/backend/commands/indexcmds.c), and so does CONCURRENTLY, either as
/// a word or as an enabled option (PostgreSQL 14+ option list).
bool _reindexNeedsNoTransaction(TokenScan scan, int start) {
  var i = start + 1;
  var concurrently = false;
  if (scan.isPunctuation(i, '(')) {
    final close = scan.matchingClose(i);
    concurrently = scan.slice(i + 1, close).optionListEnables(const {
      'concurrently',
    });
    i = close + 1;
  }
  return concurrently ||
      const {'schema', 'database', 'system'}.contains(scan.word(i)) ||
      scan.hasTopLevelWord(const {'concurrently'}, from: start);
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
