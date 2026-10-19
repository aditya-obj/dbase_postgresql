// File: sql_script_reader_test.dart
// Purpose: Streaming a plain-SQL file into statements, COPY data and
// backslash commands, whatever the chunking, with line numbers.

import 'package:dabase_postgresql/dump.dart';
import 'package:test/test.dart';

Future<List<ScriptItem>> read(
  String script, {
  int chunk = 1 << 20,
  int copyChunkChars = 1 << 20,
}) => Stream.fromIterable([
  for (var i = 0; i < script.length; i += chunk)
    script.substring(i, (i + chunk).clamp(0, script.length)),
]).transform(SqlScriptReader(copyChunkChars: copyChunkChars)).toList();

String describe(ScriptItem i) => switch (i) {
  ScriptStatement(:final sql, :final line) => '$line: $sql',
  ScriptCopyStart(:final sql, :final line) => '$line: copy $sql',
  ScriptCopyData(:final text, :final lines, :final line) =>
    '$line: data $lines ${text.replaceAll('\n', '|')}',
  ScriptCopyEnd(:final line, :final terminated) =>
    '$line: end${terminated ? '' : ' (unterminated)'}',
  ScriptMetaCommand(:final command, :final arguments, :final line) =>
    '$line: \\$command $arguments',
};

void main() {
  const script = '''
-- a comment
SET a = 1; SET b = 2;
CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS \$\$
BEGIN
  RETURN 1;
END;
\$\$;

--
-- Name: t; Type: TABLE DATA; Schema: s
--

COPY s.t (a, b) FROM stdin;
1\tx
2\t\\N
\\.
SELECT 'semi;colon'
  ;
''';

  test('statements, a function body and COPY data with line numbers', () async {
    const body = 'BEGIN\n  RETURN 1;\nEND;\n\$\$';
    expect((await read(script)).map(describe), [
      '2: SET a = 1',
      '2: SET b = 2',
      '3: CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS \$\$\n$body',
      '13: copy COPY s.t (a, b) FROM stdin',
      '14: data 2 1\tx|2\t\\N|',
      '16: end',
      "17: SELECT 'semi;colon'",
    ]);
  });

  test('the result does not depend on the chunking', () async {
    final whole = (await read(script)).map(describe).toList();
    for (final size in [1, 2, 3, 7, 64]) {
      expect(
        (await read(script, chunk: size)).map(describe),
        whole,
        reason: 'chunk $size',
      );
    }
  });

  test('TOC comments label the items after them', () async {
    final items = await read(script);
    expect(items.first.toc, isNull);
    final copy = items.whereType<ScriptCopyStart>().single;
    expect(copy.toc.toString(), 'TABLE DATA s.t');
  });

  test('COPY data comes in chunks of whole lines', () async {
    final items = await read(
      'COPY t FROM stdin;\naaaa\nbbbb\ncccc\n\\.\n',
      copyChunkChars: 6,
    );
    expect(items.map(describe), [
      '1: copy COPY t FROM stdin',
      '2: data 2 aaaa|bbbb|',
      '4: data 1 cccc|',
      '5: end',
    ]);
  });

  test('CRLF line ends', () async {
    final items = await read('SELECT 1;\r\nCOPY t FROM stdin;\r\nx\r\n\\.\r\n');
    expect(items.map(describe), [
      '1: SELECT 1',
      '2: copy COPY t FROM stdin',
      '3: data 1 x|',
      '4: end',
    ]);
  });

  test('backslash commands at the start of a statement', () async {
    final items = await read(
      '\\restrict abc123\nSELECT 1;\n  \\connect other\n\\unrestrict abc123\n',
    );
    expect(items.map(describe), [
      r'1: \restrict abc123',
      '2: SELECT 1',
      r'3: \connect other',
      r'4: \unrestrict abc123',
    ]);
    final metas = items.whereType<ScriptMetaCommand>().toList();
    expect([for (final m in metas) m.isIgnorable], [true, false, true]);
  });

  test('a backslash inside a statement is SQL, not a command', () async {
    final items = await read("SELECT 'a\n\\b';\n");
    expect(items.map(describe), ["1: SELECT 'a\n\\b'"]);
  });

  test('an unterminated COPY and a last statement without ;', () async {
    expect((await read('COPY t FROM stdin;\n1\n')).map(describe), [
      '1: copy COPY t FROM stdin',
      '2: data 1 1|',
      '2: end (unterminated)',
    ]);
    expect((await read('SELECT 1;\nSELECT 2')).map(describe), [
      '1: SELECT 1',
      '2: SELECT 2',
    ]);
  });

  test('CSV and binary COPY can not be split into several statements', () {
    expect(
      const ScriptCopyStart('COPY t FROM stdin', line: 1).canSplit,
      isTrue,
    );
    expect(
      const ScriptCopyStart(
        'COPY t FROM stdin WITH (FORMAT csv)',
        line: 1,
      ).canSplit,
      isFalse,
    );
    expect(
      const ScriptCopyStart('COPY t FROM STDIN BINARY', line: 1).canSplit,
      isFalse,
    );
  });
}
