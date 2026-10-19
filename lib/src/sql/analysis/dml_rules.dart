// File: dml_rules.dart
// Purpose: Analysis rules for INSERT, UPDATE, DELETE, MERGE and TRUNCATE:
// missing or always-true WHERE, unrestricted MERGE, targets (internal).

import 'package:dabase_postgresql/src/sql/analysis/function_rules.dart';
import 'package:dabase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dabase_postgresql/src/sql/analysis/statement_analysis.dart';
import 'package:dabase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dabase_postgresql/src/sql/analysis/token_scan.dart';
import 'package:dabase_postgresql/src/sql/sql_keywords.dart';
import 'package:dabase_postgresql/src/sql/sql_token.dart';

/// String literals PostgreSQL reads as boolean true in `WHERE 't'`.
const _trueStrings = {'t', 'true', 'yes', 'on'};
const _boolTypes = {'bool', 'boolean'};

/// `INSERT`: always writes; reports side-effect function calls.
StatementAnalysis insertRule(TokenScan scan) => StatementAnalysis(
  kind: StatementKind.insert,
  writes: true,
  findings: functionCallFindings(scan),
);

/// UPDATE and DELETE: flag a missing top-level WHERE, or one that is a
/// literal tautology. A WHERE inside a subquery does not count;
/// `WHERE CURRENT OF cursor` does.
StatementAnalysis filteredWriteRule(
  TokenScan scan,
  int start,
  StatementKind kind,
) {
  final isUpdate = kind == StatementKind.update;
  final where = scan
      .topLevelIndexes(from: start)
      .where((i) => scan.isWord(i, 'where'))
      .firstOrNull;
  final targetIndex = isUpdate || !scan.isWord(start + 1, 'from')
      ? start + 1
      : start + 2;
  final target = _target(scan, targetIndex);
  return StatementAnalysis(
    kind: kind,
    writes: true,
    targets: [?target],
    findings: [
      if (where == null)
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
        )
      else if (isTautology(scan, where + 1, _whereEnd(scan, where)))
        SafetyFinding(
          SafetyFindingCode.whereAlwaysTrue,
          isUpdate
              ? 'This WHERE condition is always true, so the UPDATE changes '
                    'every row in the table.'
              : 'This WHERE condition is always true, so the DELETE removes '
                    'every row in the table.',
          offset: scan.offsetAt(where),
        ),
      ...functionCallFindings(scan),
    ],
  );
}

/// End of the WHERE condition at [where]: the top-level `RETURNING`, or
/// the end of the statement.
int _whereEnd(TokenScan scan, int where) =>
    scan
        .topLevelIndexes(from: where)
        .where((i) => scan.isWord(i, 'returning'))
        .firstOrNull ??
    scan.length;

/// The table named at [index], after an optional `ONLY`.
String? _target(TokenScan scan, int index) {
  final i = scan.isWord(index, 'only') && scan.isName(index + 1)
      ? index + 1
      : index;
  return scan.qualifiedName(i)?.name;
}

/// Whether tokens `[from, to)` are exactly a literal tautology, possibly
/// in parentheses: `true`, `'t'`/`'true'`/`'yes'`/`'on'` (either with an
/// optional `::bool` cast), `NOT false`, `n = n` for the same integer
/// literal, or `x = x` for the same simple column name.
bool isTautology(TokenScan scan, int from, int to) {
  var a = from;
  var b = to;
  while (b - a >= 2 &&
      scan.isPunctuation(a, '(') &&
      scan.matchingClose(a) == b - 1) {
    a++;
    b--;
  }
  final n = b - a;
  if (n == 3 &&
      scan.isPunctuation(a + 1, '::') &&
      _boolTypes.contains(scan.word(a + 2))) {
    return _isTrueLiteral(scan, a);
  }
  if (n == 1) return _isTrueLiteral(scan, a);
  if (n == 2) return scan.isWord(a, 'not') && scan.isWord(a + 1, 'false');
  if (n == 3 && scan.isOperator(a + 1, '=')) {
    final left = scan.tokens[a];
    final right = scan.tokens[a + 2];
    if (_isInteger(left) && _isInteger(right)) return left.text == right.text;
    return _isColumnName(left) &&
        _isColumnName(right) &&
        left.normalized == right.normalized;
  }
  return false;
}

bool _isTrueLiteral(TokenScan scan, int i) =>
    scan.isWord(i, 'true') ||
    (isPlainString(scan, i) && _trueStrings.contains(scan.literalValue(i)));

bool _isInteger(SqlToken token) =>
    token.kind == SqlTokenKind.number &&
    token.diagnostic == null &&
    RegExp(r'^[0-9]+$').hasMatch(token.text);

