// File: invariants_test.dart
// Purpose: Structural invariants checked over the corpus and over
// fixed-seed random inputs: tokens tile the input, the lexer and analyzer
// never throw, and split slices are ordered and disjoint.

import 'dart:math';

import 'package:dabase_postgresql/sql.dart';
import 'package:test/test.dart';

import '../support/sql_corpus.dart';

const _lexer = SqlLexer();
const _legacyLexer = SqlLexer(standardConformingStrings: false);
const _splitter = SqlStatementSplitter();
const _analyzer = SqlStatementAnalyzer();

/// Token kinds reserved for a future `psqlMode`; never produced in v0.1.
const Set<SqlTokenKind> reservedPsqlKinds = {
  SqlTokenKind.psqlMetaCommand,
  SqlTokenKind.psqlVariable,
};

/// Checks every invariant for [input]; used by the fuzz test too.
void checkSqlInvariants(String input) {
  for (final lexer in [_lexer, _legacyLexer]) {
    final tokens = lexer.tokenize(input);
    var position = 0;
    for (final token in tokens) {
      expect(token.start, position, reason: 'tokens must tile the input');
      expect(token.text, isNotEmpty);
      expect(
        reservedPsqlKinds,
        isNot(contains(token.kind)),
        reason: 'psql token kinds are reserved; v0.1 never emits them',
      );
      expect(input.substring(token.start, token.end), token.text);
      position = token.end;
    }
    expect(position, input.length);
    expect(tokens.map((t) => t.text).join(), input);
  }

  final statements = _splitter.split(input);
  var previousEnd = 0;
  for (final statement in statements) {
    expect(statement.start, greaterThanOrEqualTo(previousEnd));
    expect(statement.end, greaterThan(statement.start));
    expect(input.substring(statement.start, statement.end), statement.text);
    expect(statement.tokens.first.start, statement.start);
    expect(statement.tokens.last.end, statement.end);
    previousEnd = statement.copyDataEnd ?? statement.endIncludingTerminator;
    expect(_analyzer.analyzeStatement(statement), isNotNull);
  }
  expect(previousEnd, lessThanOrEqualTo(input.length));
  expect(_analyzer.analyze(input), isNotNull);
  for (var offset = 0; offset <= input.length; offset += 7) {
    _splitter.statementAtOffset(input, offset);
  }
}

/// A random string over SQL-significant characters.
String randomSql(Random random, int length) {
  const alphabet = " \n\t'\"\$;()[]-/*+=<>:,.E&Uu0123456789xab_\\\u00e9";
  final buffer = StringBuffer();
  for (var i = 0; i < length; i++) {
    buffer.write(alphabet[random.nextInt(alphabet.length)]);
  }
  return buffer.toString();
}

void main() {
  group('corpus invariants', () {
    for (final (index, sql) in sqlCorpus.indexed) {
      test('corpus #$index', () => checkSqlInvariants(sql));
    }
  });

  test('fixed-seed random inputs keep the invariants', () {
    const seed = 20261016;
    final random = Random(seed);
    for (var i = 0; i < 300; i++) {
      final input = randomSql(random, random.nextInt(80));
      try {
        checkSqlInvariants(input);
      } on Object {
        printOnFailure('seed=$seed iteration=$i input=${input.codeUnits}');
        rethrow;
      }
    }
  });

  test('every keyword lexes as a keyword in any case', () {
    for (final word in sqlKeywordCategories.keys) {
      final token = _lexer.tokenize(word.toUpperCase()).single;
      expect(token.kind, SqlTokenKind.keyword, reason: word);
    }
  });
}
