// File: mutation_fuzz_test.dart
// Purpose: Seeded random-mutation fuzzing: splices quote, dollar-tag,
// comment, escape-prefix, and %00 fragments into corpus inputs and checks
// invariants. Excluded by default; run with `dart test -P fuzz`.
// Set FUZZ_SEED to replay a run and FUZZ_ITERATIONS to change its length.
@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:math';

import 'package:dabase_postgresql/dabase_postgresql.dart';
import 'package:test/test.dart';

import '../sql/invariants_test.dart' show checkSqlInvariants;
import '../support/sql_corpus.dart';

String _mutate(String input, Random random) {
  var result = input;
  final edits = 1 + random.nextInt(4);
  for (var i = 0; i < edits; i++) {
    final at = result.isEmpty ? 0 : random.nextInt(result.length + 1);
    final fragment =
        mutationFragments[random.nextInt(mutationFragments.length)];
    if (random.nextBool() || result.isEmpty) {
      result = result.substring(0, at) + fragment + result.substring(at);
    } else {
      final end = min(result.length, at + random.nextInt(4));
      result = result.substring(0, at) + result.substring(end);
    }
  }
  return result;
}

void main() {
  final seed =
      int.tryParse(Platform.environment['FUZZ_SEED'] ?? '') ??
      DateTime.now().microsecondsSinceEpoch;
  final iterations =
      int.tryParse(Platform.environment['FUZZ_ITERATIONS'] ?? '') ?? 5000;
  // Logged so any failure can be replayed with FUZZ_SEED.
  stdout.writeln('mutation fuzz seed=$seed iterations=$iterations');

  test('SQL lexer, splitter and analyzer keep their invariants', () {
    final random = Random(seed);
    for (var i = 0; i < iterations; i++) {
      final base = sqlCorpus[random.nextInt(sqlCorpus.length)];
      final input = _mutate(base, random);
      try {
        checkSqlInvariants(input);
      } on Object {
        printOnFailure('seed=$seed iteration=$i input=${input.codeUnits}');
        rethrow;
      }
    }
  });

  test('connection parser only throws PgConfigParseException', () {
    final random = Random(seed);
    for (var i = 0; i < iterations; i++) {
      final base = connectionCorpus[random.nextInt(connectionCorpus.length)];
      final input = _mutate(base, random);
      try {
        final config = PgConnectionConfig.parse(input);
        // Whatever parses must survive a format/parse round trip.
        PgConnectionConfig.parse(config.toUri(includePassword: true));
        // The parsed password itself must never be printed. (A mutation can
        // legitimately turn "secret" into part of a user or database name.)
        final password = config.password;
        if (password != null && password.length >= 4) {
          expect(config.redacted(), isNot(contains(password)));
          expect(config.toString(), isNot(contains(password)));
        }
      } on PgConfigParseException catch (e) {
        expect(e.message, isNot(contains('secret')));
      } on Object {
        printOnFailure('seed=$seed iteration=$i input=${input.codeUnits}');
        rethrow;
      }
    }
  });
}
