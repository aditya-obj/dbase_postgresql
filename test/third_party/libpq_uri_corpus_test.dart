// File: libpq_uri_corpus_test.dart
// Purpose: libpq's own URI parsing test corpus, run against
// PgConnectionConfig.parse, with deliberate divergences flagged per case.
//
// Ported from src/interfaces/libpq/t/001_uri.pl (master, fetched
// 2026-10-16) - PostgreSQL License.
// Copyright (c) 2021-2026, PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES. Divergence flags follow the pattern of
// jackc/pgx pgconn/parse_url_test.go.
//
// The corpus is the specification: change the parser to satisfy it, never
// the expectations to satisfy the parser. Generated mechanically from the
// upstream file; `libpqStdout`/`libpqStderr` are verbatim.

import 'package:dabase_postgresql/connection_string.dart';
import 'package:test/test.dart';

import '../support/libpq_describe.dart';

final class _UriCase {
  const _UriCase(
    this.uri,
    this.libpqStdout,
    this.libpqStderr, {
    this.diverges,
    this.ours,
    this.environment = const {},
  });

  final String uri;

  /// libpq_uri_regress output; empty when libpq reports an error.
  final String libpqStdout;

  /// libpq_uri_regress error; empty on success. Our errors are redacted,
  /// so only the fact that parsing fails is compared.
  final String libpqStderr;

  /// Why this parser deliberately behaves differently, or `null`.
  final String? diverges;

  /// Our expected description when [diverges] is set.
  final String? ours;

  /// Environment libpq ran with (informational; parsing is pure).
  final Map<String, String> environment;
}

