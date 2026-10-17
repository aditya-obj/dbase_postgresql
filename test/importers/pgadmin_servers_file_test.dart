// File: pgadmin_servers_file_test.dart
// Purpose: Unit tests for PgAdminServersFile: both servers.json layouts,
// pgAdmin's validation rules, the mapping table and warnings.

import 'dart:io';

import 'package:dbase_postgresql/connection_string.dart';
import 'package:dbase_postgresql/importers.dart';
import 'package:test/test.dart';

PgAdminServersFile _fixture(String name) => PgAdminServersFile.parse(
  File('test/importers/fixtures/$name').readAsStringSync(),
);

/// One server entry, merged over a minimal valid one.
String _entry(String fields) =>
    '{"Servers": {"1": {"Name": "n", "Group": "g", "Host": "h", '
    '"Port": 5432, "MaintenanceDB": "postgres", "Username": "u"'
    '${fields.isEmpty ? '' : ', $fields'}}}}';

PgAdminServer _server(String fields) =>
    PgAdminServersFile.parse(_entry(fields)).servers.single;

PgAdminServerError _error(String json) {
  final file = PgAdminServersFile.parse(json);
  expect(file.servers, isEmpty);
  return file.errors.single;
}

List<(PgAdminWarningCode, String?)> _warnings(PgAdminServer server) => [
  for (final w in server.warnings) (w.code, w.field),
];

