// File: sql_literal.dart
// Purpose: SQL string constants for the catalog queries the console
// builds from user patterns.
//
// Behaviour of appendStringLiteralConn from src/fe_utils/string_utils.c -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

/// [value] as an SQL string constant. Like psql, text with a backslash is
/// written as `E'…'` with backslashes doubled, so it reads the same
/// whether `standard_conforming_strings` is on or off; quotes are doubled.
String sqlStringLiteral(String value) {
  final quoted = value.replaceAll("'", "''");
  if (!value.contains(r'\')) return "'$quoted'";
  return "E'${quoted.replaceAll(r'\', r'\\')}'";
}
