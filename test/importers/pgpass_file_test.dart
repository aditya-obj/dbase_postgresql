// File: pgpass_file_test.dart
// Purpose: Unit tests for PgPassFile: libpq's field matching, escapes,
// wildcards, host normalisation, line handling and diagnostics.

import 'package:dabase_postgresql/connection_string.dart';
import 'package:dabase_postgresql/importers.dart';
import 'package:test/test.dart';

String? _pw(
  String text, {
  String? host = 'h',
  String? hostaddr,
  int? port = 5432,
  String? database = 'd',
  String? user = 'u',
  String socketDirectory = PgPassFile.defaultSocketDirectory,
}) => PgPassFile.parse(text)
    .lookup(
      host: host,
      hostaddr: hostaddr,
      port: port,
      database: database,
      user: user,
      socketDirectory: socketDirectory,
    )
    ?.password;

List<PgPassDiagnosticCode> _codes(String text) => [
  for (final d in PgPassFile.parse(text).diagnostics) d.code,
];

void main() {
  group('matching (pwdfMatchesString)', () {
    test('exact match on all four fields', () {
      expect(_pw('h:5432:d:u:secret'), 'secret');
      expect(_pw('h:5432:d:x:secret'), isNull);
      expect(_pw('h:5433:d:u:secret'), isNull);
    });

    test('the first matching line wins', () {
      const text = 'h:5432:d:u:first\n*:*:*:*:wild\nh:5432:d:u:second\n';
      expect(_pw(text), 'first');
      expect(_pw(text, user: 'other'), 'wild');
      expect(_pw('*:*:*:*:wild\nh:5432:d:u:specific'), 'wild');
    });

    test('* is a wildcard only as a whole field', () {
      expect(_pw('*:*:*:*:pw'), 'pw');
      expect(_pw('h:*:d*:u:pw', database: 'd*'), 'pw');
      expect(_pw('h:*:d*:u:pw', database: 'dx'), isNull);
      expect(_pw('h:*:**:u:pw'), isNull);
    });

    test(r'\* matches only a literal asterisk', () {
      expect(_pw(r'h:5432:\*:u:pw', database: '*'), 'pw');
      expect(_pw(r'h:5432:\*:u:pw'), isNull);
      final entry = PgPassFile.parse(r'h:5432:\*:u:pw').entries.single;
      expect(entry.database, '*');
      expect(entry.hasWildcard, isFalse);
    });

    test(r'backslash escapes : and \ in match fields', () {
      expect(_pw(r'a\:b:5432:d:u:pw', host: 'a:b'), 'pw');
      expect(_pw(r'a\\:5432:d:u:pw', host: r'a\'), 'pw');
      expect(_pw(r'h:5432:d\x:u:pw', database: 'dx'), 'pw');
      expect(_pw(r'h:5432:d:u\\\::pw', user: r'u\:'), 'pw');
    });

    test('password de-escaping and termination', () {
      expect(_pw(r'h:5432:d:u:p\:w'), 'p:w');
      expect(_pw(r'h:5432:d:u:p\\w'), r'p\w');
      expect(_pw(r'h:5432:d:u:pw\'), r'pw\');
      expect(_pw('h:5432:d:u:pw:extra:fields'), 'pw');
      expect(_pw('h:5432:d:u:'), '');
    });

    test('comparisons are case-sensitive and exact', () {
      expect(_pw('H:5432:d:u:pw'), isNull);
      expect(_pw('h :5432:d:u:pw'), isNull);
      expect(_pw('h:5432:D:u:pw'), isNull);
    });

    test('empty fields only match empty tokens, which never occur', () {
      expect(_pw(':5432:d:u:pw', host: ''), isNull);
      expect(_pw('h::d:u:pw', port: null), isNull);
      expect(_pw('h:5432:d:u:pw', database: ''), isNull);
      expect(_pw('h:5432:d:u:pw', user: null), isNull);
    });
  });

  group('host and port normalisation', () {
    test('empty host and the default socket directory are localhost', () {
      const text = 'localhost:5432:d:u:pw';
      expect(_pw(text, host: null), 'pw');
      expect(_pw(text, host: ''), 'pw');
      expect(_pw(text, host: '/tmp'), 'pw');
      expect(_pw(text, host: '/var/run/postgresql'), isNull);
      expect(
        _pw(
          text,
          host: '/var/run/postgresql',
          socketDirectory: '/var/run/postgresql',
        ),
        'pw',
      );
    });

    test('127.0.0.1 and localhost are different hosts', () {
      expect(_pw('localhost:5432:d:u:pw', host: '127.0.0.1'), isNull);
      expect(_pw('127.0.0.1:5432:d:u:pw', host: 'localhost'), isNull);
    });

    test('hostaddr is used only when host is empty', () {
      const text = '10.0.0.1:5432:d:u:addr\nh:5432:d:u:name';
      expect(_pw(text, host: '', hostaddr: '10.0.0.1'), 'addr');
      expect(_pw(text, hostaddr: '10.0.0.1'), 'name');
    });

    test('a missing port is 5432', () {
      expect(_pw('h:5432:d:u:pw', port: null), 'pw');
      expect(_pw('h:6432:d:u:pw', port: 6432), 'pw');
    });

    test('lookupForConfig looks up each host of a multi-host config', () {
      final file = PgPassFile.parse(
        'a:5432:shop:alice:pa\nb:6000:shop:alice:pb\n',
      );
      final config = PgConnectionConfig.parse(
        'postgres://alice@a,b:6000,c/shop',
      );
      expect(file.lookupForConfig(config).map((e) => e?.password), [
        'pa',
        'pb',
        null,
      ]);
    });

    test('lookupForConfig uses hostaddr, then localhost, and dbname=user', () {
      final file = PgPassFile.parse(
        '10.0.0.1:5432:alice:alice:addr\nlocalhost:5432:alice:alice:local',
      );
      expect(
        file
            .lookupForConfig(
              PgConnectionConfig.parse('hostaddr=10.0.0.1 user=alice'),
            )
            .single
            ?.password,
        'addr',
      );
      expect(
        file
            .lookupForConfig(PgConnectionConfig.parse('user=alice'))
            .single
            ?.password,
        'local',
      );
      expect(
        file.lookupForConfig(PgConnectionConfig.parse('dbname=x')).single,
        isNull,
      );
    });
  });

  group('lines', () {
    test('# starts a comment only in column 0', () {
      expect(_pw('#h:5432:d:u:pw'), isNull);
      expect(_codes('#h:5432:d:u:pw'), isEmpty);
      final file = PgPassFile.parse('  # just a note');
      expect(file.entries, isEmpty);
      expect(_codes('  # just a note'), [PgPassDiagnosticCode.indentedComment]);
    });

    test('an indented comment with five fields is still data', () {
      final file = PgPassFile.parse(' #h:5432:d:u:pw');
      expect(file.entries.single.host, ' #h');
      expect(_codes(' #h:5432:d:u:pw'), [PgPassDiagnosticCode.indentedComment]);
    });

    test('blank and whitespace-only lines are ignored', () {
      final file = PgPassFile.parse('\n   \n\t\r\nh:5432:d:u:pw\n\n');
      expect(file.entries.single.line, 4);
      expect(file.diagnostics, isEmpty);
    });

    test('CRLF, repeated CR and a missing final newline', () {
      expect(_pw('x:1:d:u:a\r\nh:5432:d:u:pw\r\n'), 'pw');
      expect(_pw('h:5432:d:u:pw\r\r\n'), 'pw');
      expect(_pw('h:5432:d:u:pw'), 'pw');
      // A lone CR is not a line break for fgets(); it stays in the line.
      expect(_pw('h:5432:d:u:p\rw'), 'p\rw');
      expect(_pw('x:1:d:u:a\rh:5432:d:u:pw'), isNull);
    });

    test('a byte order mark is ignored with a warning', () {
      final file = PgPassFile.parse('\uFEFFh:5432:d:u:pw\n');
      expect(file.entries.single.host, 'h');
      expect(file.diagnostics.single.code, PgPassDiagnosticCode.byteOrderMark);
      expect(file.diagnostics.single.line, 1);
    });

    test('trailing whitespace stays in the password, with a warning', () {
      expect(_pw('h:5432:d:u:pw \t'), 'pw \t');
      expect(_codes('h:5432:d:u:pw '), [
        PgPassDiagnosticCode.trailingWhitespace,
      ]);
    });

    test('leading whitespace stays in the host, with a warning', () {
      expect(_pw(' h:5432:d:u:pw'), isNull);
      expect(_pw(' h:5432:d:u:pw', host: ' h'), 'pw');
      expect(_codes(' h:5432:d:u:pw'), [
        PgPassDiagnosticCode.leadingWhitespace,
      ]);
    });

    test('fewer than five fields never match and are reported', () {
      for (final text in ['h', 'h:5432', 'h:5432:d', 'h:5432:d:u', '*:*:*:*']) {
        expect(PgPassFile.parse(text).entries, isEmpty, reason: text);
        expect(_codes(text), [PgPassDiagnosticCode.tooFewFields]);
      }
      // An escaped colon does not separate fields.
      expect(_codes(r'h:5432:d:u\:pw'), [PgPassDiagnosticCode.tooFewFields]);
      expect(
        PgPassFile.parse('h:5432:d').diagnostics.single.message,
        contains('found 3 fields'),
      );
      expect(
        PgPassFile.parse('h').diagnostics.single.message,
        contains('found 1 field.'),
      );
    });

    test('extra fields are ignored with an info diagnostic', () {
      final file = PgPassFile.parse('h:5432:d:u:pw:x');
      expect(file.entries.single.password, 'pw');
      expect(file.diagnostics.single.severity, PgImportSeverity.info);
      expect(file.diagnostics.single.code, PgPassDiagnosticCode.extraFields);
    });

    test('lines with NUL are skipped', () {
      final file = PgPassFile.parse('h:5432:d:u:p\u0000w\nh:5432:d:u:ok');
      expect(file.entries.single.password, 'ok');
      expect(file.diagnostics.single.code, PgPassDiagnosticCode.nulCharacter);
    });

    test('very long lines are read whole', () {
      final password = 'x' * 100000;
      expect(_pw('h:5432:d:u:$password'), password);
      final host = 'h' * 5000;
      expect(_pw('$host:5432:d:u:pw', host: host), 'pw');
    });

    test('diagnostics keep line numbers', () {
      final file = PgPassFile.parse('# c\nbad\n\nh:5432:d:u:pw \n');
      expect([for (final d in file.diagnostics) d.line], [2, 4]);
      expect(file.entries.single.line, 4);
    });
  });

  group('entries', () {
    test('wildcards are null', () {
      final entry = PgPassFile.parse('*:5432:*:u:pw').entries.single;
      expect(entry.host, isNull);
      expect(entry.port, '5432');
      expect(entry.database, isNull);
      expect(entry.user, 'u');
      expect(entry.hasWildcard, isTrue);
      expect(entry.toConfig(), isNull);
    });

    test('toConfig builds a draft for a concrete entry', () {
      final config = PgPassFile.parse('db.example.com:6432:shop:alice:pw')
          .entries
          .single
          .toConfig()!;
      expect(config.hosts.single, const PgHost('db.example.com', port: 6432));
      expect(config.database, 'shop');
      expect(config.user, 'alice');
      expect(config.password, 'pw');
      expect(
        config.securityWarnings.map((w) => w.code),
        isNot(contains(PgSecurityWarningCode.passwordInConnectionString)),
      );
    });

    test('toConfig rejects bad ports and drops an empty password', () {
      for (final port in ['0', '65536', 'abc', '+1', '99999999999999999999']) {
        expect(
          PgPassFile.parse('h:$port:d:u:pw').entries.single.toConfig(),
          isNull,
          reason: port,
        );
      }
      final config = PgPassFile.parse('h:1:d:u:').entries.single.toConfig();
      expect(config?.password, isNull);
    });

    test('lookup reports how libpq read the matching line', () {
      final match = PgPassFile.parse('h:*:d:*:pw')
          .lookup(host: 'h', port: 1, database: 'd', user: 'u')!;
      expect(match.line, 1);
      expect(match.host, 'h');
      expect(match.port, isNull);
      expect(match.user, isNull);
      expect(match.password, 'pw');
    });

    test('unescaped IPv6 hosts match as in libpq', () {
      final file = PgPassFile.parse('::1:5432:d:u:pw\n');
      // Split as documented, the line looks wrong...
      expect(file.entries.single.host, '');
      expect(file.diagnostics.single.code, PgPassDiagnosticCode.extraFields);
      // ...but libpq's matcher consumes the colons of the value.
      final match = file.lookup(host: '::1', database: 'd', user: 'u')!;
      expect(match.host, '::1');
      expect(match.password, 'pw');
      expect(
        PgPassFile.parse(r'\:\:1:5432:d:u:pw')
            .lookup(host: '::1', database: 'd', user: 'u')
            ?.password,
        'pw',
      );
    });
  });

  group('secrets', () {
    const password = 'hunter2-secret';
    const text =
        'h:5432:d:u:$password\n'
        'h:5432:d:u:$password \n'
        'h:5432:d:u:$password:extra\n'
        ' h:5432:d:u:$password\n'
        'h:5432:d:u\\:$password\n'
        'h:5432:d:u:$password\u0000\n';

    test('toString and diagnostics never contain the password', () {
      final file = PgPassFile.parse(text);
      expect(file.diagnostics, isNotEmpty);
      for (final d in file.diagnostics) {
        expect(d.toString(), isNot(contains(password)));
      }
      for (final e in file.entries) {
        expect(e.toString(), isNot(contains(password)));
        expect(e.toString(), contains('****'));
      }
      expect(file.toString(), isNot(contains(password)));
      expect(
        PgPassFile.parse('*:*:d:u:pw').entries.single.toString(),
        'PgPassEntry(line 1: *:*:d:u:****)',
      );
    });
  });

  test('diagnostic equality and toString', () {
    const a = PgLineDiagnostic(
      line: 1,
      code: PgPassDiagnosticCode.tooFewFields,
      severity: PgImportSeverity.warning,
      message: 'm',
    );
    const b = PgLineDiagnostic(
      line: 1,
      code: PgPassDiagnosticCode.tooFewFields,
      severity: PgImportSeverity.warning,
      message: 'm',
    );
    expect(a, b);
    expect(a.hashCode, b.hashCode);
    expect(a.toString(), 'PgLineDiagnostic(line 1, warning tooFewFields: m)');
  });
}
