// File: pg_import_diagnostic.dart
// Purpose: Diagnostics and the typed exception shared by the .pgpass,
// pg_service.conf and pgAdmin servers.json importers.

/// How serious a [PgLineDiagnostic] is.
enum PgImportSeverity {
  /// libpq (or pgAdmin) would reject this line or section; nothing usable
  /// was produced from it.
  error,

  /// The line was read the way libpq reads it, but the result is probably
  /// not what the author meant (for example trailing whitespace that
  /// becomes part of a password).
  warning,

  /// Informational: the line was ignored or overridden exactly as libpq
  /// would do it.
  info,
}

/// A problem found on one line of an imported text file.
///
/// [C] is the format's code enum, e.g. `PgPassDiagnosticCode` or
/// `PgServiceDiagnosticCode`. [message] is English text that never
/// contains values from the file, so a diagnostic is safe to log even
/// when the line held a password.
final class PgLineDiagnostic<C extends Enum> {
  /// Creates a diagnostic for the one-based [line].
  const PgLineDiagnostic({
    required this.line,
    required this.code,
    required this.severity,
    required this.message,
  });

  /// One-based line number in the imported text.
  final int line;

  /// Stable identifier, suitable for localisation and UI logic.
  final C code;

  /// How serious the problem is.
  final PgImportSeverity severity;

  /// Human-readable English explanation. Never contains file values.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is PgLineDiagnostic<C> &&
      other.line == line &&
      other.code == code &&
      other.severity == severity &&
      other.message == message;

  @override
  int get hashCode => Object.hash(line, code, severity, message);

  @override
  String toString() =>
      'PgLineDiagnostic(line $line, ${severity.name} ${code.name}: $message)';
}

/// Thrown when an imported file cannot be read at all, for example
/// malformed JSON or a `servers.json` without a `Servers` object.
///
/// Like `PgConfigParseException`, it keeps no copy of the input: imported
/// files can hold passwords. Use [offset] to point at the problem.
final class PgImportException implements Exception {
  /// Creates an exception with a human-readable [message] and, when known,
  /// the zero-based UTF-16 [offset] into the input.
  const PgImportException(this.message, {this.offset});

  /// Human-readable description of the problem. Never contains file
  /// values.
  final String message;

  /// Zero-based UTF-16 code-unit offset into the input, or `null` when the
  /// problem is not tied to one position.
  final int? offset;

  @override
  String toString() => offset == null
      ? 'PgImportException: $message'
      : 'PgImportException at offset $offset: $message';
}
