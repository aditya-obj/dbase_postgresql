// File: safety_finding.dart
// Purpose: Safety findings (code, severity, message, offset) produced by
// SqlStatementAnalyzer.

/// How serious a [SafetyFinding] is. Values are ordered from least to most
/// severe, so `a.index > b.index` means `a` is more severe.
enum SafetySeverity {
  /// Worth knowing; no confirmation needed.
  info,

  /// Surprising or risky; consider telling the user.
  warning,

  /// Destructive or not analysable; ask the user to confirm.
  danger,
}

/// Stable identifiers for [SafetyFinding]s, each with its fixed severity.
enum SafetyFindingCode {
  /// `UPDATE` with no top-level `WHERE` (one inside a subquery or CTE does
  /// not count; `WHERE CURRENT OF` does).
  updateWithoutWhere(SafetySeverity.danger),

  /// `DELETE` with no top-level `WHERE`.
  deleteWithoutWhere(SafetySeverity.danger),

  /// `TRUNCATE` removes every row.
  truncate(SafetySeverity.danger),

  /// `DROP` of any object other than a database.
  dropObject(SafetySeverity.danger),

  /// `DROP DATABASE`.
  dropDatabase(SafetySeverity.danger),

  /// `ALTER TABLE ... DROP [COLUMN]`.
  alterTableDropColumn(SafetySeverity.danger),

  /// `GRANT` or `REVOKE` changes access rights.
  grantRevoke(SafetySeverity.warning),

  /// `EXPLAIN ANALYZE` of a writing statement really executes it.
  explainAnalyzeWrites(SafetySeverity.warning),

  /// A `WITH` clause contains `INSERT`/`UPDATE`/`DELETE`/`MERGE`.
  dataModifyingCte(SafetySeverity.warning),

  /// `SELECT ... INTO` creates a new table.
  selectInto(SafetySeverity.warning),

  /// `SELECT ... FOR UPDATE/SHARE` takes row locks (and is rejected in
  /// read-only transactions).
  rowLocking(SafetySeverity.info),

  /// `DO`, `CALL`, `EXECUTE`, `LOAD`, or `COPY ... PROGRAM` runs code whose
  /// effects cannot be analysed.
  opaqueExecution(SafetySeverity.warning),

  /// `ALTER TYPE ... ADD VALUE` cannot run inside a transaction block on
  /// PostgreSQL 11 and older.
  alterTypeAddValue(SafetySeverity.warning),

  /// More than one statement was given where one was expected.
  multipleStatements(SafetySeverity.danger),

  /// The statement could not be recognised or understood.
  unparseable(SafetySeverity.danger),

  /// A string, quoted identifier, or comment is not closed.
  unterminated(SafetySeverity.danger);

  const SafetyFindingCode(this.severity);

  /// The severity every finding with this code has.
  final SafetySeverity severity;
}

/// One safety concern about a statement.
final class SafetyFinding {
  /// Creates a finding; its [severity] comes from [code].
  const SafetyFinding(this.code, this.message, {required this.offset});

  /// Stable identifier, suitable for localisation and UI logic.
  final SafetyFindingCode code;

  /// Human-readable English explanation.
  final String message;

  /// Offset of the relevant token in the analysed text.
  final int offset;

  /// How serious the finding is.
  SafetySeverity get severity => code.severity;

  @override
  bool operator ==(Object other) =>
      other is SafetyFinding &&
      other.code == code &&
      other.message == message &&
      other.offset == offset;

  @override
  int get hashCode => Object.hash(code, message, offset);

  @override
  String toString() =>
      'SafetyFinding(${code.name}, ${severity.name}, @$offset: $message)';
}
