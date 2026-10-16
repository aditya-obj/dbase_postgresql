// File: pg_config_parse_exception.dart
// Purpose: Typed error thrown when a connection string cannot be parsed.

/// Thrown when a PostgreSQL connection string (URI or key=value conninfo)
/// is malformed.
///
/// The exception deliberately does **not** keep a copy of the input: a
/// connection string often contains a password, and exceptions tend to end
/// up in logs and crash reports. Use [offset] with the string you passed in
/// to point the user at the problem.
final class PgConfigParseException implements Exception {
  /// Creates an exception with a human-readable [message] and the zero-based
  /// UTF-16 [offset] into the input where the problem was found.
  const PgConfigParseException(this.message, {required this.offset});

  /// Human-readable description of the problem. Never contains secrets.
  final String message;

  /// Zero-based UTF-16 code-unit offset into the parsed string.
  final int offset;

  @override
  String toString() => 'PgConfigParseException at offset $offset: $message';
}
