// File: libpq_describe.dart
// Purpose: Test helper that renders a PgConnectionConfig the way libpq's
// libpq_uri_regress tool prints a parsed URI, so corpus outputs compare
// directly.

import 'package:dbase_postgresql/connection_string.dart';

/// Renders [config] as `user='u' dbname='d' host='h' port='p' (inet)`.
///
/// Keyword order follows libpq's option table. `(inet)` means a TCP
/// target (a non-socket host or a `hostaddr`), `(local)` a Unix socket.
/// Parameters libpq would reject (kept by this parser) are appended after
/// the marker so divergences stay visible.
String describeLikeLibpq(PgConnectionConfig config) {
  final hosts = config.hosts;
  final hostaddr = config.parameters['hostaddr'];
  final fields = <String, String?>{
    'user': config.user,
    'password': config.password,
    'dbname': config.database,
    'host': hosts.any((h) => h.host.isNotEmpty)
        ? hosts.map((h) => h.host).join(',')
        : null,
    'hostaddr': hostaddr,
    'port': hosts.any((h) => h.port != null)
        ? hosts.map((h) => h.port ?? '').join(',')
        : null,
    'sslmode': config.sslModeWasExplicit ? config.sslMode.libpqName : null,
  };
  final isInet = hostaddr != null || hosts.any((h) => !h.isUnixSocket);
  return [
    for (final MapEntry(:key, :value) in fields.entries)
      if (value != null) "$key='$value'",
    if (isInet) '(inet)' else '(local)',
    for (final MapEntry(:key, :value) in config.parameters.entries)
      if (key != 'hostaddr') "$key='$value'",
  ].join(' ');
}
