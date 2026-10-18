// File: psql_query.dart
// Purpose: What the describe commands need from a connection (a query
// callback and its result) and what they produce (tables to print and
// psql's messages).

import 'package:dbase_postgresql/src/psql/print/print_table.dart';

/// The rows of one catalog query, as text (SQL NULL is `null`).
final class PsqlResult {
  /// Creates a result. [typeOids] (one per column, or empty) decide
  /// psql's numeric right-alignment.
  const PsqlResult({
    required this.columns,
    required this.rows,
    this.typeOids = const [],
  });

  /// Column names.
  final List<String> columns;

  /// Column type OIDs, or empty when unknown.
  final List<int> typeOids;

  /// Rows of text values.
  final List<List<String?>> rows;

  /// Value at [row], [column]; `''` for NULL, like `PQgetvalue`.
  String value(int row, int column) => rows[row][column] ?? '';

  /// Whether the value is SQL NULL (`PQgetisnull`).
  bool isNull(int row, int column) => rows[row][column] == null;

  /// Index of the column named [name] (`PQfnumber`), or -1.
  int columnIndex(String name) => columns.indexOf(name);
}

/// Runs one read-only catalog query and returns its rows. Errors are
/// thrown as they come (the caller prints them like psql).
typedef PsqlQuery = Future<PsqlResult> Function(String sql);

/// One piece of console output from a describe command.
sealed class PsqlOutput {
  const PsqlOutput();
}

/// A table to print with the current `\pset` options.
final class PsqlTableOutput extends PsqlOutput {
  /// Creates the output.
  const PsqlTableOutput(this.table);

  /// The table.
  final PrintTable table;
}

/// A line psql writes as a message, e.g. `Did not find any relation
/// named "x".` ([isError]: psql writes it to stderr and the command
/// fails).
final class PsqlMessageOutput extends PsqlOutput {
  /// Creates the message. An error fails the command unless [fails] is
  /// false.
  const PsqlMessageOutput(this.text, {this.isError = false, bool? fails})
    : fails = fails ?? isError;

  /// The text, without a trailing newline.
  final String text;

  /// Shown as an error (psql writes it to stderr).
  final bool isError;

  /// The command failed: the rest of the input line is discarded.
  final bool fails;
}

/// `server_version` text (`17.2`, `16.4 (Debian …)`, `18beta1`) as
/// psql's version number (`170002`, `160004`, `180000`); `null` when it
/// can't be read. Versions before 10 use three parts (`9.6.3` → 90603).
int? serverVersionNumber(String? serverVersion) {
  if (serverVersion == null) return null;
  final match = RegExp(r'^\s*(\d+)(?:\.(\d+))?(?:\.(\d+))?')
      .firstMatch(serverVersion);
  if (match == null) return null;
  final major = int.parse(match.group(1)!);
  final second = int.tryParse(match.group(2) ?? '') ?? 0;
  if (major >= 10) return major * 10000 + second;
  final third = int.tryParse(match.group(3) ?? '') ?? 0;
  return major * 10000 + second * 100 + third;
}

/// The result as a table to print (psql's `printQuery`), NULLs shown as
/// [nullDisplay].
PrintTable queryTable(
  PsqlResult result, {
  String? title,
  String nullDisplay = '',
  List<String>? footers,
}) => PrintTable.fromResult(
  columns: result.columns,
  rows: result.rows,
  typeOids: result.typeOids,
  nullDisplay: nullDisplay,
  title: title,
  footers: footers,
);
