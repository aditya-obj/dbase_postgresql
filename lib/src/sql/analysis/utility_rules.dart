// File: utility_rules.dart
// Purpose: Analysis rules for utility statements: EXPLAIN (incl. ANALYZE),
// COPY, and opaque code execution (DO/CALL/EXECUTE/LOAD) (internal).

import 'package:dbase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_analysis.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_rules.dart';
import 'package:dbase_postgresql/src/sql/analysis/token_scan.dart';
import 'package:dbase_postgresql/src/sql/sql_token.dart';

const _opaqueWords = {'do', 'call', 'execute', 'load'};
const _analyzeWords = {'analyze', 'analyse'};
const _falseValues = {'false', 'off', '0', 'no'};

/// Rule for utility statements; [first] is the lower-cased leading word.
StatementAnalysis utilityRule(TokenScan scan, int start, String first) {
  if (first == 'explain') return _explainRule(scan, start);
  if (first == 'copy') return _copyRule(scan, start);
  if (_opaqueWords.contains(first)) {
    return StatementAnalysis(
      kind: StatementKind.utility,
      writes: true,
      findings: [_opaqueFinding(scan.offsetAt(start), first.toUpperCase())],
    );
  }
  return StatementAnalysis(
    kind: StatementKind.utility,
    writes: false,
    // DISCARD ALL: PreventInTransactionBlock in src/backend/commands/
    // discard.c. DISCARD PLANS / SEQUENCES / TEMP are allowed.
    cannotRunInTransactionBlock:
        first == 'discard' && scan.isWord(start + 1, 'all'),
  );
}

SafetyFinding _opaqueFinding(int offset, String what) => SafetyFinding(
  SafetyFindingCode.opaqueExecution,
  '$what runs code whose effects cannot be analyzed; it may modify data.',
  offset: offset,
);

/// `EXPLAIN` only plans the statement, unless ANALYZE is on, in which case
/// the statement really runs.
StatementAnalysis _explainRule(TokenScan scan, int start) {
  var i = start + 1;
  var analyze = false;
  if (scan.isPunctuation(i, '(')) {
    final close = scan.matchingClose(i);
    analyze = _optionListEnablesAnalyze(scan.slice(i + 1, close));
    i = close + 1;
  } else {
    while (_analyzeWords.contains(scan.word(i)) || scan.isWord(i, 'verbose')) {
      if (!scan.isWord(i, 'verbose')) analyze = true;
      i++;
    }
  }
  if (i >= scan.length) return unrecognizedStatement(scan);
  final inner = analyzeTokens(scan.slice(i));
  if (!analyze) {
    return StatementAnalysis(kind: StatementKind.utility, writes: false);
  }
  if (inner.kind == StatementKind.unknown) return inner;
  return StatementAnalysis(
    kind: StatementKind.utility,
    writes: inner.writes,
    findings: [
      if (inner.writes)
        SafetyFinding(
          SafetyFindingCode.explainAnalyzeWrites,
          'EXPLAIN ANALYZE really executes the statement, including its '
          'changes. Wrap it in BEGIN ... ROLLBACK to only measure it.',
          offset: scan.offsetAt(start),
        ),
      ...inner.findings,
    ],
  );
}

/// Parses `(ANALYZE, BUFFERS true, FORMAT JSON)`. An ANALYZE option with an
/// unrecognised value counts as enabled (fail closed).
bool _optionListEnablesAnalyze(TokenScan options) {
  var analyze = false;
  var itemStart = 0;
  for (var i = 0; i <= options.length; i++) {
    if (i < options.length && !options.isPunctuation(i, ',')) continue;
    if (_analyzeWords.contains(options.word(itemStart))) {
      analyze =
          itemStart + 1 >= i ||
          !_falseValues.contains(_optionValue(options.tokens[itemStart + 1]));
    }
    itemStart = i + 1;
  }
  return analyze;
}

String _optionValue(SqlToken token) {
  final text = token.text.toLowerCase();
  if (token.kind == SqlTokenKind.string && text.length >= 2) {
    return text.substring(1, text.length - 1);
  }
  return text;
}

/// `COPY ... FROM` writes; `COPY ... TO STDOUT` only reads (unless its
/// query writes); `COPY ... TO 'file'` writes a server file; `PROGRAM`
/// runs a shell command on the server.
StatementAnalysis _copyRule(TokenScan scan, int start) {
  var i = start + 1;
  StatementAnalysis? inner;
  if (scan.isPunctuation(i, '(')) {
    final close = scan.matchingClose(i);
    inner = analyzeTokens(scan.slice(i + 1, close));
    if (inner.kind == StatementKind.unknown) return inner;
    i = close + 1;
  }
  final direction = scan
      .topLevelIndexes(from: i)
      .where((k) => scan.isWord(k, 'from') || scan.isWord(k, 'to'))
      .firstOrNull;
  if (direction == null) return unrecognizedStatement(scan);

  final isProgram = scan.isWord(direction + 1, 'program');
  final toStdout =
      scan.isWord(direction, 'to') && scan.isWord(direction + 1, 'stdout');
  return StatementAnalysis(
    kind: StatementKind.utility,
    writes: !toStdout || (inner?.writes ?? false),
    findings: [
      if (isProgram) _opaqueFinding(scan.offsetAt(direction), 'COPY PROGRAM'),
      ...?inner?.findings,
    ],
  );
}
