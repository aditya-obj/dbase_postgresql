// File: pg_server.dart
// Purpose: Connection helper for the integration tests. Reads the server
// URL from DABASE_PG_URL, parses it with our own PgConnectionConfig, and
// opens a connection with the `postgres` driver (a dev dependency only).
//
// Tests that use this skip with [skipReason] when DABASE_PG_URL is unset,
// so a plain `dart test -P integration` without a server reports skips
// instead of failures. See test/docker/README.md for running servers.

import 'dart:io';

import 'package:dabase_postgresql/connection_string.dart';
import 'package:postgres/postgres.dart' as pg;

/// The environment variable holding the test server's connection string.
const urlVariable = 'DABASE_PG_URL';

/// The connection string under test, or `null` when unset or blank.
final String? testServerUrl = switch (Platform.environment[urlVariable]) {
  final url? when url.trim().isNotEmpty => url.trim(),
  _ => null,
};

/// The reason integration tests are skipped, or `false` to run them.
Object get skipReason => testServerUrl == null
    ? '$urlVariable is not set. Start a server (see test/docker/README.md) '
          'and export e.g. '
          '$urlVariable=postgresql://dabase:dabase@localhost:54318/dabase'
          '?sslmode=disable'
    : false;

/// Opens a connection to [testServerUrl].
///
/// The URL goes through [PgConnectionConfig.parse] and
/// [PgConnectionConfig.resolveDefaults] (with the process environment, so
/// `PGPASSWORD` works), which also exercises the parser.
///
/// sslmode mapping (test harness only): `disable`, `allow` and `prefer`
/// (also the default when unset) connect without TLS; `require` uses TLS
/// without certificate verification; `verify-ca` and `verify-full` verify
/// the certificate.
Future<pg.Connection> openTestConnection() async {
  final url = testServerUrl;
  if (url == null) throw StateError('$urlVariable is not set');
  final config = PgConnectionConfig.parse(url).resolveDefaults(
    environment: Platform.environment,
    defaultUser: Platform.environment['USER'],
  );
  final database = config.effectiveDatabase;
  if (database == null || config.user == null) {
    throw StateError('$urlVariable must name a user (and/or a database).');
  }
  final host = config.hosts.isEmpty ? null : config.hosts.first;
  return await pg.Connection.open(
    pg.Endpoint(
      host: host?.host ?? 'localhost',
      port: host?.effectivePort ?? PgHost.defaultPort,
      database: database,
      username: config.user,
      password: config.password,
      isUnixSocket: host?.isUnixSocket ?? false,
    ),
    settings: pg.ConnectionSettings(
      applicationName: 'dabase_postgresql integration tests',
      sslMode: switch (config.sslMode) {
        SslMode.disable ||
        SslMode.allow ||
        SslMode.prefer => pg.SslMode.disable,
        SslMode.require => pg.SslMode.require,
        SslMode.verifyCa || SslMode.verifyFull => pg.SslMode.verifyFull,
      },
      connectTimeout: const Duration(seconds: 15),
      queryTimeout: const Duration(seconds: 60),
    ),
  );
}

/// The server's `server_version_num`, e.g. 180001.
Future<int> serverVersionNum(pg.Connection connection) async {
  final result = await connection.execute('SHOW server_version_num');
  return int.parse(result.single.single! as String);
}

/// The SQLSTATE of [error] when it is a server error, else `null`.
String? sqlState(Object error) =>
    error is pg.ServerException ? error.code : null;
