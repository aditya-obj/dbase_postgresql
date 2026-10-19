// File: name_pattern.dart
// Purpose: psql's `\d`-style name patterns (`*`, `?`, `"Exact"`,
// `schema.name`) translated into anchored regular expressions and the
// WHERE clause psql adds to catalog queries.
//
// Ported from src/fe_utils/string_utils.c (patternToSQLRegex,
// processSQLNamePattern) and src/bin/psql/describe.c
// (validateSQLNamePattern) - PostgreSQL License, (c) 1996-2026 PostgreSQL
// Global Development Group. See THIRD_PARTY_NOTICES.

import 'package:dabase_postgresql/src/psql/sql_literal.dart';

/// The regular expressions a pattern turns into.
final class PatternRegex {
  /// Creates the result.
  const PatternRegex({
    required this.name,
    required this.dotCount,
    this.schema,
    this.database,
  });

  /// `^(…)$` for the last part.
  final String name;

  /// `^(…)$` for the part before the last dot, when the caller splits on
  /// dots and there was one.
  final String? schema;

  /// The literal database part of `db.schema.name`, lower-cased outside
  /// quotes like psql (`want_literal_dbname`).
  final String? database;

  /// Dots outside double quotes.
  final int dotCount;
}

/// psql's `patternToSQLRegex`. [maxParts] is how many dot-separated parts
/// the caller accepts as separate regexes (1: name only; 2: schema.name;
/// 3: db.schema.name). Extra dots stay in the last part as `.`.
///
/// Outside double quotes: letters are lower-cased, `*` becomes `.*`, `?`
/// becomes `.`, and other regex characters pass through (so power users
/// can write regexes), except `[]` which is escaped. Inside double quotes
/// everything is literal. `$` is always escaped.
PatternRegex patternToRegex(
  String pattern, {
  int maxParts = 1,
  bool forceEscape = false,
}) {
  final parts = <StringBuffer>[StringBuffer('^(')];
  final literalDb = StringBuffer();
  var left = true;
  var inQuotes = false;
  var dotCount = 0;
  var i = 0;
  StringBuffer current() => parts.last;
  while (i < pattern.length) {
    final ch = pattern[i];
    final unit = pattern.codeUnitAt(i);
    if (ch == '"') {
      if (inQuotes && i + 1 < pattern.length && pattern[i + 1] == '"') {
        current().write('"');
        if (left) literalDb.write('"');
        i += 2;
        continue;
      }
      inQuotes = !inQuotes;
      i++;
    } else if (!inQuotes && unit >= 0x41 && unit <= 0x5A) {
      final lower = String.fromCharCode(unit + 0x20);
      current().write(lower);
      if (left) literalDb.write(lower);
      i++;
    } else if (!inQuotes && ch == '*') {
      current().write('.*');
      if (left) literalDb.write('*');
      i++;
    } else if (!inQuotes && ch == '?') {
      current().write('.');
      if (left) literalDb.write('?');
      i++;
    } else if (!inQuotes && ch == '.') {
      left = false;
      dotCount++;
      if (parts.length < maxParts) {
        current().write(r')$');
        parts.add(StringBuffer('^('));
      } else {
        current().write('.');
      }
      i++;
    } else if (ch == r'$') {
      current().write(r'\$');
      if (left) literalDb.write(r'$');
      i++;
    } else {
      if ((inQuotes || forceEscape) && r'|*+?()[]{}.^$\'.contains(ch)) {
        current().write(r'\');
      } else if (ch == '[' && i + 1 < pattern.length && pattern[i + 1] == ']') {
        current().write(r'\');
      }
      current().write(ch);
      if (left) literalDb.write(ch);
      i++;
    }
  }
  current().write(r')$');

  final regexes = [for (final p in parts) p.toString()];
  final name = regexes.removeLast();
  final schema = regexes.isEmpty ? null : regexes.removeLast();
  final database = regexes.isEmpty ? null : literalDb.toString();
  return PatternRegex(
    name: name,
    schema: schema,
    database: database,
    dotCount: dotCount,
  );
}

/// The result of [processNamePattern]: the clause to append and whether
/// it added a condition.
final class NamePatternClause {
  /// Creates the result.
  const NamePatternClause(this.sql, {required this.addedClause});

  /// Text to append to the query (each condition ends with a newline).
  final String sql;

  /// Whether a WHERE/AND condition was written.
  final bool addedClause;
}

/// Thrown for patterns psql refuses (too many dots, another database).
final class NamePatternException implements Exception {
  /// Creates the exception.
  const NamePatternException(this.message);

  /// psql's message.
  final String message;

  @override
  String toString() => 'NamePatternException: $message';
}

/// psql's `processSQLNamePattern` + `validateSQLNamePattern`.
///
/// Appends conditions matching [pattern] against [nameVar] (and
/// [altNameVar], e.g. `format_type(...)` for types) and [schemaVar].
/// Without a pattern, or without a schema part, [visibilityRule] (such as
/// `pg_catalog.pg_table_is_visible(c.oid)`) limits the match to objects
/// on the search_path. [haveWhere] says whether the query already has a
/// WHERE. [maxParts] is psql's limit (3 for `db.schema.name`, 1 for
/// roles and databases); [currentDatabase] checks the `db` part.
///
/// Throws [NamePatternException] like psql: `improper qualified name
/// (too many dotted names)` or `cross-database references are not
/// implemented`.
NamePatternClause processNamePattern(
  String? pattern, {
  required bool haveWhere,
  String? schemaVar,
  String? nameVar,
  String? altNameVar,
  String? visibilityRule,
  int maxParts = 3,
  String? currentDatabase,
  bool forceEscape = false,
}) {
  final out = StringBuffer();
  var where = haveWhere;
  var added = false;
  void whereAnd() {
    out.write(where ? '  AND ' : 'WHERE ');
    where = true;
    added = true;
  }

  if (pattern == null) {
    if (visibilityRule != null) {
      whereAnd();
      out.writeln(visibilityRule);
    }
    return NamePatternClause(out.toString(), addedClause: added);
  }

  final regex = patternToRegex(
    pattern,
    maxParts: schemaVar != null ? 3 : 1,
    forceEscape: forceEscape,
  );

  if (regex.dotCount >= maxParts) {
    throw NamePatternException(
      'improper qualified name (too many dotted names): $pattern',
    );
  }
  if (maxParts > 1 && regex.dotCount == maxParts - 1) {
    if (currentDatabase == null || regex.database != currentDatabase) {
      throw NamePatternException(
        'cross-database references are not implemented: $pattern',
      );
    }
  }

  const collate = ' COLLATE pg_catalog.default';
  if (nameVar != null && regex.name.length > 2 && regex.name != r'^(.*)$') {
    whereAnd();
    final literal = sqlStringLiteral(regex.name);
    if (altNameVar != null) {
      out
        ..write('($nameVar OPERATOR(pg_catalog.~) $literal$collate')
        ..write('\n        OR $altNameVar OPERATOR(pg_catalog.~) ')
        ..write('$literal$collate)\n');
    } else {
      out.write('$nameVar OPERATOR(pg_catalog.~) $literal$collate\n');
    }
  }

  final schema = regex.schema;
  if (schemaVar != null && schema != null && schema.length > 2) {
    if (schema != r'^(.*)$') {
      whereAnd();
      out.write(
        '$schemaVar OPERATOR(pg_catalog.~) '
        '${sqlStringLiteral(schema)}$collate\n',
      );
    }
  } else if (visibilityRule != null) {
    whereAnd();
    out.writeln(visibilityRule);
  }
  return NamePatternClause(out.toString(), addedClause: added);
}
