// File: statement_kind.dart
// Purpose: Broad categories of SQL statements reported by
// SqlStatementAnalyzer.

/// The broad category of a SQL statement.
enum StatementKind {
  /// `SELECT`, `VALUES`, `TABLE`, or a parenthesised query.
  select,

  /// `INSERT`.
  insert,

  /// `UPDATE`.
  update,

  /// `DELETE`.
  delete,

  /// `MERGE` (PostgreSQL 15+).
  merge,

  /// Schema and privilege changes: `CREATE`, `ALTER`, `DROP`, `COMMENT`,
  /// `GRANT`, `REVOKE`, `SECURITY LABEL`, `IMPORT FOREIGN SCHEMA`,
  /// `REASSIGN OWNED`.
  ddl,

  /// `TRUNCATE`.
  truncate,

  /// `BEGIN`, `START TRANSACTION`, `COMMIT`, `ROLLBACK`, `SAVEPOINT`,
  /// `RELEASE`, `END`, `ABORT`, and two-phase commit commands.
  transactionControl,

  /// `VACUUM`, `ANALYZE`, `REINDEX`, `CLUSTER`, `CHECKPOINT`,
  /// `REFRESH MATERIALIZED VIEW`.
  maintenance,

  /// Session and other utility commands: `SET`, `SHOW`, `RESET`,
  /// `EXPLAIN`, `COPY`, `LISTEN`, `UNLISTEN`, `NOTIFY`, `DO`, `CALL`,
  /// `LOCK`, `PREPARE`, `EXECUTE`, `DEALLOCATE`, `DISCARD`, `LOAD`, and
  /// cursor commands.
  utility,

  /// Nothing but whitespace and comments.
  empty,

  /// Not recognised, or not safely analysable. Always treated as writing
  /// and always carries a finding that requires confirmation.
  unknown,
}
