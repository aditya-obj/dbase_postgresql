// File: statement_rules.dart
// Purpose: Dispatches a statement to the rule for its leading keyword and
// implements the query/DML rules (internal).

import 'package:dbase_postgresql/src/sql/analysis/ddl_rules.dart';
import 'package:dbase_postgresql/src/sql/analysis/dml_rules.dart';
import 'package:dbase_postgresql/src/sql/analysis/function_rules.dart';
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
    // COMMIT PREPARED / ROLLBACK PREPARED: PreventInTransactionBlock in
    // src/backend/tcop/utility.c (TRANS_STMT_COMMIT_PREPARED and
    // TRANS_STMT_ROLLBACK_PREPARED).
    final finishesPrepared =
        (first == 'commit' || first == 'rollback') &&
        scan.isWord(i + 1, 'prepared');
    final startsBlock =
        first == 'begin' ||
        (first == 'start' && scan.isWord(i + 1, 'transaction'));
    return StatementAnalysis(
      kind: StatementKind.transactionControl,
      // COMMIT PREPARED makes another transaction's writes permanent and
      // ROLLBACK PREPARED throws them away; both are allowed in a
      // read-only transaction, so count them as writing.
      writes: finishesPrepared,
      cannotRunInTransactionBlock: finishesPrepared,
      findings: [
        if (startsBlock && hasReadWrite(scan, i))
          SafetyFinding(
            SafetyFindingCode.readOnlyEscape,
            'BEGIN ... READ WRITE starts a read-write transaction, even on a '
            'read-only connection.',
            offset: scan.offsetAt(i),
          ),
      ],
    );
  }
  if (_utilityWords.contains(first)) return utilityRule(scan, i, first);
  return switch (first) {
    'with' => withClauseRule(scan, i),
    'insert' => insertRule(scan),
    'merge' => mergeRule(scan, i),
    'update' => filteredWriteRule(scan, i, StatementKind.update),
    'delete' => filteredWriteRule(scan, i, StatementKind.delete),
    'truncate' => truncateRule(scan, i),
    _ => unrecognizedStatement(scan),
  };
}

/// A fail-closed result: unknown kind, writing, with one finding.
StatementAnalysis unknownAnalysis(
  SafetyFindingCode code,
  String message,
  int offset, {
  List<SafetyFinding> extraFindings = const [],
  List<String> targets = const [],
  bool cascades = false,
}) => StatementAnalysis(
  kind: StatementKind.unknown,
  writes: true,
  targets: targets,
  cascades: cascades,
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
    // `SELECT cron.schedule(...)` changes scheduled jobs.
    writes: writes || callsWritingFunction(scan),
    findings: [...findings, ...functionCallFindings(scan)],
  );
}
