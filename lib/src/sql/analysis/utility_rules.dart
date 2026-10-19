// File: utility_rules.dart
// Purpose: Analysis rules for utility statements: EXPLAIN (incl. ANALYZE),
// COPY, opaque code execution (DO/CALL/EXECUTE/LOAD), LOCK, and
// SET/RESET/DISCARD changes to read-only mode (internal).

import 'package:dabase_postgresql/src/sql/analysis/function_rules.dart';
import 'package:dabase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dabase_postgresql/src/sql/analysis/statement_analysis.dart';
import 'package:dabase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dabase_postgresql/src/sql/analysis/statement_rules.dart';
import 'package:dabase_postgresql/src/sql/analysis/table_lock_mode.dart';
import 'package:dabase_postgresql/src/sql/analysis/token_scan.dart';
import 'package:dabase_postgresql/src/sql/sql_token.dart';

const _opaqueWords = {'do', 'call', 'execute', 'load'};
const _analyzeWords = {'analyze', 'analyse'};

/// Rule for utility statements; [first] is the lower-cased leading word.
StatementAnalysis utilityRule(TokenScan scan, int start, String first) {
  if (first == 'explain') return _explainRule(scan, start);
  if (first == 'copy') return _copyRule(scan, start);
  if (first == 'lock') return _lockRule(scan, start);
  if (_opaqueWords.contains(first)) {
    return StatementAnalysis(
      kind: StatementKind.utility,
      writes: true,
      findings: [
        _opaqueFinding(scan.offsetAt(start), first.toUpperCase()),
        // CALL and EXECUTE evaluate their argument expressions.
        if (first == 'call' || first == 'execute')
          ...functionCallFindings(scan),
      ],
    );
  }
  // DISCARD ALL: PreventInTransactionBlock in src/backend/commands/
  // discard.c. DISCARD PLANS / SEQUENCES / TEMP are allowed.
  final discardAll = first == 'discard' && scan.isWord(start + 1, 'all');
  final escape = switch (first) {
    'set' => _setEscape(scan, start),
    'reset' => _resetEscape(scan, start),
    _ => discardAll ? _defaultEscapeMessage : null,
  };
  return StatementAnalysis(
    kind: StatementKind.utility,
    writes: false,
    cannotRunInTransactionBlock: discardAll,
    findings: [
      if (escape != null)
        SafetyFinding(
          SafetyFindingCode.readOnlyEscape,
          escape,
          offset: scan.offsetAt(start),
        ),
    ],
  );
}

const _defaultEscapeMessage =
    'This can turn off default_transaction_read_only for the session, so '
    'later transactions can write even on a read-only connection.';
const _transactionEscapeMessage =
    'This can make the current transaction read-write, even on a '
    'read-only connection.';

/// Whether [scan] has the adjacent top-level words `READ WRITE` from
/// [from] on.
bool hasReadWrite(TokenScan scan, int from) => scan
    .topLevelIndexes(from: from)
    .any((i) => scan.isWord(i, 'read') && scan.isWord(i + 1, 'write'));

/// The [SafetyFindingCode.readOnlyEscape] message for a `SET` statement,
/// or `null` when it doesn't turn read-only off.
String? _setEscape(TokenScan scan, int start) {
  var i = start + 1;
  final scope = scan.word(i);
  if (scope == 'session' && scan.isWord(i + 1, 'characteristics')) {
    return hasReadWrite(scan, i) ? _defaultEscapeMessage : null;
  }
  if (scope == 'session' || scope == 'local') i++;
  if (scan.isWord(i, 'transaction')) {
    return hasReadWrite(scan, i) ? _transactionEscapeMessage : null;
  }
  if (!scan.isName(i)) return null;
  final name = scan.tokens[i].normalized;
  if (!readOnlySettings.contains(name)) return null;
  final message = name == 'transaction_read_only'
      ? _transactionEscapeMessage
      : _defaultEscapeMessage;
  // Only `name {TO | =} <one truthy literal>` keeps read-only on;
  // anything else (DEFAULT, a list, an unknown form) fails closed.
  final assigns = scan.isWord(i + 1, 'to') || scan.isOperator(i + 1, '=');
  final valueIndex = i + 2;
  final keepsOn =
      assigns &&
      valueIndex == scan.length - 1 &&
      _isSimpleValue(scan, valueIndex) &&
      truthyValues.contains(scan.literalValue(valueIndex));
  return keepsOn ? null : message;
}

/// An unquoted word, a number, or a plain `'...'` string.
bool _isSimpleValue(TokenScan scan, int index) =>
    scan.tokens[index].isWord ||
    scan.tokens[index].kind == SqlTokenKind.number ||
    isPlainString(scan, index);

/// `RESET ALL` and `RESET` of a read-only setting go back to the setting's
/// reset value (postgresql.conf, role, database or startup), usually off.
String? _resetEscape(TokenScan scan, int start) {
  final i = start + 1;
  if (scan.isWord(i, 'all')) return _defaultEscapeMessage;
  if (!scan.isName(i)) return null;
  return switch (scan.tokens[i].normalized) {
    'default_transaction_read_only' => _defaultEscapeMessage,
    'transaction_read_only' => _transactionEscapeMessage,
    _ => null,
  };
}

final Map<String, TableLockMode> _lockModes = {
  for (final mode in TableLockMode.values) mode.sql.toLowerCase(): mode,
};

/// `LOCK [TABLE] [ONLY] name [*] [, ...] [IN mode MODE] [NOWAIT]`.
StatementAnalysis _lockRule(TokenScan scan, int start) {
  var i = start + 1;
  if (scan.isWord(i, 'table')) i++;
  final list = scan.nameList(i);
  var mode = TableLockMode.accessExclusive;
  if (scan.isWord(list.next, 'in')) {
    final words = <String>[];
    var k = list.next + 1;
    while (k < scan.length && !scan.isWord(k, 'mode')) {
      words.add(scan.word(k) ?? '?');
      k++;
    }
    // An unrecognised mode keeps ACCESS EXCLUSIVE (fail closed).
    mode = _lockModes[words.join(' ')] ?? TableLockMode.accessExclusive;
  }
  final blocksReads = mode == TableLockMode.accessExclusive;
  return StatementAnalysis(
    kind: StatementKind.utility,
    writes: false,
    targets: list.names,
    lockMode: mode,
    findings: [
      SafetyFinding(
        SafetyFindingCode.explicitLock,
        'LOCK takes a ${mode.sql} lock on the listed tables until the '
        'transaction ends${blocksReads ? ', blocking even reads' : ''}.',
        offset: scan.offsetAt(start),
      ),
    ],
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
    analyze = scan.slice(i + 1, close).optionListEnables(_analyzeWords);
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
    targets: inner.targets,
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
    targets: inner?.targets ?? const [],
    findings: [
      if (isProgram) _opaqueFinding(scan.offsetAt(direction), 'COPY PROGRAM'),
      ...?inner?.findings,
    ],
  );
}
