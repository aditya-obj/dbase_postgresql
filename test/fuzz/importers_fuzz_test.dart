// File: importers_fuzz_test.dart
// Purpose: Seeded random fuzzing of the .pgpass, pg_service.conf and
// servers.json importers: libpq equivalence for .pgpass lookups, and
// "never throws / never leaks" invariants for mutated inputs. Excluded by
// default; run with `dart test -P fuzz`. Set FUZZ_SEED to replay a run and
// FUZZ_ITERATIONS to change its length.
@Tags(['fuzz'])
library;

import 'dart:io';
import 'dart:math';

import 'package:dbase_postgresql/dbase_postgresql.dart';
import 'package:test/test.dart';

import '../importers/pgpass_libpq_equivalence_test.dart'
    show comparePgPassLookup;
import '../support/importer_corpus.dart';

String _mutate(String input, Random random) {
  var result = input;
  final edits = 1 + random.nextInt(4);
  for (var i = 0; i < edits; i++) {
    final at = result.isEmpty ? 0 : random.nextInt(result.length + 1);
    if (random.nextBool() || result.isEmpty) {
      final fragment =
          importerFragments[random.nextInt(importerFragments.length)];
      result = result.substring(0, at) + fragment + result.substring(at);
    } else {
      final end = min(result.length, at + random.nextInt(4));
      result = result.substring(0, at) + result.substring(end);
    }
  }
  return result;
}

/// Expects [printed] not to contain [password], unless a mutation copied
/// the password into one of the non-secret [fields] (a host or a name),
/// which is then legitimately printed.
void _expectNoLeak(String printed, String? password, List<String?> fields) {
  if (password == null || password.length < 4) return;
  if (fields.any((f) => f != null && f.contains(password))) return;
  expect(printed, isNot(contains(password)));
}

List<String?> _publicFields(PgConnectionConfig config) => [
  config.user,
  config.database,
  ...config.hosts.map((h) => h.host),
  for (final MapEntry(:key, :value) in config.parameters.entries)
    if (!key.contains('password')) ...[key, value],
];

void main() {
  final seed =
      int.tryParse(Platform.environment['FUZZ_SEED'] ?? '') ??
      DateTime.now().microsecondsSinceEpoch;
  final iterations =
      int.tryParse(Platform.environment['FUZZ_ITERATIONS'] ?? '') ?? 5000;
  // Logged so any failure can be replayed with FUZZ_SEED.
  stdout.writeln('importers fuzz seed=$seed iterations=$iterations');

  void run(void Function(Random random, int i) body) {
    final random = Random(seed);
    for (var i = 0; i < iterations; i++) {
      try {
        body(random, i);
      } on Object {
        printOnFailure('seed=$seed iteration=$i');
        rethrow;
      }
    }
  }

  test('.pgpass lookup agrees with the libpq reference', () {
    run((random, i) {
      final text = randomPgPassText(random);
      expect(comparePgPassLookup(text, random), isNull);
    });
  });

  test('.pgpass parsing never throws or leaks the password', () {
    run((random, i) {
      final text = _mutate('h:5432:d:u:secret\n*:*:*:*:secret\n', random);
      final file = PgPassFile.parse(text);
      for (final d in file.diagnostics) {
        expect(d.message, isNot(contains('secret')));
      }
      for (final entry in file.entries) {
        // Built only from the match fields, so the password cannot appear.
        String show(String? field) => field ?? '*';
        expect(
          entry.toString(),
          'PgPassEntry(line ${entry.line}: ${show(entry.host)}:'
          '${show(entry.port)}:${show(entry.database)}:${show(entry.user)}'
          ':****)',
        );
        entry.toConfig();
      }
      file.lookup(host: 'h', port: 5432, database: 'd', user: 'u');
    });
  });

  test('service files never throw, and errors always invalidate', () {
    run((random, i) {
      final base = serviceCorpus[random.nextInt(serviceCorpus.length)];
      final file = PgServiceFile.parse(_mutate(base, random));
      final names = <String>{};
      for (final d in file.diagnostics) {
        expect(d.message, isNot(contains('secret')));
      }
      for (final service in file.services) {
        expect(names.add(service.name), isTrue, reason: 'duplicate name');
        final hasError = service.diagnostics.any(
          (d) => d.severity == PgImportSeverity.error,
        );
        expect(service.isValid, !hasError);
        if (service.config case final config?) {
          _expectNoLeak(
            config.toString(),
            config.password,
            _publicFields(config),
          );
        }
        if (service.isValid) service.applyTo(PgConnectionConfig());
      }
      PgServiceFile.merge(user: file, system: file);
    });
  });

  test('servers.json only throws PgImportException and never leaks', () {
    run((random, i) {
      final base = pgAdminCorpus[random.nextInt(pgAdminCorpus.length)];
      final input = _mutate(base, random);
      try {
        final file = PgAdminServersFile.parse(input);
        for (final server in file.servers) {
          _expectNoLeak(server.toString(), server.config.password, [
            server.id,
            server.name,
            ..._publicFields(server.config),
          ]);
          for (final w in server.warnings) {
            expect(w.message, isNot(contains('secret')));
          }
        }
        for (final error in file.errors) {
          expect(error.message, isNot(contains('secret')));
        }
      } on PgImportException catch (e) {
        expect(e.toString(), isNot(contains('secret')));
      }
    });
  });
}
