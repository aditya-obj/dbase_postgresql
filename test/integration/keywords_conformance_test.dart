// File: keywords_conformance_test.dart
// Purpose: Differential test of our keyword table (generated from
// kwlist.h on master) against the server's own list:
//   SELECT word, catcode FROM pg_get_keywords()
// Run with `dart test -P integration` and DABASE_PG_URL set.
//
// Our table follows master, so older servers legitimately differ. The
// expected differences below come from diffing src/include/parser/kwlist.h
// on REL_13_STABLE .. REL_18_STABLE against master (2026-10-16). Each one
// is cited; anything else is a real mismatch.
@Tags(['integration'])
library;

import 'package:dabase_postgresql/sql.dart';
import 'package:postgres/postgres.dart' as pg;
import 'package:test/test.dart';

import 'support/pg_server.dart';

/// `pg_get_keywords().catcode` letters, from src/backend/utils/adt/misc.c.
const Map<String, SqlKeywordCategory> _categoryByCatcode = {
  'U': SqlKeywordCategory.unreserved,
  'C': SqlKeywordCategory.colName,
  'T': SqlKeywordCategory.typeFuncName,
  'R': SqlKeywordCategory.reserved,
};

/// Words the server knows that our (master) table no longer has, keyed by
/// word, with the last major version that has them.
///
/// * `recheck`: unreserved in PostgreSQL 13-17, removed from kwlist.h in
///   18.
const _removedSince = {'recheck': 17};

/// Words whose category changed, with the category on older servers and
/// the last major version that used it.
///
/// * `json`: unreserved in PostgreSQL 16, col_name since 17 (SQL/JSON
///   constructors; kwlist.h on REL_16_STABLE vs REL_17_STABLE).
const Map<String, (SqlKeywordCategory, int)> _oldCategory = {
  'json': (SqlKeywordCategory.unreserved, 16),
};

/// Keywords in our table that PostgreSQL 18 does not have yet (kwlist.h,
/// REL_18_STABLE vs master).
const _newerThan18 = {'ignore', 'lsn', 'repack', 'respect', 'wait'};

void main() {
  group('pg_get_keywords() agrees with sqlKeywordCategories', () {
    late pg.Connection connection;
    late int major;
    late Map<String, String> serverKeywords;

    setUpAll(() async {
      connection = await openTestConnection();
      major = await serverVersionNum(connection) ~/ 10000;
      final rows = await connection.execute(
        'SELECT word::text, catcode::text FROM pg_get_keywords()',
      );
      serverKeywords = {
        for (final row in rows) row[0]! as String: row[1]! as String,
      };
      printOnFailure('PostgreSQL major version $major');
    });

    tearDownAll(() => connection.close());

    test('every server keyword is ours, with the same category', () {
      final mismatches = <String>[];
      for (final MapEntry(key: word, value: catcode)
          in serverKeywords.entries) {
        final serverCategory = _categoryByCatcode[catcode];
        if (serverCategory == null) {
          mismatches.add('$word: unknown catcode "$catcode"');
          continue;
        }
        final ours = sqlKeywordCategory(word);
        if (ours == null) {
          final lastVersion = _removedSince[word];
          if (lastVersion == null || major > lastVersion) {
            mismatches.add('$word: missing from our table');
          }
          continue;
        }
        if (ours == serverCategory) continue;
        final old = _oldCategory[word];
        if (old != null && old.$1 == serverCategory && major <= old.$2) {
          continue;
        }
        mismatches.add(
          '$word: server ${serverCategory.name}, ours ${ours.name}',
        );
      }
      expect(mismatches, isEmpty);
    });

    test('our extra keywords are only ones newer than this server', () {
      final extras = sqlKeywordCategories.keys
          .where((word) => !serverKeywords.containsKey(word))
          .toSet();
      if (major >= 19) {
        expect(extras, isEmpty, reason: 'regenerate the keyword table');
      } else if (major == 18) {
        expect(extras, _newerThan18);
      } else {
        // Older majors: every PostgreSQL 18 addition is also missing, so
        // only check the direction that matters for highlighting.
        expect(extras, containsAll(_newerThan18));
      }
    });

    test('the lexer classifies every server keyword as a keyword', () {
      const lexer = SqlLexer();
      final notKeywords = [
        for (final word in serverKeywords.keys)
          if (!_removedSince.containsKey(word) &&
              lexer.tokenize(word).single.kind != SqlTokenKind.keyword)
            word,
      ];
      expect(notKeywords, isEmpty);
    });
  }, skip: skipReason);
}