void main() {
  group('ConnectionParameters layout (pgAdmin 6.20+)', () {
    final file = _fixture('servers_connection_parameters.json');

    test('imports every server', () {
      expect(file.errors, isEmpty);
      expect(file.servers.map((s) => s.id), ['1', '2', '3']);
      expect(file.toString(), 'PgAdminServersFile(3 servers, 0 errors)');
    });

    test('maps the basic fields', () {
      final s = file.servers[0];
      expect(s.name, 'Production');
      expect(s.group, 'Work');
      expect(s.usesLegacyLayout, isFalse);
      expect(s.config.hosts.single, const PgHost('db.example.com', port: 5432));
      expect(s.config.database, 'postgres');
      expect(s.config.user, 'alice');
      expect(s.config.password, isNull);
      expect(s.config.sslMode, SslMode.verifyFull);
      expect(s.config.connectTimeout, const Duration(seconds: 10));
      expect(s.config.applicationName, 'pgAdmin');
      expect(s.role, 'app_owner');
      expect(s.comment, 'Primary cluster');
      expect(s.databaseRestriction, 'shop analytics');
      expect(s.databaseRestrictionType, 'databases');
      expect(s.backgroundColor, '#FF0000');
      expect(s.foregroundColor, '#FFFFFF');
      expect(s.tags, const [
        PgAdminTag('prod', color: '#E74C3C'),
        PgAdminTag('eu'),
      ]);
      expect(s.postConnectionSql, 'SET search_path = shop, public;');
      expect(s.sshTunnel, isNull);
      expect(s.shared, isFalse);
      expect(s.service, isNull);
    });

    test('warns about file paths and post-connection SQL', () {
      expect(_warnings(file.servers[0]), [
        (PgAdminWarningCode.filePath, 'sslrootcert'),
        (PgAdminWarningCode.filePath, 'sslcert'),
        (PgAdminWarningCode.filePath, 'sslkey'),
        (PgAdminWarningCode.postConnectionSql, 'PostConnectionSQL'),
      ]);
    });

    test('maps the SSH tunnel', () {
      final s = file.servers[1];
      final tunnel = s.sshTunnel!;
      expect(tunnel.host, 'bastion.example.com');
      expect(tunnel.port, 2222);
      expect(tunnel.username, 'ec2-user');
      expect(tunnel.authentication, PgAdminTunnelAuthentication.identityFile);
      expect(tunnel.identityFile, '/Users/bob/.ssh/id_ed25519');
      expect(tunnel.promptPassword, isFalse);
      expect(tunnel.keepAlive, const Duration(seconds: 30));
      expect(
        tunnel.toString(),
        'PgAdminSshTunnel(ec2-user@bastion.example.com:2222, identityFile)',
      );
      // sslrootcert=system is not a path.
      expect(_warnings(s), [
        (PgAdminWarningCode.filePath, 'passfile'),
        (PgAdminWarningCode.hostAddress, 'hostaddr'),
        (PgAdminWarningCode.filePath, 'TunnelIdentityFile'),
      ]);
      expect(
        s.config.securityWarnings.map((w) => w.code),
        contains(PgSecurityWarningCode.sslMayFallBackToPlaintext),
      );
    });

    test('service, shared, Kerberos and password commands', () {
      final s = file.servers[2];
      expect(s.service, 'reporting');
      expect(s.shared, isTrue);
      expect(s.config.user, 'reporter');
      expect(s.config.hosts, isEmpty);
      expect(_warnings(s), [
        (PgAdminWarningCode.directSslNegotiation, 'sslnegotiation'),
        (PgAdminWarningCode.kerberos, 'gssencmode'),
        (PgAdminWarningCode.kerberos, 'krbsrvname'),
        (PgAdminWarningCode.service, 'Service'),
        (PgAdminWarningCode.kerberos, 'KerberosAuthentication'),
        (PgAdminWarningCode.passwordExecCommand, 'PasswordExecCommand'),
      ]);
      // The command text is not kept anywhere.
      expect(s.toString(), isNot(contains('vault')));
      for (final w in s.warnings) {
        expect(w.toString(), isNot(contains('vault')));
      }
    });
  });

  group('legacy flat layout', () {
    final file = _fixture('servers_legacy.json');

    test('flat keys become libpq parameters', () {
      final s = file.servers[0];
      expect(file.errors, isEmpty);
      expect(s.usesLegacyLayout, isTrue);
      expect(s.config.sslMode, SslMode.require);
      expect(s.config.parameters, {
        'hostaddr': '192.0.2.10',
        'passfile': '/home/me/.pgpass',
        'sslcert': '<STORAGE_DIR>/.postgresql/postgresql.crt',
        'sslkey': '<STORAGE_DIR>/.postgresql/postgresql.key',
        'sslrootcert': '/etc/ssl/certs/ca.pem',
        'sslcrl': '',
        'connect_timeout': '15',
        'sslcompression': '0',
      });
      expect(s.backgroundColor, isNull);
      expect(s.sshTunnel, isNull, reason: 'UseSSHTunnel is 0');
      expect(_warnings(s), [
        (PgAdminWarningCode.filePath, 'passfile'),
        (PgAdminWarningCode.filePath, 'sslcert'),
        (PgAdminWarningCode.filePath, 'sslkey'),
        (PgAdminWarningCode.filePath, 'sslrootcert'),
        (PgAdminWarningCode.hostAddress, 'hostaddr'),
      ]);
    });

    test('tunnel defaults: port 22, password authentication', () {
      final tunnel = file.servers[1].sshTunnel!;
      expect(tunnel.port, 22);
      expect(tunnel.authentication, PgAdminTunnelAuthentication.password);
      expect(tunnel.identityFile, isNull);
      expect(tunnel.keepAlive, isNull);
    });

    test('flat keys are ignored when ConnectionParameters is present', () {
      final s = _server(
        '"SSLMode": "disable", "Timeout": 3, "ConnectionParameters": '
        '{"sslmode": "verify-ca"}',
      );
      expect(s.usesLegacyLayout, isFalse);
      expect(s.config.sslMode, SslMode.verifyCa);
      expect(s.config.parameters, isEmpty);
    });

    test('ConnectionParameters: null means no parameters', () {
      final s = _server('"SSLMode": "disable", "ConnectionParameters": null');
      expect(s.usesLegacyLayout, isFalse);
      expect(s.config.sslModeWasExplicit, isFalse);
    });
  });

  group("pgAdmin's validation", () {
    test('Name, Group and MaintenanceDB are required', () {
      for (final field in ['Name', 'Group', 'MaintenanceDB']) {
        final json = _entry('')
            .replaceFirst(RegExp('"$field": "[^"]*", ?'), '');
        final error = _error(json);
        expect(error.code, PgAdminErrorCode.missingField, reason: field);
        expect(error.field, field);
        expect(error.serverId, '1');
      }
    });

    test('without Service: Port must be an integer', () {
      for (final port in ['"5432"', '5432.0', 'null', 'true']) {
        final json = _entry('').replaceFirst('"Port": 5432', '"Port": $port');
        final error = _error(json);
        expect(error.code, PgAdminErrorCode.invalidFieldType, reason: port);
        expect(error.field, 'Port');
      }
      final missing = _error(_entry('').replaceFirst('"Port": 5432, ', ''));
      expect(missing.code, PgAdminErrorCode.missingField);
    });

    test('without Service: Username is required and non-empty', () {
      final missing = _entry('').replaceFirst(', "Username": "u"', '');
      expect(_error(missing).field, 'Username');
      final empty = _entry('')
          .replaceFirst('"Username": "u"', '"Username": ""');
      expect(_error(empty).code, PgAdminErrorCode.missingField);
    });

    test('shared servers may use SharedUsername instead', () {
      final base = _entry('"Shared": true')
          .replaceFirst(', "Username": "u"', '');
      expect(_error(base).field, 'Username or SharedUsername');
      final ok = PgAdminServersFile.parse(
        base.replaceFirst(
          '"Shared": true',
          '"Shared": 1, "SharedUsername": "s"',
        ),
      ).servers.single;
      expect(ok.config.user, 's');
      expect(ok.shared, isTrue);
    });

    test('without Service: Host is required', () {
      final json = _entry('').replaceFirst('"Host": "h", ', '');
      expect(_error(json).field, 'Host or Service');
    });

    test('with Service, Host, Port and Username are optional', () {
      final file = PgAdminServersFile.parse(
        '{"Servers": {"1": {"Name": "n", "Group": "g", "Service": "s", '
        '"MaintenanceDB": "d", "Port": "x"}}}',
      );
      final s = file.servers.single;
      expect(s.config.hosts, isEmpty);
      expect(s.config.user, isNull);
      expect(_warnings(s), [
        (PgAdminWarningCode.invalidField, 'Port'),
        (PgAdminWarningCode.service, 'Service'),
      ]);
    });

    test('required fields must be strings', () {
      final json = _entry('').replaceFirst('"Name": "n"', '"Name": 5');
      expect(_error(json).code, PgAdminErrorCode.invalidFieldType);
    });

    test('invalid values reject the server', () {
      final port = _entry('').replaceFirst('"Port": 5432', '"Port": 70000');
      expect(_error(port).code, PgAdminErrorCode.invalidValue);
      final ssl = _error(_entry('"ConnectionParameters": {"sslmode": "x"}'));
      expect(ssl.code, PgAdminErrorCode.invalidValue);
      expect(ssl.toString(), startsWith('PgAdminServerError(1, invalidValue'));
    });

    test('an entry that is not an object is rejected', () {
      final error = _error('{"Servers": {"7": [1, 2]}}');
      expect(error.code, PgAdminErrorCode.notAnObject);
      expect(error.serverId, '7');
    });

    test('valid entries are imported next to invalid ones', () {
      final file = PgAdminServersFile.parse(
        '{"Servers": {"1": {"Name": "bad"}, '
        '"2": ${_entry('').substring(17, _entry('').length - 2)}}}',
      );
      expect(file.servers.single.id, '2');
      expect(file.errors.single.serverId, '1');
    });
  });

  group('optional fields and parameters', () {
    test('wrong types are ignored with invalidField warnings', () {
      final s = _server(
        '"Comment": 5, "Tags": "x", "UseSSHTunnel": "yes", "Role": [], '
        '"ConnectionParameters": 3',
      );
      expect(s.comment, isNull);
      expect(s.tags, isEmpty);
      expect(s.sshTunnel, isNull);
      expect(s.warnings.map((w) => w.field).toSet(), {
        'Comment',
        'Tags',
        'UseSSHTunnel',
        'Role',
        'ConnectionParameters',
      });
      expect(
        s.warnings.every((w) => w.code == PgAdminWarningCode.invalidField),
        isTrue,
      );
    });

    test('invalid tags are skipped', () {
      final s = _server(
        '"Tags": [{"text": "a", "color": 1}, {"color": "c"}, 3]',
      );
      expect(s.tags, const [PgAdminTag('a')]);
      expect(_warnings(s), [(PgAdminWarningCode.invalidField, 'Tags')]);
    });

    test('tunnel fields: string ports, booleans and unknown values', () {
      final tunnel = _server(
        '"UseSSHTunnel": true, "TunnelPort": "2200", '
        '"TunnelAuthentication": true, "TunnelPromptPassword": 1, '
        '"TunnelKeepAlive": 0',
      ).sshTunnel!;
      expect(tunnel.port, 2200);
      expect(tunnel.authentication, PgAdminTunnelAuthentication.identityFile);
      expect(tunnel.promptPassword, isTrue);
      expect(tunnel.keepAlive, isNull);

      final odd = _server(
        '"UseSSHTunnel": 1, "TunnelPort": 0, "TunnelAuthentication": 2, '
        '"TunnelKeepAlive": "x"',
      );
      expect(odd.sshTunnel!.port, 22);
      expect(
        odd.sshTunnel!.authentication,
        PgAdminTunnelAuthentication.password,
      );
      expect(_warnings(odd), [
        (PgAdminWarningCode.invalidField, 'TunnelAuthentication'),
        (PgAdminWarningCode.invalidField, 'TunnelKeepAlive'),
      ]);
    });

    test('parameter values: numbers become strings, others are skipped', () {
      final s = _server(
        '"ConnectionParameters": {"connect_timeout": 10.0, '
        '"keepalives_idle": 1.5, "keepalives": true, "bad key": "x", '
        '"hunter2": [], "options": null, "target_session_attrs": "any"}',
      );
      expect(s.config.parameters, {
        'connect_timeout': '10',
        'keepalives_idle': '1.5',
        'target_session_attrs': 'any',
      });
      expect(_warnings(s), [
        (PgAdminWarningCode.ignoredParameter, 'keepalives'),
        (PgAdminWarningCode.ignoredParameter, null),
        (PgAdminWarningCode.ignoredParameter, null),
      ]);
      for (final w in s.warnings) {
        expect(w.message, isNot(contains('hunter2')));
        expect(w.message, isNot(contains('bad key')));
      }
    });

    test('top-level fields win over ConnectionParameters', () {
      final s = _server('"ConnectionParameters": {"host": "other", "port": 1}');
      expect(s.config.hosts.single, const PgHost('h', port: 5432));
    });

    test('secrets in parameters are flagged and never printed', () {
      final s = _server(
        '"ConnectionParameters": {"password": "hunter2", '
        '"sslpassword": "hunter3", "gsslib": "gssapi", "gssdelegation": 1, '
        '"service": "x", "gssencmode": "prefer"}',
      );
      expect(s.config.password, 'hunter2');
      expect(_warnings(s), [
        (PgAdminWarningCode.kerberos, 'gsslib'),
        (PgAdminWarningCode.kerberos, 'gssdelegation'),
        (PgAdminWarningCode.secretInFile, 'password'),
        (PgAdminWarningCode.secretInFile, 'sslpassword'),
        (PgAdminWarningCode.service, 'service'),
      ]);
      expect(s.toString(), isNot(contains('hunter')));
      expect(s.toString(), startsWith('PgAdminServer(1, n, postgresql://'));
    });

    test('empty PostConnectionSQL and PasswordExecCommand are ignored', () {
      final s = _server(
        '"PostConnectionSQL": "  ", "PasswordExecCommand": "", '
        '"KerberosAuthentication": 0',
      );
      expect(s.postConnectionSql, isNull);
      expect(s.warnings, isEmpty);
    });
  });

  group('file errors', () {
    void expectThrows(String json, String message) {
      expect(
        () => PgAdminServersFile.parse(json),
        throwsA(
          isA<PgImportException>().having((e) => e.message, 'message', message),
        ),
      );
      expect(PgAdminServersFile.tryParse(json), isNull);
    }

    test('invalid JSON reports an offset, never the text', () {
      try {
        PgAdminServersFile.parse('{"Servers": {"password": hunter2}}');
        fail('expected PgImportException');
      } on PgImportException catch (e) {
        expect(e.message, 'The file is not valid JSON.');
        expect(e.offset, isNotNull);
        expect(e.toString(), isNot(contains('hunter2')));
        expect(e.toString(), startsWith('PgImportException at offset'));
      }
    });

    test('the root must be an object with a Servers object', () {
      expectThrows('[]', 'Expected a JSON object with a "Servers" attribute.');
      expectThrows('{}', '"Servers" attribute not found.');
      expectThrows('{"Servers": []}', '"Servers" is not a JSON object.');
      expectThrows('{"Servers": null}', '"Servers" is not a JSON object.');
    });

    test(
      'a byte order mark is ignored and offsets still point at the text',
      () {
        expect(
          PgAdminServersFile.parse('﻿${_entry('')}').servers,
          hasLength(1),
        );
        try {
          PgAdminServersFile.parse('﻿{x');
          fail('expected PgImportException');
        } on PgImportException catch (e) {
          expect(e.offset, 2);
        }
      },
    );

    test('an empty Servers object imports nothing', () {
      final file = PgAdminServersFile.parse('{"Servers": {}}');
      expect(file.servers, isEmpty);
      expect(file.errors, isEmpty);
    });
  });

  test('value classes', () {
    const a = PgAdminWarning(PgAdminWarningCode.filePath, 'sslcert', 'm');
    const b = PgAdminWarning(PgAdminWarningCode.filePath, 'sslcert', 'm');
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.toString(), 'PgAdminWarning(filePath, sslcert: m)');
    expect(
      const PgAdminTag('t', color: 'c').hashCode,
      const PgAdminTag('t', color: 'c').hashCode,
    );
    expect(const PgAdminTag('t').toString(), 'PgAdminTag(t, null)');
    expect(const PgImportException('m').toString(), 'PgImportException: m');
  });
}
