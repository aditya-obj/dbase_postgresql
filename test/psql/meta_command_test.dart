// File: meta_command_test.dart
// Purpose: The backslash-command parser against psql's psqlscanslash.l
// rules: command names, argument splitting, quoting, escapes, `\\`
// terminators, semicolon stripping and identifier dequoting.

import 'package:dbase_postgresql/psql.dart';
import 'package:test/test.dart';

MetaCommand _parse(String text) => parseMetaCommand(text, 0);

List<String> _args(String text) => [
  for (final arg in _parse(text).args) arg.value(),
];

void main() {
  group('command name', () {
    test('runs to whitespace or the next backslash', () {
      expect(_parse(r'\dt+ users').name, 'dt+');
      expect(_parse(r'\x\dt').name, 'x');
      expect(_parse(r'\?').name, '?');
      expect(_parse(r'\d').args, isEmpty);
    });

    test('ends at the next command, which is not an argument', () {
      final command = _parse(r'\x on \dt');
      expect(command.name, 'x');
      expect(_args(r'\x on \dt'), ['on']);
      expect(r'\x on \dt'.substring(command.end), r'\dt');
    });

    test(r'a trailing \\ is eaten and SQL resumes after it', () {
      const text = r'\x on \\ select 1;';
      final command = _parse(text);
      expect(command.args.single.value(), 'on');
      expect(text.substring(command.end), ' select 1;');
    });

    test('parses from an offset inside a line', () {
      const text = r'select 1 \gx';
      final command = parseMetaCommand(text, 9);
      expect(command.name, 'gx');
      expect(command.text, r'\gx');
      expect(command.end, text.length);
    });

    test('rejects an offset that is not a backslash', () {
      expect(() => parseMetaCommand('select', 0), throwsArgumentError);
    });
  });

  group('arguments', () {
    test('split on unquoted whitespace', () {
      expect(_args(r'\df  foo   int4 -'), ['foo', 'int4', '-']);
    });

    test("single quotes: '' and backslash escapes, quotes removed", () {
      expect(_args(r"\echo 'it''s' 'a\tb' 'x\ny'"), ["it's", 'a\tb', 'x\ny']);
      expect(_args(r"\echo '\101\x42\q'"), ['ABq']);
      expect(_args(r"\echo 'two words'"), ['two words']);
      expect(_args(r"\echo a'b c'd"), ['ab cd']);
    });

    test('double quotes are kept in the normal reading', () {
      expect(_args(r'\d "My Table"'), ['"My Table"']);
      expect(_args(r'\d public."A b".x'), ['public."A b".x']);
    });

    test('a backslash inside quotes does not end the argument', () {
      expect(_args(r'\d "a\b"'), [r'"a\b"']);
    });

    test('unterminated quotes are an error', () {
      expect(
        () => _parse(r"\echo 'oops"),
        throwsA(isA<MetaCommandFormatException>()),
      );
      expect(
        () => _parse(r'\d "oops'),
        throwsA(
          isA<MetaCommandFormatException>().having(
            (e) => e.message,
            'message',
            'unterminated quoted string',
          ),
        ),
      );
    });

    test('backquotes (shell commands) are refused', () {
      expect(
        () => _parse(r'\echo `date`'),
        throwsA(isA<MetaCommandFormatException>()),
      );
    });

    test('semicolon stripping only removes unquoted trailing ones', () {
      final args = _parse(r"\d users;; 'x;' 'y';").args;
      expect(args[0].value(semicolon: true), 'users');
      expect(args[0].value(), 'users;;');
      expect(args[1].value(semicolon: true), 'x;');
      expect(args[2].value(semicolon: true), 'y');
    });

    test('records the last quote character', () {
      final args = _parse(r'''\echo plain 'single' "double"''').args;
      expect(args[0].quote, isNull);
      expect(args[1].quote, "'");
      expect(args[2].quote, '"');
      expect(args[1].isQuoted, isTrue);
    });

    test('the identifier reading dequotes and lower-cases', () {
      final args = _parse(r'\x FOO "Bar"Baz "a""b"').args;
      expect(args[0].sqlIdentifier(), 'foo');
      expect(args[1].sqlIdentifier(), 'Barbaz');
      expect(args[2].sqlIdentifier(), 'a"b');
      expect(dequoteDowncaseIdentifier('ABC', downcase: false), 'ABC');
    });

    test('arg() reads by position', () {
      final command = _parse(r'\pset null (null)');
      expect(command.arg(0), 'null');
      expect(command.arg(1), '(null)');
      expect(command.arg(2), isNull);
    });
  });
}
