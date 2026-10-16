// File: resolve_defaults_test.dart
// Purpose: Tests for libpq-style default resolution: PG* environment
// variables (injected), user fallback, and dbname = user.

import 'package:dbase_postgresql/connection_string.dart';
import 'package:test/test.dart';

void main() {
  test('database stays null when absent; effectiveDatabase is the user', () {
    final c = PgConnectionConfig.parse('postgres://alice@h');
    expect(c.database, isNull);
    expect(c.effectiveDatabase, 'alice');
    expect(PgConnectionConfig.parse('postgres://h').effectiveDatabase, isNull);
  });

  test('never invents "postgres" as the database', () {
    final c = PgConnectionConfig.parse('postgres://h').resolveDefaults();
    expect(c.database, isNull);
    expect(c.user, isNull);
  });

  test('environment fills only missing keywords', () {
    final c = PgConnectionConfig.parse('postgres://bob@h/db').resolveDefaults(
      environment: const {
        'PGHOST': 'other',
        'PGPORT': '6000',
        'PGUSER': 'eve',
        'PGPASSWORD': 'envpw',
        'PGSSLMODE': 'verify-full',
        'PGAPPNAME': 'dbase',
        'HOME': '/ignored',
      },
    );
    expect(c.hosts, const [PgHost('h', port: 6000)]);
    expect(c.user, 'bob');
    expect(c.password, 'envpw');
    expect(c.database, 'db');
    expect(c.sslMode, SslMode.verifyFull);
    expect(c.sslModeWasExplicit, isTrue);
    expect(c.applicationName, 'dbase');
    expect(c.parameters.containsKey('HOME'), isFalse);
  });

  test('a password from the environment is not "embedded"', () {
    final c = PgConnectionConfig.parse('postgres://h/db?sslmode=verify-full')
        .resolveDefaults(environment: const {'PGPASSWORD': 'x'});
    expect(c.securityWarnings, isEmpty);
  });

  test('an embedded password stays flagged after resolution', () {
    final c = PgConnectionConfig.parse(
      'postgres://u:pw@h/db?sslmode=verify-full',
    ).resolveDefaults();
    expect(
      c.securityWarnings.single.code,
      PgSecurityWarningCode.passwordInConnectionString,
    );
  });

  test('user falls back to defaultUser, then dbname to the user', () {
    final c = PgConnectionConfig.parse('postgres://h')
        .resolveDefaults(defaultUser: 'osuser');
    expect(c.user, 'osuser');
    expect(c.database, 'osuser');
  });

  test('PGUSER beats defaultUser; PGDATABASE beats the user fallback', () {
    final c = PgConnectionConfig.parse('postgres://h').resolveDefaults(
      environment: const {'PGUSER': 'envuser'},
      defaultUser: 'osuser',
    );
    expect(c.user, 'envuser');
    expect(c.database, 'envuser');
    final d = PgConnectionConfig.parse('postgres://h').resolveDefaults(
      environment: const {'PGUSER': 'u', 'PGDATABASE': 'appdb'},
    );
    expect(d.database, 'appdb');
  });

  test('empty environment values are ignored', () {
    final c = PgConnectionConfig.parse('postgres://h')
        .resolveDefaults(environment: const {'PGUSER': ''});
    expect(c.user, isNull);
  });

  test('PGHOST with a socket path and multiple hosts', () {
    final c = PgConnectionConfig.parse('dbname=d').resolveDefaults(
      environment: const {'PGHOST': '/run/pg,db2', 'PGPORT': '5433,5434'},
    );
    expect(c.hosts, const [
      PgHost('/run/pg', port: 5433),
      PgHost('db2', port: 5434),
    ]);
    expect(c.hosts.first.isUnixSocket, isTrue);
  });

  test('invalid environment values throw without echoing them', () {
    expect(
      () =>
          PgConnectionConfig.parse('postgres://h')
              .resolveDefaults(environment: const {'PGPORT': 'hunter2'}),
      throwsA(
        isA<PgConfigParseException>().having(
          (e) => e.toString(),
          'toString',
          isNot(contains('hunter2')),
        ),
      ),
    );
  });
}
