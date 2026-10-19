// File: psql_messages_test.dart
// Purpose: Server errors and notices formatted like psql (expected texts
// are real psql 17 output for the same statements), and \timing lines.

import 'package:dabase_postgresql/psql.dart';
import 'package:test/test.dart';

String _error(String query, String needle, String message, {String? hint}) =>
    formatServerMessage(
      severity: 'ERROR',
      message: message,
      query: query,
      position: query.indexOf(needle) + 1,
      hint: hint,
    );

void main() {
  group('error position like psql', () {
    test('one line', () {
      expect(
        _error(
          'select * from nosuch',
          'nosuch',
          'relation "nosuch" does not exist',
        ),
        'ERROR:  relation "nosuch" does not exist\n'
        'LINE 1: select * from nosuch\n'
        '                      ^\n',
      );
    });

    test('the line holding the error in a multi-line query', () {
      expect(
        _error(
          'select 1,\n  2, nosuchcol\nfrom (select 1) t;',
          'nosuchcol',
          'column "nosuchcol" does not exist',
        ),
        'ERROR:  column "nosuchcol" does not exist\n'
        'LINE 2:   2, nosuchcol\n'
        '             ^\n',
      );
    });

    test('long lines are cut on both sides around the error', () {
      final query =
          "select '${'a' * 78}' as x, '${'b' * 50}' || nosuch || "
          "'${'c' * 55}'";
      expect(
        _error(query, 'nosuch', 'column "nosuch" does not exist'),
        'ERROR:  column "nosuch" does not exist\n'
        "LINE 1: ...${'b' * 45}' || nosuch || ...\n"
        '                                                             ^\n',
      );
    });

    test('long lines are cut on the left only near the end, with a hint', () {
      final query = "select '${'a' * 78}' ||| 1";
      expect(
        _error(
          query,
          '|||',
          'operator does not exist: unknown ||| integer',
          hint:
              'No operator matches the given name and argument types. You '
              'might need to add explicit type casts.',
        ),
        'ERROR:  operator does not exist: unknown ||| integer\n'
        "LINE 1: ...${'a' * 53}' ||| 1\n"
        '                                                                  ^\n'
        'HINT:  No operator matches the given name and argument types. You '
        'might need to add explicit type casts.\n',
      );
    });

    test('wide characters move the caret two columns', () {
      expect(
        _error(
          "select '日本語' || nosuch",
          'nosuch',
          'column "nosuch" does not exist',
        ),
        'ERROR:  column "nosuch" does not exist\n'
        "LINE 1: select '日本語' || nosuch\n"
        '                           ^\n',
      );
    });

    test('no position: message and detail only', () {
      expect(
        formatServerMessage(
          severity: 'ERROR',
          message: 'duplicate key value violates unique constraint "tt_pkey"',
          detail: 'Key (a)=(1) already exists.',
        ),
        'ERROR:  duplicate key value violates unique constraint "tt_pkey"\n'
        'DETAIL:  Key (a)=(1) already exists.\n',
      );
    });
  });

  test('notices with detail and hint; context only when asked', () {
    expect(
      formatServerMessage(
        severity: 'NOTICE',
        message: 'hello 1',
        detail: 'd1',
        hint: 'h1',
        context: 'PL/pgSQL function inline_code_block line 1 at RAISE',
        showContext: false,
      ),
      'NOTICE:  hello 1\nDETAIL:  d1\nHINT:  h1\n',
    );
  });

  test('a position past the end of the query is ignored', () {
    expect(
      formatServerMessage(
        severity: 'ERROR',
        message: 'x',
        query: 'select',
        position: 99,
      ),
      'ERROR:  x\n',
    );
  });

  group('timing like psql', () {
    test('under a second', () {
      expect(
        formatTiming(const Duration(microseconds: 512345)),
        'Time: 512.345 ms',
      );
    });

    test('with minutes, hours and days', () {
      expect(
        formatTiming(const Duration(milliseconds: 61234)),
        'Time: 61234.000 ms (01:01.234)',
      );
      expect(
        formatTiming(const Duration(hours: 2, seconds: 5)),
        'Time: 7205000.000 ms (02:00:05.000)',
      );
      expect(
        formatTiming(const Duration(days: 1, hours: 1, minutes: 2)),
        'Time: 90120000.000 ms (1 d 01:02:00.000)',
      );
    });
  });
}