const _cases = <_UriCase>[
  // Case 1.
  _UriCase(
    'postgresql://uri-user:secret@host:12345/db',
    "user='uri-user' password='secret' dbname='db' host='host' port='12345' "
        '(inet)',
    '',
  ),
  // Case 2.
  _UriCase(
    'postgresql://uri-user@host:12345/db',
    "user='uri-user' dbname='db' host='host' port='12345' (inet)",
    '',
  ),
  // Case 3.
  _UriCase(
    'postgresql://uri-user@host/db',
    "user='uri-user' dbname='db' host='host' (inet)",
    '',
  ),
  // Case 4.
  _UriCase(
    'postgresql://host:12345/db',
    "dbname='db' host='host' port='12345' (inet)",
    '',
  ),
  // Case 5.
  _UriCase('postgresql://host/db', "dbname='db' host='host' (inet)", ''),
  // Case 6.
  _UriCase(
    'postgresql://uri-user@host:12345/',
    "user='uri-user' host='host' port='12345' (inet)",
    '',
  ),
  // Case 7.
  _UriCase(
    'postgresql://uri-user@host/',
    "user='uri-user' host='host' (inet)",
    '',
  ),
  // Case 8.
  _UriCase('postgresql://uri-user@', "user='uri-user' (local)", ''),
  // Case 9.
  _UriCase('postgresql://host:12345/', "host='host' port='12345' (inet)", ''),
  // Case 10.
  _UriCase('postgresql://host:12345', "host='host' port='12345' (inet)", ''),
  // Case 11.
  _UriCase('postgresql://host/db', "dbname='db' host='host' (inet)", ''),
  // Case 12.
  _UriCase('postgresql://host/', "host='host' (inet)", ''),
  // Case 13.
  _UriCase('postgresql://host', "host='host' (inet)", ''),
  // Case 14.
  _UriCase('postgresql://', '(local)', ''),
  // Case 15.
  _UriCase(
    'postgresql://?hostaddr=127.0.0.1',
    "hostaddr='127.0.0.1' (inet)",
    '',
  ),
  // Case 16.
  _UriCase(
    'postgresql://example.com?hostaddr=63.1.2.4',
    "host='example.com' hostaddr='63.1.2.4' (inet)",
    '',
  ),
  // Case 17.
  _UriCase('postgresql://%68ost/', "host='host' (inet)", ''),
  // Case 18.
  _UriCase(
    'postgresql://host/db?user=uri-user',
    "user='uri-user' dbname='db' host='host' (inet)",
    '',
  ),
  // Case 19.
  _UriCase(
    'postgresql://host/db?user=uri-user&port=12345',
    "user='uri-user' dbname='db' host='host' port='12345' (inet)",
    '',
  ),
  // Case 20.
  _UriCase(
    'postgresql://host/db?u%73er=someotheruser&port=12345',
    "user='someotheruser' dbname='db' host='host' port='12345' (inet)",
    '',
  ),
  // Case 21.
  _UriCase(
    'postgresql://host/db?u%7aer=someotheruser&port=12345',
    '',
    'libpq_uri_regress: invalid URI query parameter: "uzer"',
    diverges:
        'Unknown query parameters are kept in parameters (libpq rejects them); '
        'see ADR 0001.',
    ours: "dbname='db' host='host' port='12345' (inet) uzer='someotheruser'",
  ),
  // Case 22.
  _UriCase(
    'postgresql://host:12345?user=uri-user',
    "user='uri-user' host='host' port='12345' (inet)",
    '',
  ),
  // Case 23.
  _UriCase(
    'postgresql://host?user=uri-user',
    "user='uri-user' host='host' (inet)",
    '',
  ),
  // Case 24.
  _UriCase(
    'postgresql://host?  user = uri-user & port  = 12345 ',
    "user='uri-user' host='host' port='12345' (inet)",
    '',
  ),
  // Case 25.
  _UriCase(
    'postgresql://host?  user user  =  uri  & port = 12345 12 ',
    '',
    'libpq_uri_regress: unexpected spaces found in "  user user  ", use '
        'percent-encoded spaces (%20) instead',
  ),
  // Case 26.
  _UriCase(
    'postgresql://host?  user  =  uri-user  & port = 12345 12 ',
    '',
    'libpq_uri_regress: unexpected spaces found in " 12345 12 ", use '
        'percent-encoded spaces (%20) instead',
  ),
  // Case 27.
  _UriCase('postgresql://host?', "host='host' (inet)", ''),
  // Case 28.
  _UriCase(
    'postgresql://[::1]:12345/db',
    "dbname='db' host='::1' port='12345' (inet)",
    '',
  ),
  // Case 29.
  _UriCase('postgresql://[::1]/db', "dbname='db' host='::1' (inet)", ''),
  // Case 30.
  _UriCase(
    'postgresql://[2001:db8::1234]/',
    "host='2001:db8::1234' (inet)",
    '',
  ),
  // Case 31.
  _UriCase(
    'postgresql://[200z:db8::1234]/',
    "host='200z:db8::1234' (inet)",
    '',
  ),
  // Case 32.
  _UriCase('postgresql://[::1]', "host='::1' (inet)", ''),
  // Case 33.
  _UriCase('postgres://', '(local)', ''),
  // Case 34.
  _UriCase('postgres:///', '(local)', ''),
  // Case 35.
  _UriCase('postgres:///db', "dbname='db' (local)", ''),
  // Case 36.
  _UriCase(
    'postgres://uri-user@/db',
    "user='uri-user' dbname='db' (local)",
    '',
  ),
  // Case 37.
  _UriCase(
    'postgres://?host=/path/to/socket/dir',
    "host='/path/to/socket/dir' (local)",
    '',
  ),
  // Case 38.
  _UriCase(
    'postgresql://host?uzer=',
    '',
    'libpq_uri_regress: invalid URI query parameter: "uzer"',
    diverges:
        'Unknown query parameters are kept in parameters (libpq rejects them); '
        'see ADR 0001.',
    ours: "host='host' (inet) uzer=''",
  ),
  // Case 39.
  _UriCase(
    'postgre://',
    '',
    'libpq_uri_regress: missing "=" after "postgre://" in connection info '
        'string',
  ),
  // Case 40.
  _UriCase(
    'postgres://[::1',
    '',
    'libpq_uri_regress: end of string reached when looking for matching "]" '
        'in IPv6 host address in URI: "postgres://[::1"',
  ),
  // Case 41.
  _UriCase(
    'postgres://[]',
    '',
    'libpq_uri_regress: IPv6 host address may not be empty in URI: '
        '"postgres://[]"',
  ),
  // Case 42.
  _UriCase(
    'postgres://[::1]z',
    '',
    'libpq_uri_regress: unexpected character "z" at position 17 in URI '
        '(expected ":" or "/"): "postgres://[::1]z"',
  ),
  // Case 43.
  _UriCase(
    'postgresql://host?zzz',
    '',
    'libpq_uri_regress: missing key/value separator "=" in URI query '
        'parameter: "zzz"',
  ),
  // Case 44.
  _UriCase(
    'postgresql://host?value1&value2',
    '',
    'libpq_uri_regress: missing key/value separator "=" in URI query '
        'parameter: "value1"',
  ),
  // Case 45.
  _UriCase(
    'postgresql://host?key=key=value',
    '',
    'libpq_uri_regress: extra key/value separator "=" in URI query parameter: '
        '"key"',
  ),
  // Case 46.
  _UriCase(
    'postgres://host?dbname=%XXfoo',
    '',
    'libpq_uri_regress: invalid percent-encoded token: "%XXfoo"',
  ),
  // Case 47.
  _UriCase(
    'postgresql://a%00b',
    '',
    'libpq_uri_regress: forbidden value %00 in percent-encoded value: "a%00b"',
  ),
  // Case 48.
  _UriCase(
    'postgresql://%zz',
    '',
    'libpq_uri_regress: invalid percent-encoded token: "%zz"',
  ),
  // Case 49.
  _UriCase(
    'postgresql://%1',
    '',
    'libpq_uri_regress: invalid percent-encoded token: "%1"',
  ),
  // Case 50.
  _UriCase(
    'postgresql://%',
    '',
    'libpq_uri_regress: invalid percent-encoded token: "%"',
  ),
  // Case 51.
  _UriCase('postgres://@host', "host='host' (inet)", ''),
  // Case 52.
  _UriCase('postgres://host:/', "host='host' (inet)", ''),
  // Case 53.
  _UriCase('postgres://:12345/', "port='12345' (local)", ''),
  // Case 54.
  _UriCase(
    'postgres://otheruser@?host=/no/such/directory',
    "user='otheruser' host='/no/such/directory' (local)",
    '',
  ),
  // Case 55.
  _UriCase(
    'postgres://otheruser@/?host=/no/such/directory',
    "user='otheruser' host='/no/such/directory' (local)",
    '',
  ),
  // Case 56.
  _UriCase(
    'postgres://otheruser@:12345?host=/no/such/socket/path',
    "user='otheruser' host='/no/such/socket/path' port='12345' (local)",
    '',
  ),
  // Case 57.
  _UriCase(
    'postgres://otheruser@:12345/db?host=/path/to/socket',
    "user='otheruser' dbname='db' host='/path/to/socket' port='12345' (local)",
    '',
  ),
  // Case 58.
  _UriCase(
    'postgres://:12345/db?host=/path/to/socket',
    "dbname='db' host='/path/to/socket' port='12345' (local)",
    '',
  ),
  // Case 59.
  _UriCase(
    'postgres://:12345?host=/path/to/socket',
    "host='/path/to/socket' port='12345' (local)",
    '',
  ),
  // Case 60.
  _UriCase(
    'postgres://%2Fvar%2Flib%2Fpostgresql/dbname',
    "dbname='dbname' host='/var/lib/postgresql' (local)",
    '',
  ),
  // Case 61.
  _UriCase(
    'postgresql://host?sslmode=disable',
    "host='host' sslmode='disable' (inet)",
    '',
    environment: {'PGSSLROOTCERT': 'system'},
  ),
  // Case 62.
  _UriCase(
    'postgresql://host?sslmode=prefer',
    "host='host' sslmode='prefer' (inet)",
    '',
    environment: {'PGSSLROOTCERT': 'system'},
  ),
  // Case 63.
  _UriCase(
    'postgresql://host?sslmode=verify-full',
    "host='host' (inet)",
    '',
    diverges:
        'libpq omits sslmode here because PGSSLROOTCERT=system makes '
        'verify-full its default; this parser never reads the environment and '
        'records the explicit sslmode.',
    ours: "host='host' sslmode='verify-full' (inet)",
    environment: {'PGSSLROOTCERT': 'system'},
  ),
];

void main() {
  test('corpus has all 63 upstream cases', () {
    expect(_cases, hasLength(63));
  });

  for (final c in _cases) {
    final expectError = c.libpqStderr.isNotEmpty && c.diverges == null;
    final label = c.diverges == null ? c.uri : '${c.uri} (diverges)';
    test(label, () {
      if (expectError) {
        expect(
          () => PgConnectionConfig.parse(c.uri),
          throwsA(isA<PgConfigParseException>()),
        );
        return;
      }
      final described = describeLikeLibpq(PgConnectionConfig.parse(c.uri));
      expect(described, c.diverges == null ? c.libpqStdout : c.ours);
    });
  }
}
