// File: libpg_query_split_test.dart
// Purpose: libpg_query's statement-split test vectors, run against
// SqlStatementSplitter, with divergences flagged per case.
//
// Ported from pganalyze/libpg_query test/split_tests.c (branch 17-latest,
// fetched 2026-10-16) - BSD 3-Clause License.
// Copyright (c) 2015, Lukas Fittl; (c) 2016-2023, Duboce Labs, Inc.
// (pganalyze). See THIRD_PARTY_NOTICES.
//
// Expected locations are verbatim (`loc=<offset>,len=<length>` per
// statement). A diverging case must still find the same number of
// statements, each inside the upstream slice, with only whitespace and
// comments outside ours.

import 'package:dabase_postgresql/sql.dart';
import 'package:test/test.dart';

final class _SplitCase {
  const _SplitCase(this.sql, this.expected, {this.diverges});

  final String sql;

  /// Upstream result, e.g. `loc=0,len=8;loc=9,len=9`.
  final String expected;

  /// Why our slices differ from upstream, or `null` for an exact match.
  final String? diverges;
}

const _cases = <_SplitCase>[
  _SplitCase('', ''),
  _SplitCase('SELECT 1', 'loc=0,len=8'),
  _SplitCase(
    'SELECT 1; SELECT 2',
    'loc=0,len=8;loc=9,len=9',
    diverges:
        'Leading whitespace is excluded from statement text (libpg_query '
        'includes it).',
  ),
  _SplitCase(
    'SELECT 1; SELECT 2; SELECT 3',
    'loc=0,len=8;loc=9,len=9;loc=19,len=9',
    diverges:
        'Leading whitespace is excluded from statement text (libpg_query '
        'includes it).',
  ),
  _SplitCase(
    'SELECT /* comment with ; */ 1; SELECT 2',
    'loc=0,len=29;loc=30,len=9',
    diverges:
        'Leading whitespace is excluded from statement text (libpg_query '
        'includes it).',
  ),
  _SplitCase(
    'SELECT --othercomment with ;\n 1; SELECT 2',
    'loc=0,len=31;loc=32,len=9',
    diverges:
        'Leading whitespace is excluded from statement text (libpg_query '
        'includes it).',
  ),
  _SplitCase(
    'CREATE RULE x AS ON SELECT TO tbl DO (SELECT 1; SELECT 2)',
    'loc=0,len=57',
  ),
  _SplitCase(
    'SELECT 1;\n;\n-- comment\nSELECT 2;\n;',
    'loc=0,len=8;loc=11,len=20',
    diverges:
        'Leading whitespace and comments are excluded from statement text '
        '(libpg_query attaches a leading comment to the following statement).',
  ),
];

void main() {
  const splitter = SqlStatementSplitter();
  const lexer = SqlLexer();

  for (final c in _cases) {
    test('split vector ${c.sql.replaceAll('\n', r'\n')}', () {
      final upstream = c.expected.isEmpty
          ? <(int, int)>[]
          : c.expected.split(';').map((item) {
              final match = RegExp(r'loc=(\d+),len=(\d+)').firstMatch(item)!;
              final loc = int.parse(match[1]!);
              return (loc, loc + int.parse(match[2]!));
            }).toList();
      final ours = splitter.split(c.sql);
      expect(ours, hasLength(upstream.length));
      for (var i = 0; i < ours.length; i++) {
        final (start, end) = upstream[i];
        if (c.diverges == null) {
          expect((ours[i].start, ours[i].end), (start, end));
          continue;
        }
        expect(ours[i].start, greaterThanOrEqualTo(start));
        expect(ours[i].end, lessThanOrEqualTo(end));
        final outside =
            c.sql.substring(start, ours[i].start) +
            c.sql.substring(ours[i].end, end);
        expect(lexer.tokenize(outside).every((t) => t.isTrivia), isTrue);
      }
    });
  }
}
