// File: statement_analysis.dart
// Purpose: Result of analysing one SQL statement: kind, write/transaction
// flags, and safety findings.

import 'package:dbase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_kind.dart';

/// What `SqlStatementAnalyzer` concluded about a statement.
///
/// The analysis is lexical and best effort. It fails closed: anything it
/// cannot understand is [StatementKind.unknown], counted as writing, and
/// carries a [SafetySeverity.danger] finding.
///
/// Known limitation: [isReadOnly] does not look inside function calls. A
/// `SELECT` can still change data through volatile functions (`nextval`,
/// `setval`, `pg_terminate_backend`, user functions...). Run statements in
/// a `READ ONLY` transaction when read-only must be guaranteed.
final class StatementAnalysis {
  /// Creates an analysis result.
  StatementAnalysis({
    required this.kind,
    required this.writes,
    this.cannotRunInTransactionBlock = false,
    List<SafetyFinding> findings = const [],
  }) : findings = List.unmodifiable(findings);

  /// The broad category of the statement. For `WITH ... <main>` this is the
  /// category of the main statement.
  final StatementKind kind;

  /// Whether the statement may modify data, schema, or other persistent
  /// server state (including through data-modifying CTEs,
  /// `EXPLAIN ANALYZE`, `SELECT INTO`, and opaque code such as `DO`).
  final bool writes;

  /// Whether PostgreSQL refuses to run the statement inside a transaction
  /// block (e.g. `VACUUM`, `CREATE DATABASE`, `CREATE INDEX CONCURRENTLY`,
  /// `ALTER SYSTEM`). Callers that wrap statements in `BEGIN`/`COMMIT`
  /// must run these outside a transaction.
  final bool cannotRunInTransactionBlock;

  /// Safety findings, in source order where possible. Unmodifiable.
  final List<SafetyFinding> findings;

  /// Whether the analyzer believes the statement does not write; the
  /// inverse of [writes]. See the class docs for limitations.
  bool get isReadOnly => !writes;

  /// Whether any finding is [SafetySeverity.danger], meaning the user
  /// should explicitly confirm before the statement runs.
  bool get requiresConfirmation =>
      findings.any((f) => f.severity == SafetySeverity.danger);

  /// The most severe finding's severity, or `null` with no findings.
  SafetySeverity? get highestSeverity {
    SafetySeverity? highest;
    for (final finding in findings) {
      if (highest == null || finding.severity.index > highest.index) {
        highest = finding.severity;
      }
    }
    return highest;
  }

  /// Whether a finding with [code] is present.
  bool hasFinding(SafetyFindingCode code) =>
      findings.any((f) => f.code == code);

  @override
  String toString() =>
      'StatementAnalysis(${kind.name}, writes: $writes, '
      'cannotRunInTransactionBlock: $cannotRunInTransactionBlock, '
      'findings: $findings)';
}
