// File: sql_lexer_test.dart
// Purpose: Unit tests for SqlLexer covering every PostgreSQL token form,
// diagnostics, and the standard_conforming_strings option.

import 'package:dbase_postgresql/sql.dart';
import 'package:test/test.dart';

const _lexer = SqlLexer();

/// Significant tokens as `kind:text` strings.
List<String> _sig(String sql, [SqlLexer lexer = _lexer]) => [
  for (final t in lexer.tokenize(sql))
    if (!t.isTrivia) '${t.kind.name}:${t.text}',
];

SqlToken _single(String sql, [SqlLexer lexer = _lexer]) {
  final tokens = lexer.tokenize(sql);
  expect(tokens, hasLength(1), reason: 'expected one token for $sql');
  return tokens.single;
}

void main() {
  group('trivia', () {
    test('whitespace runs are one token', () {
      final t = _single(' \t\r\n\f');
      expect(t.kind, SqlTokenKind.whitespace);
      expect((t.start, t.end), (0, 5));
    });

    test('line comment stops before the newline', () {
      final tokens = _lexer.tokenize('-- hi ; there\nSELECT');
      expect(tokens.first.kind, SqlTokenKind.lineComment);
      expect(tokens.first.text, '-- hi ; there');
      expect(tokens[1].kind, SqlTokenKind.whitespace);
    });

    test('line comment at end of input', () {
      expect(_single('-- end').kind, SqlTokenKind.lineComment);
    });

    test('block comments nest', () {
      final t = _single('/* a /* b */ c */');
      expect(t.kind, SqlTokenKind.blockComment);
      expect(t.isUnterminated, isFalse);
    });

    test('unterminated nested block comment is flagged', () {
      final t = _single('/* a /* b */ c');
      expect(t.diagnostic, SqlTokenDiagnostic.unterminated);
      expect(t.isUnterminated, isTrue);
    });
  });

  group('strings', () {
    test("standard string with '' escape", () {
      final t = _single("'it''s'");
      expect(t.kind, SqlTokenKind.string);
      expect(t.text, "'it''s'");
    });

    test('standard string keeps backslash literal by default', () {
      expect(_sig(r"'a\' || 'b'"), [
        r"string:'a\'",
        'operator:||',
        "string:'b'",
      ]);
    });

    test('standardConformingStrings: false makes backslash escape', () {
      const legacy = SqlLexer(standardConformingStrings: false);
      expect(_single(r"'a\'b'", legacy).kind, SqlTokenKind.string);
      expect(_single(r"N'a\'b'", legacy).kind, SqlTokenKind.string);
    });

    test('E string honours backslash and doubled quotes', () {
      for (final sql in [r"E'a\'b'", r"e'\\'", "E'a''b'", r"E'\n\t'"]) {
        final t = _single(sql);
        expect(t.kind, SqlTokenKind.escapeString, reason: sql);
      }
    });

    test('unterminated E string ends at backslash before EOF', () {
      final t = _single(r"E'abc\");
      expect(t.isUnterminated, isTrue);
    });

    test('U& string and U& identifier', () {
      expect(_single(r"U&'d\0061t'").kind, SqlTokenKind.unicodeString);
      expect(_single("u&'x''y'").kind, SqlTokenKind.unicodeString);
      expect(_single(r'U&"d\0061t"').kind, SqlTokenKind.quotedIdentifier);
    });

    test('bare U& falls back to identifier and operator (xufailed)', () {
      expect(_sig('U&x'), ['identifier:U', 'operator:&', 'identifier:x']);
    });

    test('bit strings and national strings', () {
      expect(_single("B'1010'").kind, SqlTokenKind.bitString);
      expect(_single("x'1F'").kind, SqlTokenKind.bitString);
      expect(_single("N'abc'").kind, SqlTokenKind.string);
    });

    test('a prefix letter inside a word is not a string prefix', () {
      expect(_sig("type'x'"), ['keyword:type', "string:'x'"]);
    });

    test('unterminated standard string runs to the end', () {
      final tokens = _lexer.tokenize("SELECT 'abc; DROP");
      expect(tokens.last.text, "'abc; DROP");
      expect(tokens.last.isUnterminated, isTrue);
    });

    test('adjacent strings stay separate tokens', () {
      expect(_sig("'a'\n'b'"), ["string:'a'", "string:'b'"]);
    });
  });

  group('dollar quotes', () {
    test(r'$$ with semicolons and quotes inside', () {
      final t = _single(r"$$ a; 'b'; -- c $$");
      expect(t.kind, SqlTokenKind.dollarString);
    });

    test('tagged dollar quote ignores other tags', () {
      final t = _single(r'$fn$ $$ $x$ inner $fn$');
      expect(t.kind, SqlTokenKind.dollarString);
    });

    test('tags are case-sensitive', () {
      final t = _single(r'$A$ x $a$');
      expect(t.isUnterminated, isTrue);
    });

    test(r'$junk$delim$ closes at the right delimiter', () {
      expect(_single(r'$a$x$ab$a$').text, r'$a$x$ab$a$');
    });

    test('tag cannot start with a digit; that is a parameter', () {
      expect(_sig(r'$1 $1a$'), [r'parameter:$1', r'parameter:$1a$']);
      expect(
        _lexer.tokenize(r'$1a$').single.diagnostic,
        SqlTokenDiagnostic.malformedParameter,
      );
    });

    test(r'a lone $ is unknown (dolqfailed)', () {
      expect(_sig(r'$ $foo'), [r'unknown:$', r'unknown:$', 'identifier:foo']);
    });

    test('identifier absorbs dollar signs', () {
      expect(_sig(r'a$$b$$'), [r'identifier:a$$b$$']);
    });

    test('unterminated dollar quote', () {
      expect(_single(r'$t$ never closed').isUnterminated, isTrue);
    });
  });

  group('identifiers and keywords', () {
    test('quoted identifier with "" escape', () {
      final t = _single('"My ""Table"""');
      expect(t.kind, SqlTokenKind.quotedIdentifier);
      expect(t.normalized, 'My "Table"');
    });

    test('unterminated quoted identifier', () {
      expect(_single('"abc').isUnterminated, isTrue);
    });

    test('keywords are case-insensitive and carry a category', () {
      final t = _single('SeLeCt');
      expect(t.kind, SqlTokenKind.keyword);
      expect(t.normalized, 'select');
      expect(t.keywordCategory, SqlKeywordCategory.reserved);
      expect(_single('UPDATE').keywordCategory, SqlKeywordCategory.unreserved);
    });

    test('non-keywords are identifiers', () {
      expect(_single('customer_id').kind, SqlTokenKind.identifier);
      expect(_single('customer_id').keywordCategory, isNull);
    });

    test('non-ASCII code units are identifier characters', () {
      expect(_single('café_\u{1F600}').kind, SqlTokenKind.identifier);
    });

    test('positional parameters', () {
      expect(_sig(r'$1 + $12'), [
        r'parameter:$1',
        'operator:+',
        r'parameter:$12',
      ]);
    });
  });

  group('numbers (PostgreSQL 16 rules)', () {
    for (final sql in [
      '42', '1.5', '.5', '5.', '1.5e10', '1e-3', '2E+7', '0x1F', '0X_ff', //
      '0o17', '0b1010', '1_000_000', '1_000.000_1', '0x_1',
    ]) {
      test('valid: $sql', () {
        final t = _single(sql);
        expect(t.kind, SqlTokenKind.number);
        expect(t.diagnostic, isNull);
      });
    }

    for (final sql in [
      '123abc', '1_', '1__0', '0x', '0xg', '0b2', '1e+', //
      '1.5e', '.5x', '0x1Fg',
    ]) {
      test('malformed: $sql', () {
        final t = _single(sql);
        expect(t.kind, SqlTokenKind.number);
        expect(t.diagnostic, SqlTokenDiagnostic.malformedNumber);
      });
    }

    test('1..10 lexes as integer, dot, dot-number', () {
      expect(_sig('1..10'), ['number:1', 'punctuation:.', 'number:.10']);
    });

    test('exponent without digits is junk, not a separate word', () {
      expect(_sig('1e'), ['number:1e']);
    });
  });

  group('operators and punctuation', () {
    test('typecast, colon-equals and named-arg arrow', () {
      expect(_sig('a::int, f(x := 1, y => 2)'), [
        'identifier:a',
        'punctuation:::',
        'keyword:int',
        'punctuation:,',
        'identifier:f',
        'punctuation:(',
        'identifier:x',
        'operator::=',
        'number:1',
        'punctuation:,',
        'identifier:y',
        'operator:=>',
        'number:2',
        'punctuation:)',
      ]);
    });

    test(':var is not special (psql syntax)', () {
      expect(_sig(':var'), ['punctuation::', 'identifier:var']);
    });

    test('multi-char operators', () {
      expect(_sig('a->>b @> c <> d'), [
        'identifier:a',
        'operator:->>',
        'identifier:b',
        'operator:@>',
        'identifier:c',
        'operator:<>',
        'identifier:d',
      ]);
    });

    test('trailing + / - is stripped from SQL-like operators', () {
      expect(_sig('a=-1'), [
        'identifier:a',
        'operator:=',
        'operator:-',
        'number:1',
      ]);
    });

    test('trailing - is kept when the operator has a non-SQL char', () {
      expect(_sig('a?-b'), ['identifier:a', 'operator:?-', 'identifier:b']);
      expect(_sig('a%-b'), ['identifier:a', 'operator:%-', 'identifier:b']);
    });

    test('operator stops before an embedded comment start', () {
      expect(_lexer.tokenize('*/*x*/').map((t) => t.kind), [
        SqlTokenKind.operator,
        SqlTokenKind.blockComment,
      ]);
      expect(_sig('+--c'), ['operator:+']);
    });

    test('punctuation', () {
      expect(_sig('( ) [ ] , ; .'), [
        'punctuation:(',
        'punctuation:)',
        'punctuation:[',
        'punctuation:]',
        'punctuation:,',
        'punctuation:;',
        'punctuation:.',
      ]);
    });

    test('backslash and braces are unknown', () {
      expect(_sig(r'\d {'), [r'unknown:\', 'identifier:d', 'unknown:{']);
    });
  });

  group('scan', () {
    test('starts at an offset and reports absolute offsets', () {
      final tokens = _lexer.scan('SELECT 1', start: 7).toList();
      expect(tokens.single.start, 7);
      expect(tokens.single.text, '1');
    });

    test('rejects an out-of-range start', () {
      expect(() => _lexer.scan('x', start: 2).toList(), throwsRangeError);
    });
  });

  test('toString never includes token text', () {
    final t = _single("'secret'");
    expect(t.toString(), isNot(contains('secret')));
  });
}
