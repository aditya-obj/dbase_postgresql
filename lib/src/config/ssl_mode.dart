// File: ssl_mode.dart
// Purpose: libpq-compatible `sslmode` values and their security properties.

/// How a connection negotiates TLS, mirroring libpq's `sslmode` setting.
///
/// When a connection string does not name a mode, libpq (and
/// `PgConnectionConfig`) use [prefer], which can silently fall back to an
/// unencrypted connection. Callers that want a safer default should check
/// `PgConnectionConfig.sslModeWasExplicit` and apply their own policy.
enum SslMode {
  /// Never use TLS. Credentials and data travel in plaintext.
  disable('disable'),

  /// Try plaintext first, use TLS only if the server insists.
  allow('allow'),

  /// Try TLS first, fall back to plaintext if the server refuses (libpq
  /// default).
  prefer('prefer'),

  /// Require TLS but do not verify the server certificate.
  require('require'),

  /// Require TLS and verify the certificate chain, but not the host name.
  verifyCa('verify-ca'),

  /// Require TLS, verify the certificate chain and the host name.
  verifyFull('verify-full');

  const SslMode(this.libpqName);

  /// The value as written in a connection string, e.g. `verify-full`.
  final String libpqName;

  /// Returns the mode whose [libpqName] equals [value] (ASCII
  /// case-insensitive), or `null` when [value] is not a known mode.
  static SslMode? tryParse(String value) {
    final lower = value.toLowerCase();
    for (final mode in values) {
      if (mode.libpqName == lower) return mode;
    }
    return null;
  }

  /// Whether the connection is guaranteed to be encrypted.
  bool get requiresEncryption => index >= SslMode.require.index;

  /// Whether the server certificate chain is verified.
  bool get verifiesCertificate => index >= SslMode.verifyCa.index;

  /// Whether the server host name is checked against its certificate.
  bool get verifiesHostName => this == SslMode.verifyFull;
}
