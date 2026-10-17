// File: pgpass_libpq_equivalence_test.dart
// Purpose: Checks PgPassFile.lookup against a literal port of libpq's
// passwordFromFile()/pwdfMatchesString() on many generated files.

import 'dart:math';

import 'package:dbase_postgresql/importers.dart';
import 'package:test/test.dart';

import '../support/importer_corpus.dart';
import '../support/libpq_pgpass_reference.dart';

/// Compares one lookup; returns a failure description or `null`.
String? comparePgPassLookup(String text, Random random) {
  T pick<T>(List<T> list) => list[random.nextInt(list.length)];
  final host = pick(hostTokens);
  final port = pick(portTokens);
  final database = pick(nameTokens);
  final user = pick(nameTokens);
  final expected = libpqPasswordFromText(
    text,
    hostname: host,
    port: port,
    dbname: database,
    username: user,
  );
  final actual = PgPassFile.parse(text)
      .lookup(
        host: host,
        port: port.isEmpty ? null : int.parse(port),
        database: database,
        user: user,
      )
      ?.password;
  if (expected == actual) return null;
  return 'text=${text.codeUnits} host="$host" port="$port" '
      'db="$database" user="$user" libpq=$expected ours=$actual';
}

void main() {
  test('lookup agrees with libpq on 20000 generated files', () {
    final random = Random(20261017);
    var matched = 0;
    for (var i = 0; i < 20000; i++) {
      final text = randomPgPassText(random);
      final failure = comparePgPassLookup(text, random);
      expect(failure, isNull, reason: 'iteration $i');
      if (PgPassFile.parse(text).entries.isNotEmpty) matched++;
    }
    // Make sure the generator produces usable lines, not only garbage.
    expect(matched, greaterThan(5000));
  });

  test('libpq edge cases agree', () {
    const cases = <(String, String, String, String, String)>[
      (r'a\:b:5432:a:a:pw', 'a:b', '5432', 'a', 'a'),
      (r'*:*:\*:*:pw', 'a', '', '*', 'a'),
      (r'*:*:\*:*:pw', 'a', '', 'a', 'a'),
      (r'a:5432:a:a:pw\', 'a', '5432', 'a', 'a'),
      (r'a:5432:a:a\', 'a', '5432', 'a', r'a\'),
      // libpq walks the line against each value, so unescaped colons in
      // the file match colons in the value (unescaped IPv6 hosts).
      ('::1:5432:a:a:pw', '::1', '5432', 'a', 'a'),
      ('a:b:5432:a:a:pw', 'a:b', '5432', 'a', 'a'),
      ('a:5432:a:b:*:pw', 'a', '5432', 'a:b', 'a'),
      ('localhost:5432:a:a:pw', '/tmp', '', 'a', 'a'),
      ('localhost:5432:a:a:pw', '127.0.0.1', '', 'a', 'a'),
      ('a:5432:a:a:p:w', 'a', '5432', 'a', 'a'),
      ('a:5432:a:a:pw\r\n', 'a', '', 'a', 'a'),
      ('#a:5432:a:a:pw\na:5432:a:a:second', 'a', '', 'a', 'a'),
    ];
    for (final (text, host, port, db, user) in cases) {
      final expected = libpqPasswordFromText(
        text,
        hostname: host,
        port: port,
        dbname: db,
        username: user,
      );
      final actual = PgPassFile.parse(text)
          .lookup(
            host: host,
            port: port.isEmpty ? null : int.parse(port),
            database: db,
            user: user,
          )
          ?.password;
      expect(actual, expected, reason: text);
    }
  });
}
