// File: table_lock_mode.dart
// Purpose: PostgreSQL table-level lock modes, as named in `LOCK ... IN
// <mode> MODE`, ordered from weakest to strongest.

/// A table-level lock mode, see
/// https://www.postgresql.org/docs/current/explicit-locking.html.
///
/// Values are ordered like PostgreSQL's lock levels (`AccessShareLock` = 1
/// to `AccessExclusiveLock` = 8 in `src/include/storage/lockdefs.h`), so
/// `a.index > b.index` means `a` has the higher lock level. Modes above
/// [rowExclusive] are refused on a hot standby and conflict with other
/// sessions' schema changes and maintenance; from [share] up they also
/// block ordinary writes (`INSERT`/`UPDATE`/`DELETE`), and
/// [accessExclusive] blocks even plain `SELECT`. See the
/// documentation's conflict table for the exact rules.
enum TableLockMode {
  /// `ACCESS SHARE`: taken by `SELECT`; conflicts only with
  /// [accessExclusive].
  accessShare('ACCESS SHARE'),

  /// `ROW SHARE`: taken by `SELECT ... FOR UPDATE/SHARE`.
  rowShare('ROW SHARE'),

  /// `ROW EXCLUSIVE`: taken by `INSERT`, `UPDATE`, `DELETE` and `MERGE`.
  rowExclusive('ROW EXCLUSIVE'),

  /// `SHARE UPDATE EXCLUSIVE`: taken by `VACUUM`, `ANALYZE` and
  /// `CREATE INDEX CONCURRENTLY`.
  shareUpdateExclusive('SHARE UPDATE EXCLUSIVE'),

  /// `SHARE`: taken by `CREATE INDEX`; blocks writes.
  share('SHARE'),

  /// `SHARE ROW EXCLUSIVE`: blocks writes and other `SHARE` locks.
  shareRowExclusive('SHARE ROW EXCLUSIVE'),

  /// `EXCLUSIVE`: blocks everything except plain reads.
  exclusive('EXCLUSIVE'),

  /// `ACCESS EXCLUSIVE`: blocks every access, including `SELECT`. The
  /// default for `LOCK` without `IN ... MODE`.
  accessExclusive('ACCESS EXCLUSIVE');

  const TableLockMode(this.sql);

  /// The mode as written in SQL, upper case, e.g. `ROW EXCLUSIVE`.
  final String sql;
}
