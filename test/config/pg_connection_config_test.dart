// File: pg_connection_config_test.dart
// Purpose: Unit tests for PgConnectionConfig parsing (URI and conninfo),
// validation, multi-host, IPv6, sockets, and round-tripping.

import 'package:dabase_postgresql/connection_string.dart';
import 'package:test/test.dart';

PgConnectionConfig _p(String s) => PgConnectionConfig.parse(s);

Matcher _throwsAt(int offset) => throwsA(
  isA<PgConfigParseException>().having((e) => e.offset, 'offset', offset),
);

void main() {
  group('URI', () {
    test('full URI with both schemes', () {
      for (final scheme in ['postgres', 'postgresql', 'POSTGRES']) {
        final c = _p('$scheme://alice:pw@db.example.com:6543/app?x=1');
        expect(c.user, 'alice');
        expect(c.password, 'pw');
        expect(c.host, 'db.example.com');
        expect(c.port, 6543);
        expect(c.database, 'app');
        expect(c.parameters, {'x': '1'});
      }
    });

    test('default port when absent', () {
      final c = _p('postgres://h/db');
      expect(c.hosts.single.port, isNull);
      expect(c.port, 5432);
    });

    test('percent-decoding of every component', () {
      final c = _p(
        'postgres://us%40er:p%3Aw%2F%3F%25@h%C3%A9st/d%20b'
        '?application_name=caf%C3%A9+x',
      );
      expect(c.user, 'us@er');
      expect(c.password, 'p:w/?%');
      expect(c.host, 'hést');
      expect(c.database, 'd b');
      expect(c.applicationName, 'café+x');
    });

    test('unencoded @ in the password uses the last @', () {
      final c = _p('postgres://u:p@ss@host/db');
      expect(c.password, 'p@ss');
      expect(c.host, 'host');
    });

    test('IPv6 hosts in brackets, with port and zone id', () {
      expect(
        _p('postgres://[::1]:5433/db').hosts.single,
        const PgHost('::1', port: 5433),
      );
      expect(_p('postgres://[fe80::1%25eth0]/db').host, 'fe80::1%eth0');
    });

    test('unbracketed IPv6 is rejected', () {
      expect(() => _p('postgres://::1/db'), _throwsAt(11));
    });

    test('multi-host with per-host ports', () {
      final c = _p('postgres://a:5433,b,[::1]:5435/db');
      expect(c.hosts, const [
        PgHost('a', port: 5433),
        PgHost('b'),
        PgHost('::1', port: 5435),
      ]);
    });

    test('query parameters override and add keywords', () {
      final c = _p(
        'postgres://h/db?sslmode=verify-full&connect_timeout=10'
        '&target_session_attrs=read-write&options=-c%20x%3D1&ssl=true',
      );
      expect(c.sslMode, SslMode.verifyFull);
      expect(c.sslModeWasExplicit, isTrue);
      expect(c.connectTimeout, const Duration(seconds: 10));
      expect(c.parameters, {
        'connect_timeout': '10',
        'target_session_attrs': 'read-write',
        'options': '-c x=1',
      });
    });

    test('ssl=true maps to sslmode=require', () {
      final c = _p('postgres://h/db?ssl=true');
      expect(c.sslMode, SslMode.require);
      expect(c.sslModeWasExplicit, isTrue);
      expect(c.parameters, isEmpty);
    });

    test('Unix socket hosts', () {
      expect(
        _p('postgres://%2Fvar%2Frun/db').hosts.single.isUnixSocket,
        isTrue,
      );
      expect(_p('postgres://:5433/db').hosts.single.isUnixSocket, isTrue);
      expect(_p('postgres://h/db').hosts.single.isUnixSocket, isFalse);
      expect(_p('postgres:///db').hosts, isEmpty);
    });

    test('surrounding whitespace is ignored', () {
      expect(_p('  postgres://h/db \n').database, 'db');
    });
  });

  group('conninfo', () {
    test('keywords, spaces around =, quoted values with escapes', () {
      final c = _p(
        r"host=db port = 6000 dbname=app user=bob password='it\'s a \\ test'"
        " application_name='' sslmode=require",
      );
      expect(c.host, 'db');
      expect(c.port, 6000);
      expect(c.database, 'app');
      expect(c.user, 'bob');
      expect(c.password, r"it's a \ test");
      expect(c.applicationName, '');
      expect(c.sslMode, SslMode.require);
    });

    test('backslash escapes in unquoted values', () {
      expect(_p(r'host=a\ b').host, 'a b');
    });

    test('multi-host lists with one port for all', () {
      final c = _p('host=a,b,c port=6000');
      expect(c.hosts.map((h) => h.effectivePort), [6000, 6000, 6000]);
    });

    test('multi-host lists with parallel ports and empty items', () {
      final c = _p('host=a,b port=6000,');
      expect(c.hosts, const [PgHost('a', port: 6000), PgHost('b')]);
    });

    test('port without host means the default host', () {
      expect(_p('port=6000').hosts, const [PgHost('', port: 6000)]);
    });

    test('unknown keywords are kept', () {
      expect(_p('host=h foo=bar').parameters, {'foo': 'bar'});
    });

    test('later duplicates win', () {
      expect(_p('host=a host=b').host, 'b');
    });
  });

  group('errors', () {
    final cases = <String, int>{
      '': 0,
      '   ': 0,
      'just-a-hostname': 0,
      'jdbc:postgresql://h/db': 0,
      'host=h port=0': 12,
      'host=h port=65536': 12,
      'host=h port=12a': 12,
      'host=h port=-1': 12,
      'postgres://h:99999/db': 11,
      'postgres://h:x/db': 11,
      'host=a,b,c port=1,2': 16,
      'host=h sslmode=sometimes': 15,
      'postgres://h/db?ssl=yes': 20,
      'host=h connect_timeout=soon': 23,
      "host='unterminated": 5,
      'host=h =x': 7,
      'host=h user': 11,
      'postgres://h/db?a=1&=2': 20,
      'postgres://h/db?a%2': 16,
      'postgres://[::1]x/db': 16,
    };
    for (final MapEntry(key: input, value: offset) in cases.entries) {
      test('rejects ${input.isEmpty ? '(empty)' : input}', () {
        expect(() => _p(input), _throwsAt(offset));
        expect(PgConnectionConfig.tryParse(input), isNull);
      });
    }

    test('NUL is rejected raw and percent-encoded', () {
      expect(() => _p('host=a\u0000b'), _throwsAt(6));
      expect(() => _p('postgres://h/d%00b'), _throwsAt(14));
    });

    test('invalid UTF-8 in percent-encoding is rejected', () {
      expect(
        () => _p('postgres://h/%C3'),
        throwsA(isA<PgConfigParseException>()),
      );
    });
  });

  group('formatting', () {
    test('toUri round-trips to equivalent settings', () {
      for (final input in [
        'postgres://u:p%40ss@h:6000/d%2Fb?sslmode=verify-ca&application_name=x',
        'postgres://h1,h2:5433,[::1]/db',
        'host=/var/run/postgresql port=6000 dbname=d user=u',
        'postgres://h/db?sslpassword=k&options=-c%20a%3Db',
        'postgres://h:5432/db',
      ]) {
        final original = _p(input);
        final again = _p(original.toUri(includePassword: true));
        expect(again.hosts, original.hosts, reason: input);
        expect(again.user, original.user);
        expect(again.password, original.password);
        expect(again.database, original.database);
        expect(again.sslMode, original.sslMode);
        expect(again.sslModeWasExplicit, original.sslModeWasExplicit);
        expect(again.parameters, original.parameters);
      }
    });

    test('toUri omits secrets by default', () {
      final uri = _p('postgres://u:pw@h/db?sslpassword=k').toUri();
      expect(uri, 'postgresql://u@h/db');
    });

    test('explicit default port is preserved', () {
      expect(_p('postgres://h:5432/db').toUri(), 'postgresql://h:5432/db');
    });

    test('socket hosts are written as a query parameter', () {
      expect(
        _p('host=/tmp port=6000').toUri(),
        'postgresql://?host=%2Ftmp&port=6000',
      );
    });
  });

  test('copyWith upgrades sslmode and marks it explicit', () {
    final c = _p('postgres://h/db').copyWith(sslMode: SslMode.verifyFull);
    expect(c.sslMode, SslMode.verifyFull);
    expect(c.sslModeWasExplicit, isTrue);
    expect(c.securityWarnings, isEmpty);
  });

  test('programmatic construction defaults like libpq', () {
    final c = PgConnectionConfig(hosts: const [PgHost('h')], password: 'x');
    expect(c.sslMode, SslMode.prefer);
    expect(c.sslModeWasExplicit, isFalse);
    expect(
      c.securityWarnings.map((w) => w.code),
      isNot(contains(PgSecurityWarningCode.passwordInConnectionString)),
    );
    expect(() => c.parameters['a'] = 'b', throwsUnsupportedError);
  });
}
