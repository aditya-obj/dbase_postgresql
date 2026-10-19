// File: dump_options.dart
// Purpose: What a SQL dump covers and how, plus the warning codes a dump
// reports (codes, not text, so an app can translate them).

import 'package:dabase_postgresql/src/catalog/catalog_reader.dart';

/// Which sections a dump writes.
enum DumpContent {
  /// Pre-data, data and post-data (pg_dump's default).
  schemaAndData,

  /// Pre-data and post-data (`pg_dump --schema-only`).
  schemaOnly,

  /// Table data and sequence values (`pg_dump --data-only`).
  dataOnly;

  /// Whether DDL is written.
  bool get hasSchema => this != dataOnly;

  /// Whether table data and sequence values are written.
  bool get hasData => this != schemaOnly;
}

/// What a dump covers and how.
final class DumpOptions {
  /// Creates dump options.
  const DumpOptions({
    required this.scope,
    this.content = DumpContent.schemaAndData,
    this.includeGrants = false,
    this.visibleRowsOnly = false,
  });

  /// The objects to dump.
  final CatalogScope scope;

  /// Which sections to write.
  final DumpContent content;

  /// Write GRANTs and default privileges (off by default: the roles may
  /// not exist where the file is restored).
  final bool includeGrants;

  /// For tables where row-level security applies to the current user,
  /// export only the rows that user can see (`pg_dump
  /// --enable-row-security`). Off by default: such a table then fails
  /// instead of being exported incomplete.
  final bool visibleRowsOnly;
}

/// Why a dump warns.
enum DumpWarningCode {
  /// Objects that depend on each other in a cycle the dump could not
  /// break; written in a best-effort order. Subjects: their names.
  dependencyCycle,

  /// Foreign keys that reference tables outside the dump. Subjects:
  /// `table -> referenced table`.
  outsideReference,

  /// `money` columns: their text depends on `lc_monetary`, which must
  /// match on restore. Subjects: tables.
  moneyColumns,

  /// Sequences the current user may not read; their value is not
  /// restored. Subjects: sequences.
  unreadableSequence,

  /// Tables exported with only the rows row-level security lets the
  /// current user see. Subjects: tables.
  visibleRowsOnly,

  /// A data-only dump has foreign keys in a cycle: restoring it into a
  /// schema with those keys may fail. Subjects: tables.
  dataOnlyForeignKeyCycle,

  /// The server is a hot standby: a long export can be cancelled by
  /// recovery conflicts. No subjects.
  hotStandby,

  /// The dump holds locks that make schema changes on its tables wait
  /// until it finishes. No subjects.
  locksHeld,
}

/// One warning, with the objects it is about.
final class DumpWarning {
  /// Creates a warning.
  const DumpWarning(this.code, [this.subjects = const []]);

  /// Why.
  final DumpWarningCode code;

  /// Names of the objects concerned.
  final List<String> subjects;

  @override
  String toString() =>
      subjects.isEmpty ? code.name : '${code.name}: ${subjects.join(', ')}';
}
