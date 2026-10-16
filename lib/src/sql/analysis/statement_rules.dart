// File: statement_rules.dart
// Purpose: Dispatches a statement to the rule for its leading keyword and
// implements the query/DML rules (internal).

import 'package:dbase_postgresql/src/sql/analysis/ddl_rules.dart';
import 'package:dbase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_analysis.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dbase_postgresql/src/sql/analysis/token_scan.dart';
import 'package:dbase_postgresql/src/sql/analysis/utility_rules.dart';
import 'package:dbase_postgresql/src/sql/analysis/with_clause_rule.dart';

Set<String> _words(String spaceSeparated) =>
    Set.unmodifiable(spaceSeparated.split(' '));

final Set<String> _ddlWords = _words(
  'create alter drop comment grant revoke security import reassign',
);
final Set<String> _transactionWords = _words(
  'begin start commit rollback savepoint release end abort',
);
final Set<String> _maintenanceWords = _words(
  'vacuum analyze analyse reindex cluster checkpoint refresh',
);
final Set<String> _utilityWords = _words(
  'set show reset explain copy listen unlisten notify do call lock prepare '
  'execute deallocate discard load fetch move close declare',
);
final Set<String> _queryWords = _words('select values table');
final Set<String> _lockStrengthWords = _words('update share no key');

/// Analyses one statement's significant tokens.
StatementAnalysis analyzeTokens(TokenScan scan) {
  if (scan.isEmpty) {
    return StatementAnalysis(kind: StatementKind.empty, writes: false);
  }
  for (final token in scan.tokens) {
    if (token.isUnterminated) {
      return unknownAnalysis(
        SafetyFindingCode.unterminated,
        'This statement has an unterminated string, quoted identifier, or '
        'comment, so it could not be analyzed. Confirm before running.',
        token.start,
      );
    }
    if (token.diagnostic != null) {
      return unknownAnalysis(
        SafetyFindingCode.unparseable,
        'This statement has a malformed number or parameter, so it could '
        'not be analyzed. Confirm before running.',
        token.start,
      );
    }
  }
  if (!scan.isBalanced) {
    return unknownAnalysis(
      SafetyFindingCode.unparseable,
      'Parentheses are unbalanced, so this statement could not be '
      'analyzed. Confirm before running.',
      scan.offsetAt(0),
    );
  }

  var i = 0;
  while (scan.isPunctuation(i, '(')) {
    i++;
  }
  final first = scan.word(i);
  if (i > 0) {
    // A parenthesised query, e.g. `(SELECT 1) UNION (SELECT 2)`.
    return _queryWords.contains(first) || first == 'with'
        ? _selectRule(scan, i)
        : unrecognizedStatement(scan);
  }
  if (first == null) return unrecognizedStatement(scan);
  if (_queryWords.contains(first)) return _selectRule(scan, i);
  if (_ddlWords.contains(first)) return ddlRule(scan, i, first);
  if (_maintenanceWords.contains(first)) return maintenanceRule(scan, i, first);
  if (first == 'prepare' && scan.isWord(i + 1, 'transaction') ||
      _transactionWords.contains(first)) {
    return StatementAnalysis(
      kind: StatementKind.transactionControl,
      writes: false,
    );
  }
  if (_utilityWords.contains(first)) return utilityRule(scan, i, first);
  return switch (first) {
    'with' => withClauseRule(scan, i),
    'insert' => StatementAnalysis(kind: StatementKind.insert, writes: true),
    'merge' => StatementAnalysis(kind: StatementKind.merge, writes: true),
    'update' => _filteredWriteRule(scan, i, StatementKind.update),
    'delete' => _filteredWriteRule(scan, i, StatementKind.delete),
    'truncate' => StatementAnalysis(
      kind: StatementKind.truncate,
      writes: true,
      findings: [
        SafetyFinding(
          SafetyFindingCode.truncate,
          'TRUNCATE removes every row from the listed tables.',
          offset: scan.offsetAt(i),
        ),
      ],
    ),
    _ => unrecognizedStatement(scan),
  };
}

/// A fail-closed result: unknown kind, writing, with one finding.
StatementAnalysis unknownAnalysis(
  SafetyFindingCode code,
  String message,
  int offset, {
  List<SafetyFinding> extraFindings = const [],
}) => StatementAnalysis(
  kind: StatementKind.unknown,
  writes: true,
  findings: [
    SafetyFinding(code, message, offset: offset),
    ...extraFindings,
  ],
);

/// Fail-closed result for a statement the analyzer does not recognise.
StatementAnalysis unrecognizedStatement(TokenScan scan) => unknownAnalysis(
  SafetyFindingCode.unparseable,
  'This statement could not be analyzed, so its effects are unknown. '
  'Confirm before running.',
  scan.offsetAt(0),
);

StatementAnalysis _selectRule(TokenScan scan, int start) {
  final findings = <SafetyFinding>[];
  var writes = false;
  for (final i in scan.topLevelIndexes(from: start)) {
    if (scan.isWord(i, 'into')) {
      writes = true;
      findings.add(
        SafetyFinding(
          SafetyFindingCode.selectInto,
          'SELECT ... INTO creates a new table from the query result.',
          offset: scan.offsetAt(i),
        ),
      );
    } else if (scan.isWord(i, 'for') &&
        _lockStrengthWords.contains(scan.word(i + 1))) {
      findings.add(
        SafetyFinding(
          SafetyFindingCode.rowLocking,
          'FOR UPDATE/SHARE locks the selected rows until the transaction '
          'ends.',
          offset: scan.offsetAt(i),
        ),
      );
    }
  }
  return StatementAnalysis(
    kind: StatementKind.select,
    writes: writes,
    findings: findings,
  );
}

/// UPDATE and DELETE: flag a missing top-level WHERE. A WHERE inside a
/// subquery does not count; `WHERE CURRENT OF cursor` does.
StatementAnalysis _filteredWriteRule(
  TokenScan scan,
  int start,
  StatementKind kind,
) {
  final hasWhere = scan.hasTopLevelWord(const {'where'}, from: start);
  final isUpdate = kind == StatementKind.update;
  return StatementAnalysis(
    kind: kind,
    writes: true,
    findings: [
      if (!hasWhere)
        SafetyFinding(
          isUpdate
              ? SafetyFindingCode.updateWithoutWhere
              : SafetyFindingCode.deleteWithoutWhere,
          isUpdate
              ? 'UPDATE without a WHERE clause changes every row in the '
                    'table.'
              : 'DELETE without a WHERE clause removes every row in the '
                    'table.',
          offset: scan.offsetAt(start),
        ),
    ],
  );
}
