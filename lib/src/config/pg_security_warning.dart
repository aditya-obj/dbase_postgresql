// File: pg_security_warning.dart
// Purpose: Security concerns detected in a parsed connection configuration.

/// Stable identifiers for [PgSecurityWarning]s, suitable for localisation
/// and for UI logic (e.g. showing a lock icon).
enum PgSecurityWarningCode {
  /// No `sslmode` was given, so libpq's default (`prefer`) applies.
  sslModeNotSpecified,

  /// `sslmode` is `prefer` or `allow`: the connection can silently fall back
  /// to plaintext, exposing credentials and data.
  sslMayFallBackToPlaintext,

  /// `sslmode=disable`: credentials and data are sent unencrypted.
  sslDisabled,

  /// TLS is used but the server identity is not fully verified
  /// (`require` or `verify-ca`), so a man-in-the-middle is possible.
  serverIdentityNotVerified,

  /// The password was embedded in the connection string, which is easy to
  /// leak through clipboard, history, screenshots, or logs.
  passwordInConnectionString,
}

/// A security concern about a connection configuration.
final class PgSecurityWarning {
  /// Creates a warning with a stable [code] and an English [message].
  const PgSecurityWarning(this.code, this.message);

  /// Stable identifier for this warning.
  final PgSecurityWarningCode code;

  /// Human-readable English explanation. Never contains secrets.
  final String message;

  @override
  bool operator ==(Object other) =>
      other is PgSecurityWarning &&
      other.code == code &&
      other.message == message;

  @override
  int get hashCode => Object.hash(code, message);

  @override
  String toString() => 'PgSecurityWarning(${code.name}: $message)';
}
