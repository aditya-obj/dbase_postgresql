// File: sql_statement_analyzer.dart
// Purpose: Public entry point that classifies SQL statements and reports
// safety findings (missing WHERE, DROP, TRUNCATE, ...).

import 'package:dbase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_analysis.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_rules.dart';
import 'package:dbase_postgresql/src/sql/analysis/token_scan.dart';
import 'package:dbase_postgresql/src/sql/sql_statement.dart';
import 'package:dbase_postgresql/src/sql/sql_statement_splitter.dart';

/// Classifies SQL statements and flags risky ones before they run.
///
/// The analysis is lexical (token based), not a full parser. It is designed
/// to **fail closed**: whatever it cannot confidently understand is
/// reported as [StatementKind.unknown], counted as writing, and carries a
/// [SafetySeverity.danger] finding so the UI asks for confirmation.
///
/// ```dart
/// const analyzer = SqlStatementAnalyzer();
/// final result = analyzer.analyze('DELETE FROM orders');
/// result.kind;                 // StatementKind.delete
/// result.requiresConfirmation; // true (deleteWithoutWhere)
/// ```
final class SqlStatementAnalyzer {
  /// Creates an analyzer that uses [splitter] (and its lexer) for input.
  const SqlStatementAnalyzer({this.splitter = const SqlStatementSplitter()});

  /// Splitter used by [analyze] to find statements.
  final SqlStatementSplitter splitter;

  /// Analyses [sql], which is expected to hold a single statement (a
  /// trailing `;` is fine).
  ///
  /// Input with only whitespace and comments is [StatementKind.empty].
  /// Input with several statements is [StatementKind.unknown] with a
  /// [SafetyFindingCode.multipleStatements] finding plus the findings,
  /// targets and `cascades` of each statement; split scripts with
  /// [SqlStatementSplitter] and call [analyzeStatement] for each one
  /// instead. Finding offsets are relative to [sql].
  StatementAnalysis analyze(String sql) {
    for (final token in splitter.lexer.tokenize(sql)) {
      // Catches unterminated comments that the splitter would otherwise
      // drop as trivia.
      if (token.isUnterminated) {
        return unknownAnalysis(
          SafetyFindingCode.unterminated,
          'The SQL has an unterminated string, quoted identifier, or '
          'comment, so it could not be analyzed. Confirm before running.',
          token.start,
        );
      }
    }
    final statements = splitter.split(sql);
    if (statements.isEmpty) {
      return StatementAnalysis(kind: StatementKind.empty, writes: false);
    }
    if (statements.length == 1) return analyzeStatement(statements.single);

    final analyses = statements.map(analyzeStatement).toList();
    return unknownAnalysis(
      SafetyFindingCode.multipleStatements,
      'The SQL contains ${statements.length} statements; review each one '
      'before running.',
      statements[1].start,
      extraFindings: [for (final a in analyses) ...a.findings],
      targets: [for (final a in analyses) ...a.targets],
      cascades: analyses.any((a) => a.cascades),
    );
  }

  /// Analyses one statement produced by [SqlStatementSplitter.split].
  /// Finding offsets are relative to the script it was split from.
  StatementAnalysis analyzeStatement(SqlStatement statement) =>
      analyzeTokens(TokenScan(statement.tokens));
}
