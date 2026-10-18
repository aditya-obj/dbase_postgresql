// File: csv_field_value.dart
// Purpose: Turns a decoded field into the value to load: SQL NULL or text,
// by PostgreSQL's CSV rule or the user's choice.

import 'package:dbase_postgresql/src/csv/csv_record.dart';

/// What an empty field means.
enum EmptyFieldRule {
  /// PostgreSQL's CSV rule: empty unquoted is NULL, `""` is an empty
  /// string.
  nullUnlessQuoted,

  /// Every empty field is NULL.
  alwaysNull,

  /// Every empty field is an empty string.
  emptyString,
}

/// The value of field [i] of [record]: `null` for SQL NULL. A field the
/// record doesn't have is NULL. A field equal to [nullMarker] (e.g. `\N`
/// or `NULL`), when given and unquoted, is NULL too.
String? fieldValue(
  CsvRecord record,
  int i, {
  EmptyFieldRule empty = EmptyFieldRule.nullUnlessQuoted,
  String? nullMarker,
}) {
  if (i < 0 || i >= record.fields.length) return null;
  final value = record.fields[i];
  final quoted = record.quoted[i];
  if (nullMarker != null && !quoted && value == nullMarker) return null;
  if (value.isNotEmpty) return value;
  return switch (empty) {
    EmptyFieldRule.nullUnlessQuoted => quoted ? '' : null,
    EmptyFieldRule.alwaysNull => null,
    EmptyFieldRule.emptyString => '',
  };
}
