// File: sql_statement_splitter_test.dart
// Purpose: Unit tests for SqlStatementSplitter: top-level semicolons,
// psql's BEGIN/CASE/END tracking, COPY FROM STDIN data, and cursor lookup.

import 'package:dabase_postgresql/sql.dart';
import 'package:test/test.dart';

const _splitter = SqlStatementSplitter();

List<String> _texts(String script) =>
    _splitter.split(script).map((s) => s.text).toList();

void main() {
  group('split', () {
    test('splits on top-level semicolons', () {
      expect(_texts('SELECT 1; SELECT 2;'), ['SELECT 1', 'SELECT 2']);
    });

    test('keeps a trailing statement without semicolon', () {
      final statements = _splitter.split('SELECT 1;\nSELECT 2');
      expect(statements.map((s) => s.text), ['SELECT 1', 'SELECT 2']);
      expect(statements.first.hasTerminator, isTrue);
      expect(statements.first.terminatorOffset, 8);
      expect(statements.last.hasTerminator, isFalse);
      expect(statements.last.endIncludingTerminator, 18);
    });

    test('ignores semicolons in strings, identifiers and comments', () {
      const script =
          "SELECT ';', E'\\';', \"a;b\" -- c;\n"
          'FROM t /* x; /* nested; */ y; */; SELECT 2';
      expect(_splitter.split(script), hasLength(2));
    });

    test('ignores semicolons inside dollar quotes', () {
      const script = r'''
CREATE FUNCTION f() RETURNS int LANGUAGE plpgsql AS $body$
BEGIN
  RETURN 1;
END;
$body$;
SELECT f();''';
      expect(_texts(script), hasLength(2));
      expect(_texts(script).last, 'SELECT f()');
    });

    test('ignores semicolons inside parentheses', () {
      const sql = 'CREATE RULE r AS ON INSERT TO t DO (SELECT 1; SELECT 2)';
      expect(_texts(sql), [sql]);
    });

    test('skips empty and comment-only statements', () {
      expect(_texts(';;  -- only a comment\n; /* c */ ;SELECT 1;;'), [
        'SELECT 1',
      ]);
    });

    test('leading and trailing comments are outside the statement', () {
      final s = _splitter.split('-- lead\nSELECT 1 -- tail\n;').single;
      expect(s.text, 'SELECT 1');
      expect(s.start, 8);
    });

    test('statement offsets index the script', () {
      const script = '  SELECT 1 ;  UPDATE t SET a = 1  ';
      for (final s in _splitter.split(script)) {
        expect(script.substring(s.start, s.end), s.text);
      }
    });

    test('an unbalanced ( keeps the rest in one statement (like psql)', () {
      expect(_splitter.split('SELECT (1; SELECT 2; SELECT 3'), hasLength(1));
    });

    test('an unterminated string swallows the rest', () {
      final s = _splitter.split("SELECT 'abc; SELECT 2;").single;
      expect(s.hasUnterminatedToken, isTrue);
    });
  });

  group('BEGIN ATOMIC and psql begin_depth', () {
    test('keeps a SQL-standard function body whole', () {
      const script = '''
CREATE FUNCTION f(a int) RETURNS int LANGUAGE sql
BEGIN ATOMIC
  SELECT a + 1;
  SELECT CASE WHEN a > 0 THEN 1 ELSE 0 END;
END;
SELECT f(1);''';
      final texts = _texts(script);
      expect(texts, hasLength(2));
      expect(texts.first, endsWith('END'));
    });

    test('CREATE OR REPLACE PROCEDURE is tracked', () {
      const script =
          'CREATE OR REPLACE PROCEDURE p() BEGIN ATOMIC '
          'INSERT INTO t VALUES (1); DELETE FROM u WHERE x; END; SELECT 1';
      expect(_texts(script), hasLength(2));
    });

    test('BEGIN outside CREATE FUNCTION is a transaction', () {
      expect(_texts('BEGIN; SELECT 1; END;'), ['BEGIN', 'SELECT 1', 'END']);
    });

    test('CASE outside a BEGIN block does not change depth', () {
      const script =
          'CREATE FUNCTION f() RETURNS int RETURN CASE WHEN true THEN 1 END;'
          ' SELECT 2;';
      expect(_texts(script), hasLength(2));
    });

    test('CREATE TABLE with a column named "begin" splits normally', () {
      expect(_texts('CREATE TABLE t ("begin" int); SELECT 1;'), hasLength(2));
    });
  });

  group('COPY FROM STDIN', () {
    test(r'skips the inline data block up to \.', () {
      const script =
          "COPY t (a, b) FROM stdin;\n1\tit's; not SQL\n2\t\$\$\n\\.\n"
          'SELECT 1;';
      final statements = _splitter.split(script);
      expect(statements.map((s) => s.text), [
        'COPY t (a, b) FROM stdin',
        'SELECT 1',
      ]);
      final copy = statements.first;
      expect(copy.isCopyFromStdin, isTrue);
      expect(
        script.substring(copy.copyDataStart!, copy.copyDataEnd),
        "1\tit's; not SQL\n2\t\$\$\n",
      );
      expect(statements.last.isCopyFromStdin, isFalse);
    });

    test('handles CRLF terminator lines', () {
      const script = 'COPY t FROM STDIN;\r\nx\r\n\\.\r\nSELECT 2;';
      expect(_texts(script), ['COPY t FROM STDIN', 'SELECT 2']);
    });

    test('missing terminator: data runs to end of script', () {
      const script = 'COPY t FROM STDIN;\nx;y';
      final copy = _splitter.split(script).single;
      expect(copy.copyDataEnd, script.length);
    });

    test('COPY ... TO STDOUT is not followed by data', () {
      expect(_texts('COPY t TO STDOUT; SELECT 1;'), hasLength(2));
    });
  });

  group('statementAtOffset', () {
    const script = 'SELECT 1;  SELECT 2;\n\nSELECT 3';
    //              0        9  11      19  22

    SqlStatement? at(int offset) => _splitter.statementAtOffset(script, offset);

    test('cursor at the very start selects the first statement', () {
      expect(at(0)?.text, 'SELECT 1');
    });

    test('cursor just after a semicolon selects that statement', () {
      expect(at(9)?.text, 'SELECT 1');
    });

    test('cursor in a same-line gap selects the previous statement', () {
      expect(at(10)?.text, 'SELECT 1');
    });

    test('cursor at the start of a statement selects it', () {
      expect(at(11)?.text, 'SELECT 2');
    });

    test('cursor on a blank line selects the next statement', () {
      expect(at(21)?.text, 'SELECT 3');
    });

    test('cursor at end of script selects the last statement', () {
      expect(at(script.length)?.text, 'SELECT 3');
      expect(
        _splitter.statementAtOffset('SELECT 1;\n\n', 11)?.text,
        'SELECT 1',
      );
    });

    test('no statements gives null', () {
      expect(_splitter.statementAtOffset('-- nothing', 3), isNull);
      expect(_splitter.statementAtOffset('', 0), isNull);
    });

    test('out-of-range offsets throw RangeError', () {
      expect(() => at(-1), throwsRangeError);
      expect(() => at(script.length + 1), throwsRangeError);
    });
  });
}
