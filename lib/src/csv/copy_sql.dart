// File: copy_sql.dart
// Purpose: SQL for loading CSV data: the `COPY ... FROM STDIN` statement,
// and the `INSERT ... SELECT ... FROM unnest(...)` fallback for tables
// where COPY is refused (row-level security), with its array literals.

/// What `COPY` does with a value that doesn't convert.
enum CopyOnError {
  /// Stop with an error (every version).
  stop,

  /// Skip the row (PostgreSQL 17+, `ON_ERROR ignore`).
  ignore,
}

/// Quotes an identifier, always: `"name"` with `"` doubled.
String _ident(String name) {
  if (name.isEmpty || name.contains('\u0000')) {
    throw ArgumentError.value(name, 'name', 'not a valid identifier');
  }
  return '"${name.replaceAll('"', '""')}"';
}

String _columnList(List<String> columns) {
  if (columns.isEmpty) {
    throw ArgumentError.value(columns, 'columns', 'must not be empty');
  }
  return columns.map(_ident).join(', ');
}

/// `COPY "s"."t" ("a", "b") FROM STDIN (FORMAT csv)`, every name quoted.
///
/// [onError] `ignore` adds `ON_ERROR ignore, LOG_VERBOSITY verbose` and
/// needs [serverVersionNum] ≥ 170000; [rejectLimit] (stop after that many
/// skipped rows) needs `ignore` and ≥ 180000. Otherwise throws
/// [ArgumentError].
String copyFromStdinSql(
  String schema,
  String table,
  List<String> columns, {
  required int serverVersionNum,
  CopyOnError onError = CopyOnError.stop,
  int? rejectLimit,
}) {
  final options = ['FORMAT csv'];
  if (onError == CopyOnError.ignore) {
    if (serverVersionNum < 170000) {
      throw ArgumentError.value(onError, 'onError', 'needs PostgreSQL 17');
    }
    options.addAll(['ON_ERROR ignore', 'LOG_VERBOSITY verbose']);
  }
  if (rejectLimit != null) {
    if (onError != CopyOnError.ignore || serverVersionNum < 180000) {
      throw ArgumentError.value(
        rejectLimit,
        'rejectLimit',
        'needs ON_ERROR ignore and PostgreSQL 18',
      );
    }
    if (rejectLimit < 1) {
      throw ArgumentError.value(rejectLimit, 'rejectLimit', 'must be ≥ 1');
    }
    options.add('REJECT_LIMIT $rejectLimit');
  }
  return 'COPY ${_ident(schema)}.${_ident(table)} (${_columnList(columns)}) '
      'FROM STDIN (${options.join(', ')})';
}

/// `INSERT INTO "s"."t" ("a", "b") SELECT CAST(u.c1 AS type1), … FROM
/// unnest($1::text[], $2::text[]) AS u(c1, c2)`: one text-array parameter
/// per column ([pgArrayLiteral]), each element cast to its column type.
///
/// [types] are type names as `format_type` prints them, inserted as
/// written: pass only names that came from the server's catalog.
String insertFromUnnestSql(
  String schema,
  String table,
  List<String> columns,
  List<String> types,
) {
  if (types.length != columns.length) {
    throw ArgumentError.value(types, 'types', 'one per column');
  }
  final n = columns.length;
  final casts = [
    for (var i = 0; i < n; i++) 'CAST(u.c${i + 1} AS ${types[i]})',
  ];
  final arrays = [for (var i = 1; i <= n; i++) '\$$i::text[]'];
  final aliases = [for (var i = 1; i <= n; i++) 'c$i'];
  return 'INSERT INTO ${_ident(schema)}.${_ident(table)} '
      '(${_columnList(columns)}) SELECT ${casts.join(', ')} '
      'FROM unnest(${arrays.join(', ')}) AS u(${aliases.join(', ')})';
}

/// A one-dimensional `text[]` literal: `{"a","b c",NULL,"x\"y"}`. Every
/// element is quoted, with `\` and `"` escaped by a backslash, so `NULL`
/// written by a user stays a string; `null` is the SQL NULL.
String pgArrayLiteral(Iterable<String?> values) {
  final out = StringBuffer('{');
  var first = true;
  for (final v in values) {
    if (!first) out.write(',');
    first = false;
    if (v == null) {
      out.write('NULL');
    } else {
      out
        ..write('"')
        ..write(v.replaceAll(r'\', r'\\').replaceAll('"', r'\"'))
        ..write('"');
    }
  }
  out.write('}');
  return out.toString();
}
