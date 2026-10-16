// File: with_clause_rule.dart
// Purpose: Analyses `WITH ... <main statement>`: classifies by the main
// statement and detects data-modifying CTEs (internal).

import 'package:dbase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_analysis.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_rules.dart';
import 'package:dbase_postgresql/src/sql/analysis/token_scan.dart';
import 'package:dbase_postgresql/src/sql/sql_token.dart';

const Set<StatementKind> _writingKinds = {
  StatementKind.insert,
  StatementKind.update,
  StatementKind.delete,
  StatementKind.merge,
};
const _mainStatementWords = {
  'select',
  'values',
  'table',
  'insert',
  'update',
  'delete',
  'merge',
};

/// Rule for a statement starting with `WITH` at [start].
///
/// Grammar handled:
/// `WITH [RECURSIVE] name [(cols)] AS [[NOT] MATERIALIZED] (body)`
/// `[SEARCH ...] [CYCLE ...] [, ...] main`. Anything else fails closed.
StatementAnalysis withClauseRule(TokenScan scan, int start) {
  final findings = <SafetyFinding>[];
  var cteWrites = false;
  var i = start + 1;
  if (scan.isWord(i, 'recursive')) i++;

  while (true) {
    if (!_isName(scan, i)) return _unparseableWith(scan, start, findings);
    i++;
    if (scan.isPunctuation(i, '(')) i = scan.matchingClose(i) + 1;
    if (!scan.isWord(i, 'as')) return _unparseableWith(scan, start, findings);
    i++;
    if (scan.isWord(i, 'not')) i++;
    if (scan.isWord(i, 'materialized')) i++;
    if (!scan.isPunctuation(i, '(')) {
      return _unparseableWith(scan, start, findings);
    }
    final close = scan.matchingClose(i);
    final body = analyzeTokens(scan.slice(i + 1, close));
    if (body.kind == StatementKind.unknown) {
      return _unparseableWith(scan, start, [...findings, ...body.findings]);
    }
    if (_writingKinds.contains(body.kind)) {
      findings.add(
        SafetyFinding(
          SafetyFindingCode.dataModifyingCte,
          'This WITH clause contains a data-modifying statement '
          '(${body.kind.name.toUpperCase()}); it runs even if the main '
          'statement only reads.',
          offset: scan.offsetAt(i + 1),
        ),
      );
    }
    cteWrites = cteWrites || body.writes;
    findings.addAll(body.findings);
    i = close + 1;

    if (scan.isWord(i, 'search') || scan.isWord(i, 'cycle')) {
      i = _skipSearchAndCycle(scan, i);
    }
    if (!scan.isPunctuation(i, ',')) break;
    i++;
  }

  if (!_mainStatementWords.contains(scan.word(i)) &&
      !scan.isPunctuation(i, '(')) {
    return _unparseableWith(scan, start, findings);
  }
  final main = analyzeTokens(scan.slice(i));
  if (main.kind == StatementKind.unknown) {
    return _unparseableWith(scan, start, [...findings, ...main.findings]);
  }
  return StatementAnalysis(
    kind: main.kind,
    writes: main.writes || cteWrites,
    cannotRunInTransactionBlock: main.cannotRunInTransactionBlock,
    findings: [...findings, ...main.findings],
  );
}

bool _isName(TokenScan scan, int i) =>
    i < scan.length &&
    (scan.tokens[i].isWord ||
        scan.tokens[i].kind == SqlTokenKind.quotedIdentifier);

/// Skips `SEARCH ... SET col` / `CYCLE ... USING col` clauses, which may
/// contain commas, up to the next CTE (`, name AS`/`, name (`) or the main
/// statement.
int _skipSearchAndCycle(TokenScan scan, int from) {
  for (final i in scan.topLevelIndexes(from: from)) {
    if (_mainStatementWords.contains(scan.word(i))) return i;
    if (scan.isPunctuation(i, ',') &&
        _isName(scan, i + 1) &&
        (scan.isWord(i + 2, 'as') || scan.isPunctuation(i + 2, '('))) {
      return i;
    }
  }
  return scan.length;
}

StatementAnalysis _unparseableWith(
  TokenScan scan,
  int start,
  List<SafetyFinding> findings,
) => unknownAnalysis(
  SafetyFindingCode.unparseable,
  'This WITH query could not be analyzed, so its effects are unknown. '
  'Confirm before running.',
  scan.offsetAt(start),
  extraFindings: findings,
);
