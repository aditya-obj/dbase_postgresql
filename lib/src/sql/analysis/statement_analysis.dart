// File: statement_analysis.dart
// Purpose: Result of analysing one SQL statement: kind, write/transaction
// flags, and safety findings.

import 'package:dbase_postgresql/src/sql/analysis/safety_finding.dart';
import 'package:dbase_postgresql/src/sql/analysis/statement_kind.dart';
import 'package:dbase_postgresql/src/sql/analysis/table_lock_mode.dart';

/// What `SqlStatementAnalyzer` concluded about a statement.
///
/// The analysis is lexical and best effort. It fails closed: anything it
/// cannot understand is [StatementKind.unknown], counted as writing, and
/// carries a [SafetySeverity.danger] finding.
///
/// Known limitation: [isReadOnly] does not look inside function calls. A
/// `SELECT` can still change data through volatile functions (`nextval`,
/// `setval`, `pg_terminate_backend`, user functions...). Well-known
/// built-ins are reported as [SafetyFindingCode.sideEffectFunction] but do
/// not change [writes]. Run statements in a `READ ONLY` transaction when
/// read-only must be guaranteed.
final class StatementAnalysis {
  /// Creates an analysis result.
  StatementAnalysis({
    required this.kind,
    required this.writes,
    this.cannotRunInTransactionBlock = false,
    List<SafetyFinding> findings = const [],
    List<String> targets = const [],
    this.cascades = false,
    this.lockMode,
    this.dropObjectType,
  }) : findings = List.unmodifiable(findings),
       targets = List.unmodifiable(targets);

  /// The broad category of the statement. For `WITH ... <main>` this is the
  /// category of the main statement.
  final StatementKind kind;

  /// Whether the statement may modify data, schema, or other persistent
  /// server state (including through data-modifying CTEs,
  /// `EXPLAIN ANALYZE`, `SELECT INTO`, and opaque code such as `DO`).
  final bool writes;

  /// Whether PostgreSQL refuses to run the statement inside a transaction
  /// block (e.g. `VACUUM`, `CREATE DATABASE`, `CREATE INDEX CONCURRENTLY`,
  /// `ALTER SYSTEM`, `DISCARD ALL`). Callers that wrap statements in
  /// `BEGIN`/`COMMIT` must run these outside a transaction.
  ///
  /// The check is lexical. Rules that depend on server state are not
  /// detected: subscription commands that create, drop or refresh a
  /// replication slot, and `REINDEX` or `CLUSTER` of a partitioned table.
  final bool cannotRunInTransactionBlock;

  /// Safety findings, in source order where possible. Unmodifiable.
  final List<SafetyFinding> findings;

  /// The relations or objects the statement changes, so a UI can name them
  /// (or ask the user to type them). Unmodifiable.
  ///
  /// Filled for the target of `UPDATE`, `DELETE` and `MERGE`, every table
  /// listed by `TRUNCATE` and `LOCK`, the object list of `DROP`, and the
  /// table of `ALTER [FOREIGN] TABLE`. Targets of data-modifying CTE
  /// bodies and of the statement run by `EXPLAIN ANALYZE` are included.
  /// In source order; a name can appear more than once.
  ///
  /// Each name is in the form the server resolves: unquoted parts are
  /// lower-cased and double-quoted parts lose their quotes, joined with
  /// `.` (`Public.Orders` gives `public.orders`, `"My Table"` gives
  /// `My Table`). Aliases, `ONLY`, `*`, `IF EXISTS` and argument lists are
  /// dropped. Empty when the names could not be read, e.g. `DROP CAST`,
  /// `DROP OPERATOR` or `ALTER TABLE ALL IN TABLESPACE`.
  final List<String> targets;

  /// Whether `TRUNCATE` or `DROP` has a top-level `CASCADE`, so other
  /// tables or objects that depend on [targets] are affected too.
  final bool cascades;

  /// The lock mode of a `LOCK` statement, `null` for other statements. A
  /// `LOCK` without `IN ... MODE` is [TableLockMode.accessExclusive], and
  /// so is a mode the analyzer doesn't recognise (fail closed).
  final TableLockMode? lockMode;

  /// For `DROP`, the object type as written, upper case and single-spaced
  /// (`TABLE`, `MATERIALIZED VIEW`, `FUNCTION`); `null` for other
  /// statements and for a `DROP` whose type isn't recognised.
  final String? dropObjectType;

  /// Whether the statement can turn a read-only session or transaction
  /// read-write: true exactly when a [SafetyFindingCode.readOnlyEscape]
  /// finding is present. Callers that enforce read-only sessions should
  /// refuse or re-assert `default_transaction_read_only` after it.
  bool get changesTransactionMode =>
      hasFinding(SafetyFindingCode.readOnlyEscape);

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
      'findings: $findings, targets: ${targets.length}, '
      'cascades: $cascades, lockMode: ${lockMode?.name})';
}
