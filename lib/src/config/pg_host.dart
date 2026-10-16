// File: pg_host.dart
// Purpose: One host/port pair of a (possibly multi-host) connection target.

/// A single server address from a connection string.
///
/// libpq keeps hosts and ports as parallel lists; a [PgHost] is one
/// position of those lists. Multi-host strings (`postgres://a,b:5433/db`)
/// produce one [PgHost] per entry, in order.
final class PgHost {
  /// Creates a host entry.
  ///
  /// [host] may be a DNS name, an IPv4 address, an IPv6 address **without**
  /// brackets, a Unix-socket directory (starting with `/`, or `@` for a
  /// Linux abstract socket), or empty for libpq's default (a local
  /// socket). [port] is `null` when the connection string did not give one.
  const PgHost(this.host, {this.port});

  /// PostgreSQL's default TCP port.
  static const int defaultPort = 5432;

  /// Host name, address, or socket directory, without IPv6 brackets.
  final String host;

  /// The port given in the connection string (1-65535), or `null` when it
  /// was absent or empty.
  final int? port;

  /// [port], or [defaultPort] when none was given.
  int get effectivePort => port ?? defaultPort;

  /// Whether this entry means a Unix-domain socket rather than TCP: an
  /// empty host (libpq's default), an absolute path, or an abstract socket
  /// name starting with `@` (libpq's `is_unixsock_path`).
  bool get isUnixSocket =>
      host.isEmpty || host.startsWith('/') || host.startsWith('@');

  /// Whether [host] is an IPv6 literal (contains a colon).
  bool get isIpv6 => host.contains(':');

  @override
  bool operator ==(Object other) =>
      other is PgHost && other.host == host && other.port == port;

  @override
  int get hashCode => Object.hash(host, port);

  @override
  String toString() =>
      '${isIpv6 ? '[$host]' : host}${port == null ? '' : ':$port'}';
}