/// An identifier, quoted identifier, or unreserved keyword used as a
/// name. Reserved words such as `NULL` (`NULL = NULL` is never true) and
/// `CURRENT_USER` are excluded.
bool _isColumnName(SqlToken token) =>
    token.kind == SqlTokenKind.identifier ||
    (token.kind == SqlTokenKind.quotedIdentifier && !token.isUnterminated) ||
    token.keywordCategory == SqlKeywordCategory.unreserved;

/// MERGE: always modifies; flags an always-true join condition with an
/// unconditional `WHEN MATCHED THEN UPDATE/DELETE`, and
/// `WHEN NOT MATCHED BY SOURCE ... THEN DELETE`. Grammar:
/// `MERGE INTO [ONLY] target [*] [[AS] alias] USING source ON cond WHEN`.
StatementAnalysis mergeRule(TokenScan scan, int start) {
  final target = scan.isWord(start + 1, 'into')
      ? _target(scan, start + 2)
      : null;
  final findings = <SafetyFinding>[];

  // Top-level WHEN/THEN of the merge clauses, skipping CASE ... END.
  final whens = <int>[];
  final thens = <int>[];
  var caseDepth = 0;
  for (final i in scan.topLevelIndexes(from: start)) {
    if (scan.isWord(i, 'case')) {
      caseDepth++;
    } else if (scan.isWord(i, 'end') && caseDepth > 0) {
      caseDepth--;
    } else if (caseDepth == 0 && scan.isWord(i, 'when')) {
      whens.add(i);
    } else if (caseDepth == 0 && scan.isWord(i, 'then')) {
      thens.add(i);
    }
  }
  final firstWhen = whens.firstOrNull ?? scan.length;
  // The join condition follows the last top-level ON before the first
  // WHEN; earlier ONs belong to joins inside the USING source.
  final on = scan
      .topLevelIndexes(from: start)
      .takeWhile((i) => i < firstWhen)
      .where((i) => scan.isWord(i, 'on'))
      .lastOrNull;
  final unrestrictedOn = on != null && isTautology(scan, on + 1, firstWhen);

  var unrestricted = false;
  for (final when in whens) {
    final then = thens.where((t) => t > when).firstOrNull;
    if (then == null) continue;
    final action = scan.word(then + 1);
    final modifies = action == 'update' || action == 'delete';
    if (scan.isWord(when + 1, 'matched')) {
      // An `AND condition` restricts the clause, so it is not flagged.
      unrestricted =
          unrestricted || (unrestrictedOn && modifies && then == when + 2);
    } else if (scan.isWord(when + 1, 'not') &&
        scan.isWord(when + 2, 'matched') &&
        scan.isWord(when + 3, 'by') &&
        scan.isWord(when + 4, 'source') &&
        action == 'delete') {
      findings.add(
        SafetyFinding(
          SafetyFindingCode.mergeDeletesUnmatched,
          'WHEN NOT MATCHED BY SOURCE ... THEN DELETE deletes every target '
          'row that has no match in the source.',
          offset: scan.offsetAt(when),
        ),
      );
    }
  }
  return StatementAnalysis(
    kind: StatementKind.merge,
    writes: true,
    targets: [?target],
    findings: [
      if (unrestricted)
        SafetyFinding(
          SafetyFindingCode.mergeUnrestricted,
          'This MERGE condition is always true, so WHEN MATCHED changes '
          'every row in the target table.',
          offset: scan.offsetAt(on!),
        ),
      ...findings,
      SafetyFinding(
        SafetyFindingCode.mergeModifies,
        'MERGE can insert, update and delete rows in one statement.',
        offset: scan.offsetAt(start),
      ),
      ...functionCallFindings(scan),
    ],
  );
}

/// TRUNCATE: always dangerous; lists the tables and notes CASCADE.
/// Grammar: `TRUNCATE [TABLE] [ONLY] name [*] [, ...] [CASCADE]`.
StatementAnalysis truncateRule(TokenScan scan, int start) {
  final i = scan.isWord(start + 1, 'table') ? start + 2 : start + 1;
  final cascades = scan.hasTopLevelWord(const {'cascade'}, from: start);
  return StatementAnalysis(
    kind: StatementKind.truncate,
    writes: true,
    targets: scan.nameList(i).names,
    cascades: cascades,
    findings: [
      SafetyFinding(
        SafetyFindingCode.truncate,
        cascades
            ? 'TRUNCATE ... CASCADE removes every row from the listed tables '
                  'and from every table with a foreign key to them.'
            : 'TRUNCATE removes every row from the listed tables.',
        offset: scan.offsetAt(start),
      ),
    ],
  );
}
