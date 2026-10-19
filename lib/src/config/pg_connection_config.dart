// File: pg_connection_config.dart
// Purpose: Typed PostgreSQL connection settings parsed from URIs or libpq
// conninfo strings, with libpq default resolution, security warnings, and
// secret-safe formatting.

import 'package:dabase_postgresql/src/config/config_builder.dart';
import 'package:dabase_postgresql/src/config/config_formatter.dart';
import 'package:dabase_postgresql/src/config/conninfo_parser.dart';
import 'package:dabase_postgresql/src/config/pg_config_parse_exception.dart';
import 'package:dabase_postgresql/src/config/pg_host.dart';
import 'package:dabase_postgresql/src/config/pg_security_warning.dart';
import 'package:dabase_postgresql/src/config/raw_setting.dart';
import 'package:dabase_postgresql/src/config/ssl_mode.dart';
import 'package:dabase_postgresql/src/config/uri_parser.dart';

/// Immutable PostgreSQL connection settings.
///
/// Create one with [PgConnectionConfig.parse] from a `postgres://` /
/// `postgresql://` URI or a libpq `key=value` string, or build one directly.
/// Parsing is pure: it never reads the environment. Call
/// [resolveDefaults] to apply libpq's `PG*` variable and default rules.
///
/// SSL defaults follow libpq: when no `sslmode` is given, [sslMode] is
/// [SslMode.prefer] and [sslModeWasExplicit] is `false`. That mode can fall
/// back to plaintext; inspect [securityWarnings] and apply app policy (for
/// example, `copyWith(sslMode: SslMode.verifyFull)`).
///
/// Deliberate differences from libpq are recorded in
/// `doc/adr/0001-libpq-divergences.md`.
final class PgConnectionConfig {
  /// Creates a configuration. Passing [sslMode] marks it as explicit; leaving
  /// it `null` applies libpq's default ([SslMode.prefer]).
  PgConnectionConfig({
    List<PgHost> hosts = const [],
    String? user,
    String? password,
    String? database,
    SslMode? sslMode,
    Map<String, String> parameters = const {},
  }) : this._(
         hosts: hosts,
         user: user,
         password: password,
         database: database,
         sslMode: sslMode,
         parameters: parameters,
         passwordEmbedded: false,
       );

  PgConnectionConfig._({
    required List<PgHost> hosts,
    required this.user,
    required this.password,
    required this.database,
    required SslMode? sslMode,
    required Map<String, String> parameters,
    required bool passwordEmbedded,
  }) : hosts = List.unmodifiable(hosts),
       sslMode = sslMode ?? SslMode.prefer,
       sslModeWasExplicit = sslMode != null,
       parameters = Map.unmodifiable(parameters),
       _passwordEmbedded = passwordEmbedded && password != null;

  /// Parses a URI (`postgres://...` or `postgresql://...`) or a libpq
  /// conninfo string (`host=... dbname=...`).
  ///
  /// Throws [PgConfigParseException] when the input is malformed, contains
  /// a NUL character (raw or `%00`), or has an invalid value (bad port,
  /// unknown `sslmode`, port/host count mismatch...). Error messages never
  /// repeat the input. Unknown keywords are kept in [parameters] rather
  /// than rejected.
  factory PgConnectionConfig.parse(String connectionString) {
    final nul = connectionString.indexOf('\u0000');
    if (nul >= 0) {
      throw PgConfigParseException(
        'NUL characters are not allowed in a connection string.',
        offset: nul,
      );
    }
    final trimmed = connectionString.trim();
    final lead = connectionString.length - connectionString.trimLeft().length;
    if (trimmed.isEmpty) {
      throw const PgConfigParseException(
        'Connection string is empty.',
        offset: 0,
      );
    }
    final RawSettings settings;
    if (uriSchemeLength(trimmed) > 0) {
      settings = parseUriSettings(trimmed, baseOffset: lead);
    } else if (trimmed.toLowerCase().startsWith('jdbc:')) {
      throw PgConfigParseException(
        'JDBC URLs are not supported; remove the "jdbc:" prefix.',
        offset: lead,
      );
    } else if (trimmed.contains('=')) {
      settings = parseConninfoSettings(connectionString);
    } else {
      throw PgConfigParseException(
        'Expected a postgres:// URI or key=value connection string.',
        offset: lead,
      );
    }
    return PgConnectionConfig._fromSettings(settings, passwordEmbedded: true);
  }

  factory PgConnectionConfig._fromSettings(
    RawSettings settings, {
    required bool passwordEmbedded,
  }) {
    final v = validateSettings(settings);
    return PgConnectionConfig._(
      hosts: v.hosts,
      user: v.user,
      password: v.password,
      database: v.database,
      sslMode: v.sslMode,
      parameters: v.parameters,
      passwordEmbedded: passwordEmbedded,
    );
  }

  /// Like [PgConnectionConfig.parse] but returns `null` instead of throwing.
  static PgConnectionConfig? tryParse(String connectionString) {
    try {
      return PgConnectionConfig.parse(connectionString);
    } on PgConfigParseException {
      return null;
    }
  }

  /// Target servers in the order libpq would try them. Empty means "not
  /// given" (libpq then uses a local socket); see [PgHost.isUnixSocket].
  final List<PgHost> hosts;

  /// Role name, or `null` when not given.
  final String? user;

  /// Password, or `null` when not given. Never shown by [redacted] or
  /// [toString].
  final String? password;

