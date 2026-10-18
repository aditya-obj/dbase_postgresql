// File: psql_input_test.dart
// Purpose: psql's line handling: the query buffer, `;` terminators,
// backslash commands anywhere on a line, \g / \gx / \p / \r, quotes that
// hide backslashes, and the prompt continuation state.

import 'package:dbase_postgresql/psql.dart';
import 'package:test/test.dart';

List<String> _describe(List<PsqlInputItem> items) => [
  for (final item in items)
    switch (item) {
      PsqlQueryItem(:final sql, :final expanded) =>
        expanded ? 'QX:$sql' : 'Q:$sql',
      PsqlMetaItem(:final command) => 'M:${command.name}',
      PsqlTextItem(:final text, :final isError) =>
        isError ? 'E:$text' : 'T:$text',
    },
];

void main() {
  late PsqlInputScanner scanner;
  setUp(() => scanner = PsqlInputScanner());

  test('a statement ending in ; is sent at once', () {
    expect(_describe(scanner.feedLine('select 1;')), ['Q:select 1;']);
    expect(scanner.isEmpty, isTrue);
    expect(scanner.previous, 'select 1;');
  });

  test('several statements on one line go out in order', () {
    expect(_describe(scanner.feedLine('select 1; select 2;')), [
      'Q:select 1;',
      'Q:select 2;',
    ]);
  });

  test('an unfinished statement waits in the buffer across lines', () {
    expect(scanner.feedLine('select 1,'), isEmpty);
    expect(scanner.promptState, PsqlPromptState.continuation);
    expect(_describe(scanner.feedLine('  2;')), ['Q:select 1,\n  2;']);
    expect(scanner.promptState, PsqlPromptState.ready);
  });

  test('the prompt shows open quotes, comments and parentheses', () {
    PsqlPromptState after(String line) {
      scanner
        ..reset()
        ..feedLine(line);
      return scanner.promptState;
    }

    expect(after("select 'abc"), PsqlPromptState.singleQuote);
    expect(after('select "Col'), PsqlPromptState.doubleQuote);
    expect(after(r'select $$ body'), PsqlPromptState.dollarQuote);
    expect(after('select /* note'), PsqlPromptState.comment);
    expect(after('select (1'), PsqlPromptState.parenthesis);
  });

  test('a ; inside a string does not end the statement', () {
    expect(scanner.feedLine("select ';"), isEmpty);
    expect(_describe(scanner.feedLine("';")), ["Q:select ';\n';"]);
  });

  test('a ; inside parentheses does not end the statement', () {
    expect(scanner.feedLine('select (1;'), isEmpty);
    expect(scanner.isEmpty, isFalse);
  });

  test('a backslash command can follow SQL on the same line', () {
    expect(_describe(scanner.feedLine(r'select 1; \x')), [
      'Q:select 1;',
      'M:x',
    ]);
  });

  test(r'\g sends the buffer; with an empty buffer it repeats the last', () {
    expect(_describe(scanner.feedLine(r'select 1 \g')), ['Q:select 1']);
    expect(_describe(scanner.feedLine(r'\g')), ['Q:select 1']);
    expect(_describe(scanner.feedLine(r'\gx')), ['QX:select 1']);
  });

  test(r'\g with nothing ever sent does nothing', () {
    expect(scanner.feedLine(r'\g'), isEmpty);
  });

  test(r'\g with a file argument is refused', () {
    final items = scanner.feedLine(r'select 1 \g out.txt');
    expect(items.single, isA<PsqlTextItem>());
    expect((items.single as PsqlTextItem).isError, isTrue);
  });

  test(r'\p shows the buffer, \r clears it', () {
    scanner.feedLine('select 42');
    expect(_describe(scanner.feedLine(r'\p')), ['T:select 42']);
    expect(_describe(scanner.feedLine(r'\r')), [
      'T:Query buffer reset (cleared).',
    ]);
    expect(scanner.isEmpty, isTrue);
    expect(_describe(scanner.feedLine(r'\p')), ['T:Query buffer is empty.']);
  });

  test('a backslash inside a string or comment is not a command', () {
    expect(_describe(scanner.feedLine(r"select E'a\nb', '\x';")), [
      r"Q:select E'a\nb', '\x';",
    ]);
    expect(_describe(scanner.feedLine(r'select 1 /* \x */;')), [
      r'Q:select 1 /* \x */;',
    ]);
  });

  test(r'several commands on one line, and SQL after \\', () {
    expect(_describe(scanner.feedLine(r'\x on \timing \\ select 2;')), [
      'M:x',
      'M:timing',
      'Q:select 2;',
    ]);
  });

  test('a command parse error drops the rest of the line', () {
    expect(_describe(scanner.feedLine(r"\echo 'open \x")), [
      'E:unterminated quoted string',
    ]);
  });

  test('blank lines and whitespace leave the buffer empty', () {
    expect(scanner.feedLine('   '), isEmpty);
    expect(scanner.isEmpty, isTrue);
    expect(scanner.promptState, PsqlPromptState.ready);
  });

  test('the buffer is kept while a describe runs mid-statement', () {
    scanner.feedLine('select 1');
    expect(_describe(scanner.feedLine(r'\dt')), ['M:dt']);
    expect(scanner.buffer, 'select 1');
  });
}
