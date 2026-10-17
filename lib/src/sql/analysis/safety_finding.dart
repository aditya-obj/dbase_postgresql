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

  /// `UPDATE` or `DELETE` whose top-level `WHERE` is a literal tautology
  /// (`WHERE true`, `WHERE 't'`, `WHERE 1 = 1`, `WHERE NOT false`,
  /// `WHERE x = x`), so it changes every row (`x = x` skips rows where `x`
  /// is NULL). Lexical: only these literal forms are recognised.
  whereAlwaysTrue(SafetySeverity.warning),

  /// `MERGE` whose `ON` condition is a literal tautology (same forms as
  /// [whereAlwaysTrue]) with an unconditional `WHEN MATCHED THEN UPDATE`
  /// or `DELETE`, so every target row is changed.
  mergeUnrestricted(SafetySeverity.danger),

  /// `MERGE ... WHEN NOT MATCHED BY SOURCE ... THEN DELETE` (PostgreSQL
  /// 17+) deletes every target row that has no match in the source.
  mergeDeletesUnmatched(SafetySeverity.danger),

  /// Any `MERGE`: it can insert, update and delete in one statement.
  /// Reported in addition to [mergeUnrestricted] and
  /// [mergeDeletesUnmatched].
  mergeModifies(SafetySeverity.warning),

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

  /// The statement can make later or current transactions read-write,
  /// undoing a session's `default_transaction_read_only = on`:
  /// `SET [SESSION | LOCAL] default_transaction_read_only` or
  /// `transaction_read_only` to anything but `on`/`true`/`yes`/`1`
  /// (including `DEFAULT`), `SET [SESSION CHARACTERISTICS AS] TRANSACTION
  /// ... READ WRITE`, `BEGIN` / `START TRANSACTION ... READ WRITE`,
  /// `RESET` of either setting or `RESET ALL`, `DISCARD ALL`, and
  /// `set_config(...)` calls naming either setting or whose name is not a
  /// plain string literal. See `StatementAnalysis.changesTransactionMode`.
  ///
  /// Lexical: code inside functions, `DO` bodies or procedures is not seen.
  readOnlyEscape(SafetySeverity.danger),

  /// `LOCK [TABLE] ...` takes an explicit table lock until the transaction
  /// ends. The mode is in `StatementAnalysis.lockMode`; a bare `LOCK t` is
  /// `ACCESS EXCLUSIVE`, which blocks even reads.
  explicitLock(SafetySeverity.warning),

  /// A call to a built-in function with side effects that a read-only
  /// transaction does not stop, or that changes state outside the table
  /// data: backend signalling (`pg_terminate_backend`, `pg_cancel_backend`),
  /// server control (`pg_reload_conf`, `pg_rotate_logfile`, `pg_switch_wal`,
  /// `pg_promote`, `pg_create_restore_point`), advisory locks
  /// (`pg_advisory_lock*`, `pg_advisory_xact_lock*`,
  /// `pg_try_advisory_*lock*`), `pg_notify`, `dblink`, `dblink_exec`,
  /// `dblink_connect`, `set_config`, `pg_stat_reset*`, large objects
  /// (`lo_import`, `lo_export`, `lo_unlink`, `lo_create`, `lo_creat`,
  /// `lo_open`, `lo_put`, `lo_from_bytea`, `lo_truncate`, `lo_truncate64`,
  /// `lowrite`), replication slots (`pg_*replication_slot*`), `nextval`
  /// and `setval`.
  ///
  /// Best effort: a name followed by `(` in a statement that runs
  /// expressions (queries, DML, `CALL`, `EXECUTE`), schema-qualified or
  /// not. Names inside strings, dollar-quoted bodies and comments are not
  /// seen, and neither are calls made by user functions or views.
  sideEffectFunction(SafetySeverity.warning),

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
