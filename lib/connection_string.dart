// File: connection_string.dart
// Purpose: Narrow entrypoint for PostgreSQL connection string parsing,
// formatting, default resolution, and security warnings.

/// Parse and format libpq connection strings (`postgres://` URIs and
/// `key=value` conninfo) with libpq-compatible semantics and secret-safe
/// errors.
library;

export 'src/config/pg_config_parse_exception.dart' show PgConfigParseException;
export 'src/config/pg_connection_config.dart' show PgConnectionConfig;
export 'src/config/pg_host.dart' show PgHost;
export 'src/config/pg_security_warning.dart'
    show PgSecurityWarning, PgSecurityWarningCode;
export 'src/config/ssl_mode.dart' show SslMode;
