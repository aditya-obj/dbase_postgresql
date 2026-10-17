// File: pg_service_file_test.dart
// Purpose: Unit tests for PgServiceFile: libpq's parseServiceFile() rules,
// per-section diagnostics, user/system precedence and applyTo.

import 'package:dbase_postgresql/connection_string.dart';
import 'package:dbase_postgresql/importers.dart';
import 'package:test/test.dart';

PgServiceFile _parse(String text) => PgServiceFile.parse(text);

PgService _single(String text) => _parse(text).services.single;

List<PgServiceDiagnosticCode> _codes(PgService service) => [
  for (final d in service.diagnostics) d.code,
];

List<PgServiceDiagnosticCode> _fileCodes(String text) => [
  for (final d in _parse(text).diagnostics) d.code,
];

void main() {
  group('sections', () {
    test('a section becomes a connection config', () {
      final service = _single(
        '[prod]\n'
        'host=db1,db2\n'
        'port=5432,5433\n'
        'dbname=shop\n'
        'user=alice\n'
        'sslmode=verify-full\n'
        'application_name=dbase\n',
      );
      expect(service.name, 'prod');
      expect(service.line, 1);
      expect(service.isValid, isTrue);
      expect(service.diagnostics, isEmpty);
      final config = service.config!;
      expect(config.hosts, const [
        PgHost('db1', port: 5432),
        PgHost('db2', port: 5433),
      ]);
      expect(config.database, 'shop');
      expect(config.user, 'alice');
      expect(config.sslMode, SslMode.verifyFull);
      expect(config.parameters, {'application_name': 'dbase'});
    });

    test('names are case-sensitive and text after ] is ignored', () {
      final file = _parse('[Prod]x y\nhost=a\n[prod]\nhost=b\n');
      expect(file.services.map((s) => s.name), ['Prod', 'prod']);
      expect(file.lookup('Prod')!.config!.host, 'a');
      expect(file.lookup('prod')!.config!.host, 'b');
      expect(file.lookup('PROD'), isNull);
    });

    test('whitespace inside brackets is part of the name', () {
      expect(_single('[ a ]\nhost=h\n').name, ' a ');
    });

    test('only the first section with a name counts', () {
      final file = _parse('[a]\nhost=first\n[a]\nhost=second\nbogus\n');
      expect(file.services.single.config!.host, 'first');
      expect(_fileCodes('[a]\nhost=first\n[a]\nhost=second\nbogus\n'), [
        PgServiceDiagnosticCode.duplicateService,
      ]);
    });

    test('settings outside a section are ignored', () {
      final file = _parse('host=x\n[a]\nport=1\n');
      expect(file.services.single.settings, {'port': '1'});
      expect(
        file.diagnostics.single.code,
        PgServiceDiagnosticCode.outsideSection,
      );
      expect(file.diagnostics.single.severity, PgImportSeverity.info);
    });

    test('a header without ] ends the section and its lines are ignored', () {
      final file = _parse('[a]\nhost=h\n[b\nport=1\n[c]\nport=2\n');
      expect(file.services.map((s) => s.name), ['a', 'c']);
      expect(file.lookup('a')!.settings, {'host': 'h'});
      expect(
        file.diagnostics.single.code,
        PgServiceDiagnosticCode.malformedSectionHeader,
      );
    });

    test('[] is ignored', () {
      final file = _parse('[]\nhost=h\n');
      expect(file.services, isEmpty);
      expect(
        file.diagnostics.single.code,
        PgServiceDiagnosticCode.emptyServiceName,
      );
    });
  });

  group('lines', () {
    test('comments only as the first non-blank character', () {
      final service = _single(
        '# top\n[a]\n   # indented comment\n\t#tab\nhost=a # not a comment\n',
      );
      expect(service.settings, {'host': 'a # not a comment'});
      expect(service.diagnostics, isEmpty);
    });

    test('leading and trailing whitespace of a line is trimmed', () {
      final service = _single('  [a]  \n\t host=h \t\r\n');
      expect(service.settings, {'host': 'h'});
    });

    test('values are taken literally: no quotes or escapes', () {
      final service = _single('[a]\n${r"password='it\'s'"}\n');
      expect(service.settings['password'], r"'it\'s'");
    });

    test('the value is split at the first =', () {
      expect(_single('[a]\noptions=-c a=b\n').settings, {'options': '-c a=b'});
    });

    test('CRLF line endings', () {
      final service = _single('[a]\r\nhost=h\r\nport=5433\r\n');
      expect(service.config!.hosts.single, const PgHost('h', port: 5433));
    });

    test('a byte order mark is ignored with a warning', () {
      final file = _parse('\uFEFF[a]\nhost=h\n');
      expect(file.services.single.name, 'a');
      expect(
        file.diagnostics.single.code,
        PgServiceDiagnosticCode.byteOrderMark,
      );
    });

    test('an empty value is set (and means the default)', () {
      final service = _single('[a]\nhost=\nport=\n');
      expect(service.settings, {'host': '', 'port': ''});
      expect(service.config!.hosts, const [PgHost('')]);
    });
  });

  group('errors that break a service', () {
    void expectError(String body, PgServiceDiagnosticCode code) {
      final service = _single('[a]\nhost=h\n$body\n');
      expect(service.isValid, isFalse, reason: body);
      expect(service.config, isNull);
      final error = service.diagnostics.single;
      expect(error.code, code, reason: body);
      expect(error.severity, PgImportSeverity.error);
      expect(error.line, 3);
    }

    test('whitespace before = is a syntax error', () {
      expectError('port = 5432', PgServiceDiagnosticCode.spaceAroundEquals);
      expectError('port =5432', PgServiceDiagnosticCode.spaceAroundEquals);
      expectError('port\t=5432', PgServiceDiagnosticCode.spaceAroundEquals);
    });

    test('unknown keywords are errors (ssl= is URI-only)', () {
      expectError('uzer=alice', PgServiceDiagnosticCode.unknownKeyword);
      expectError('ssl=true', PgServiceDiagnosticCode.unknownKeyword);
      expectError('Host=h', PgServiceDiagnosticCode.unknownKeyword);
      expectError('=x', PgServiceDiagnosticCode.unknownKeyword);
    });

    test('nested services are errors', () {
      expectError('service=other', PgServiceDiagnosticCode.nestedService);
      expectError('servicefile=/x', PgServiceDiagnosticCode.nestedService);
    });

    test('a line without = is an error', () {
      expectError('just text', PgServiceDiagnosticCode.missingEquals);
    });

    test('NUL in a section is an error', () {
      expectError('port=1\u00002', PgServiceDiagnosticCode.nulCharacter);
    });

    test('invalid values are errors on their own line', () {
      expectError('port=99999', PgServiceDiagnosticCode.invalidValue);
      expectError('sslmode=bogus', PgServiceDiagnosticCode.invalidValue);
      expectError('connect_timeout=ten', PgServiceDiagnosticCode.invalidValue);
      final service = _single('[a]\nhost=a,b,c\nport=1,2\n');
      expect(service.diagnostics.single.line, 3);
    });

    test('error messages never repeat the line', () {
      final service = _single(
        '[a]\nhunter2secret\nhunter2secret=x\npassword =hunter2secret\n'
        'port=hunter2secret\n',
      );
      expect(service.diagnostics, hasLength(3));
      for (final d in service.diagnostics) {
        expect(d.message, isNot(contains('hunter2')));
      }
    });

    test('errors in one section do not affect another', () {
      final file = _parse('[bad]\nbogus\n[good]\nhost=h\n');
      expect(file.lookup('bad')!.isValid, isFalse);
      expect(file.lookup('good')!.isValid, isTrue);
    });
  });

  group('warnings and info that keep a service valid', () {
    test('a value starting with whitespace is kept, with a warning', () {
      final service = _single('[a]\nhost= h\n');
      expect(service.isValid, isTrue);
      expect(service.settings['host'], ' h');
      expect(_codes(service), [
        PgServiceDiagnosticCode.valueHasLeadingWhitespace,
      ]);
    });

    test('the first value of a repeated keyword wins', () {
      final service = _single('[a]\nhost=first\nhost=second\n');
      expect(service.config!.host, 'first');
      expect(_codes(service), [PgServiceDiagnosticCode.duplicateKeyword]);
      expect(service.diagnostics.single.line, 3);
    });

    test('ldap lines are skipped with a warning', () {
      final service = _single(
        '[a]\nldap://ldap.example.com/dc=example?uniqueMember?one\nhost=h\n',
      );
      expect(service.isValid, isTrue);
      expect(service.settings, {'host': 'h'});
      expect(_codes(service), [PgServiceDiagnosticCode.ldapNotSupported]);
    });
  });

  group('line length (fgets into a 1024-byte buffer)', () {
    String section(String line, {bool newline = true}) =>
        '[a]\n$line${newline ? '\n' : ''}';

    test('1022 bytes including the newline are allowed', () {
      final value = 'x' * (1021 - 'options='.length);
      final service = _single(section('options=$value'));
      expect(service.isValid, isTrue);
    });

    test('1023 bytes including the newline are an error', () {
      final value = 'x' * (1022 - 'options='.length);
      final file = _parse(section('options=$value'));
      expect(file.services.single.isValid, isFalse);
      expect(file.lineTooLong?.line, 2);
      expect(file.lineTooLong?.message, contains('1023 bytes'));
    });

    test('the last line without a newline may be 1022 bytes', () {
      final value = 'x' * (1022 - 'options='.length);
      expect(
        _single(section('options=$value', newline: false)).isValid,
        isTrue,
      );
      final longer = 'x' * (1023 - 'options='.length);
      expect(
        _single(section('options=$longer', newline: false)).isValid,
        isFalse,
      );
    });

    test('bytes are counted in UTF-8', () {
      // '\u00E9' is two bytes; 'options=' is 8.
      final value = '\u00E9' * 507; // 8 + 1014 + newline = 1023 bytes
      expect(_single(section('options=$value')).isValid, isFalse);
      final shorter = '\u00E9' * 506;
      expect(_single(section('options=$shorter')).isValid, isTrue);
      // The euro sign is three bytes: 8 + 1014 + newline = 1023.
      expect(_single(section('options=${'\u20AC' * 338}')).isValid, isFalse);
      expect(_single(section('options=${'\u20AC' * 337}')).isValid, isTrue);
      final emoji = '\u{1F600}' * 253; // 8 + 1012 + 1 = 1021 bytes
      expect(_single(section('options=$emoji')).isValid, isTrue);
    });

    test('a long line breaks its section and every later one', () {
      final long = '#${'x' * 2000}';
      final file = _parse(
        '[before]\nhost=h\n[during]\n$long\n[after]\nhost=h\n',
      );
      expect(file.lookup('before')!.isValid, isTrue);
      expect(file.lookup('during')!.isValid, isFalse);
      expect(file.lookup('after')!.isValid, isFalse);
      expect(file.lookup('after')!.diagnostics.single.line, 4);
    });

    test('a long header line also breaks the section it ends', () {
      final file = _parse('[a]\nhost=h\n[b]${'x' * 2000}\nhost=h\n');
      expect(file.lookup('a')!.isValid, isFalse);
      expect(file.lookup('b')!.isValid, isFalse);
    });
  });

  group('secrets', () {
    test('secretKeywords and safe toString', () {
      final service = _single('[a]\npassword=hunter2\nsslpassword=k\nhost=h\n');
      expect(service.secretKeywords, {'password', 'sslpassword'});
      expect(service.config!.password, 'hunter2');
      expect(service.toString(), isNot(contains('hunter2')));
      expect(service.toString(), contains('password'));
      expect(service.config.toString(), isNot(contains('hunter2')));
      expect(
        service.config!.securityWarnings.map((w) => w.code),
        isNot(contains(PgSecurityWarningCode.passwordInConnectionString)),
      );
    });

    test('file toString', () {
      expect(
        _parse('[a]\nhost=h\nbad\n').toString(),
        'PgServiceFile(1 services, 1 diagnostics)',
      );
    });
  });

  group('merge (user file before system file)', () {
    test('the user file wins per name, even when its section is broken', () {
      final user = _parse('[a]\nbogus\n[u]\nhost=user\n');
      final system = _parse('[a]\nhost=system\n[s]\nhost=system\n');
      final merged = PgServiceFile.merge(user: user, system: system);
      expect(merged.map((s) => s.name), ['a', 'u', 's']);
      expect(merged.first.isValid, isFalse);
      expect(merged.last.config!.host, 'system');
    });

    test('a long line in the user file blocks the system file', () {
      final user = _parse('[u]\nhost=h\n#${'x' * 1100}\n');
      final system = _parse('[s]\nhost=h\n');
      final merged = PgServiceFile.merge(user: user, system: system);
      expect(merged.map((s) => s.isValid), [false, false]);
      expect(
        merged.last.diagnostics.first.code,
        PgServiceDiagnosticCode.lineTooLong,
      );
      expect(merged.last.settings, {'host': 'h'});
    });
  });

  group('applyTo (connection string wins over the service)', () {
    final service = _single(
      '[a]\nhost=svc-host\nport=6000\ndbname=svc-db\nuser=svc-user\n'
      'password=svc-pw\nsslmode=verify-full\napplication_name=svc\n',
    );

    test('keywords already set win; the service fills the rest', () {
      final merged = service.applyTo(
        PgConnectionConfig.parse('dbname=mine application_name=me'),
      );
      expect(merged.hosts.single, const PgHost('svc-host', port: 6000));
      expect(merged.database, 'mine');
      expect(merged.user, 'svc-user');
      expect(merged.password, 'svc-pw');
      expect(merged.sslMode, SslMode.verifyFull);
      expect(merged.sslModeWasExplicit, isTrue);
      expect(merged.applicationName, 'me');
    });

    test('a port without a host takes the service host', () {
      final merged = service.applyTo(PgConnectionConfig.parse('port=7000'));
      expect(merged.hosts.single, const PgHost('svc-host', port: 7000));
    });

    test('an explicit sslmode and embedded password are kept', () {
      final merged = service.applyTo(
        PgConnectionConfig.parse('postgres://me:pw@h/d?sslmode=require'),
      );
      expect(merged.password, 'pw');
      expect(merged.sslMode, SslMode.require);
      expect(
        merged.securityWarnings.map((w) => w.code),
        contains(PgSecurityWarningCode.passwordInConnectionString),
      );
    });

    test('an invalid service or combination throws PgImportException', () {
      expect(
        () => _single('[a]\nbogus\n').applyTo(PgConnectionConfig()),
        throwsA(isA<PgImportException>()),
      );
      final ports = _single('[a]\nport=1,2,3\n');
      expect(
        () => ports.applyTo(PgConnectionConfig.parse('host=a,b')),
        throwsA(
          isA<PgImportException>().having(
            (e) => e.toString(),
            'toString',
            startsWith('PgImportException: The service does not combine'),
          ),
        ),
      );
    });
  });

  test('diagnostics are in line order', () {
    final file = _parse('x=1\n[a]\nbogus\nport=99999\n[a]\n');
    expect([for (final d in file.diagnostics) d.line], [1, 3, 5]);
  });
}