  /// Database name (`dbname`) exactly as given, or `null` when absent. See
  /// [effectiveDatabase] for libpq's fallback.
  final String? database;

  /// The effective SSL mode ([SslMode.prefer] when not given).
  final SslMode sslMode;

  /// Whether `sslmode` (or the legacy `ssl=true`) was set explicitly.
  final bool sslModeWasExplicit;

  /// All other keywords, e.g. `application_name`, `connect_timeout`,
  /// `options`, `sslrootcert`, `target_session_attrs`, `channel_binding`,
  /// `hostaddr`. Unmodifiable; insertion order follows the source string.
  final Map<String, String> parameters;

  final bool _passwordEmbedded;

  /// The first host name, or `null` when [hosts] is empty.
  String? get host => hosts.isEmpty ? null : hosts.first.host;

  /// The first host's effective port ([PgHost.defaultPort] when unset).
  int get port =>
      hosts.isEmpty ? PgHost.defaultPort : hosts.first.effectivePort;

  /// The database libpq would connect to: [database], else [user] (libpq's
  /// rule), else `null`. Never invents a name such as `postgres`.
  String? get effectiveDatabase => database ?? user;

  /// The `application_name` parameter, if set.
  String? get applicationName => parameters['application_name'];

  /// The `connect_timeout` parameter as a [Duration], if set.
  Duration? get connectTimeout {
    final seconds = int.tryParse(parameters['connect_timeout'] ?? '');
    return seconds == null ? null : Duration(seconds: seconds);
  }

  /// Returns a copy with libpq's fallbacks applied, without touching the
  /// real environment: each keyword missing here is taken from its `PG*`
  /// variable in [environment] (e.g. `PGHOST`, `PGPORT`, `PGUSER`,
  /// `PGPASSWORD`, `PGDATABASE`, `PGSSLMODE`), then `user` falls back to
  /// [defaultUser] (libpq uses the OS user name) and `dbname` to the user.
  ///
  /// Service files and password files are not read. Throws
  /// [PgConfigParseException] (offset 0) when an environment value is
  /// invalid.
  PgConnectionConfig resolveDefaults({
    Map<String, String> environment = const {},
    String? defaultUser,
  }) {
    final resolved = withDefaults(
      configToSettings(this),
      environment: environment,
      defaultUser: defaultUser,
    );
    final passwordUnchanged = resolved['password']?.value == password;
    return PgConnectionConfig._fromSettings(
      resolved,
      passwordEmbedded: _passwordEmbedded && passwordUnchanged,
    );
  }

  /// Security concerns about this configuration, most important first.
  List<PgSecurityWarning> get securityWarnings => [
    if (sslMode == SslMode.disable)
      const PgSecurityWarning(
        PgSecurityWarningCode.sslDisabled,
        'SSL is disabled: the password and all data are sent unencrypted.',
      ),
    if (sslMode == SslMode.prefer || sslMode == SslMode.allow)
      PgSecurityWarning(
        PgSecurityWarningCode.sslMayFallBackToPlaintext,
        'sslmode=${sslMode.libpqName} can silently fall back to an '
        'unencrypted connection.',
      ),
    if (sslMode == SslMode.require || sslMode == SslMode.verifyCa)
      PgSecurityWarning(
        PgSecurityWarningCode.serverIdentityNotVerified,
        'sslmode=${sslMode.libpqName} does not fully verify the server '
        'identity; use verify-full to prevent man-in-the-middle attacks.',
      ),
    if (!sslModeWasExplicit)
      const PgSecurityWarning(
        PgSecurityWarningCode.sslModeNotSpecified,
        'No sslmode given; the libpq default "prefer" applies.',
      ),
    if (_passwordEmbedded)
      const PgSecurityWarning(
        PgSecurityWarningCode.passwordInConnectionString,
        'The password is embedded in the connection string; store it '
        'separately in secure storage.',
      ),
  ];

  /// Formats this configuration as a `postgresql://` URI that
  /// [PgConnectionConfig.parse] reads back to equivalent settings.
  ///
  /// Secrets (the password, `sslpassword`, and other secret keywords) are
  /// left out unless [includePassword] is `true`. `sslmode` is written only
  /// when it was explicit, and ports only when they were given.
  String toUri({bool includePassword = false}) => formatConfigUri(
    this,
    secrets: includePassword ? SecretOutput.include : SecretOutput.omit,
  );

  /// A log-safe URI: secrets are replaced with `****`, and every other
  /// value is percent-encoded, so CR/LF cannot inject log lines.
  String redacted() => formatConfigUri(this, secrets: SecretOutput.mask);

  /// Returns a copy with the given fields replaced. Passing [sslMode] marks
  /// it as explicit. Fields cannot be cleared to `null` this way.
  PgConnectionConfig copyWith({
    List<PgHost>? hosts,
    String? user,
    String? password,
    String? database,
    SslMode? sslMode,
    Map<String, String>? parameters,
  }) => PgConnectionConfig._(
    hosts: hosts ?? this.hosts,
    user: user ?? this.user,
    password: password ?? this.password,
    database: database ?? this.database,
    sslMode: sslMode ?? (sslModeWasExplicit ? this.sslMode : null),
    parameters: parameters ?? this.parameters,
    passwordEmbedded: password == null && _passwordEmbedded,
  );

  /// The [redacted] form; never contains secrets.
  @override
  String toString() => 'PgConnectionConfig(${redacted()})';
}
