// File: copy_text_test.dart
// Purpose: COPY text encoding (CopyAttributeOutText rules) and decoding,
// with the server text of every kind of value a dump carries.

import 'package:dbase_postgresql/dump.dart';
import 'package:test/test.dart';

void main() {
  group('encodeCopyTextRow', () {
    test(r'NULL is \N, an empty string stays empty, fields are tab '
        'separated and the row ends with LF', () {
      expect(encodeCopyTextRow(['1', null, '']), '1\t\\N\t\n');
    });

    test('escapes backslash, tab, LF, CR, BS, FF and VT', () {
      expect(
        encodeCopyTextRow([
          r'back\slash',
          'a\tb',
          'line1\nline2',
          'cr\rlf',
          '\b\f\v',
        ]),
        [r'back\\slash', r'a\tb', r'line1\nline2', r'cr\rlf', r'\b\f\v'].tabbed,
      );
    });

    test(r'a value that is literally \N or \. is escaped, not taken as '
        'NULL or end of data', () {
      expect(encodeCopyTextRow([r'\N']), '\\\\N\n');
      expect(encodeCopyTextRow([r'\.']), '\\\\.\n');
    });

    test('server text of common types passes through as psql COPY '
        'prints it', () {
      // As `COPY t TO STDOUT` prints these values (bytea_output hex,
      // DateStyle ISO, IntervalStyle postgres, extra_float_digits 3, UTC).
      final row = <String?>[
        '42', // int4
        '-0', // float8 negative zero
        'NaN', // numeric NaN
        'Infinity', // float8
        '12345678901234567890.000000000001', // numeric
        't', // bool
        r'\x00ff10', // bytea, hex output
        '2026-10-18 10:00:00+00', // timestamptz in UTC
        '0044-03-15 00:00:00 BC', // timestamp BC
        '1 year 2 mons 3 days 04:05:06', // interval
        '{1,2,NULL}', // int[]
        r'{"a b","c\"d",NULL,"NULL"}', // text[] with quoting
        r'{"x":"a\nb"}', // json with an escaped newline (two characters)
        '(1,"two words")', // composite
        '[1,10)', // int4range
        'café \u{1F600}', // UTF-8, astral plane included
      ];
      expect(
        encodeCopyTextRow(row),
        [
          '42',
          '-0',
          'NaN',
          'Infinity',
          '12345678901234567890.000000000001',
          't',
          r'\\x00ff10',
          '2026-10-18 10:00:00+00',
          '0044-03-15 00:00:00 BC',
          '1 year 2 mons 3 days 04:05:06',
          '{1,2,NULL}',
          r'{"a b","c\\"d",NULL,"NULL"}',
          r'{"x":"a\\nb"}',
          '(1,"two words")',
          '[1,10)',
          'café \u{1F600}',
        ].tabbed,
      );
    });

    test('CopyTextEncoder converts like encodeCopyTextRow', () {
      expect(const CopyTextEncoder().convert(['a', null]), 'a\t\\N\n');
    });

    test('a row of no columns is an empty line', () {
      expect(encodeCopyTextRow(const []), '\n');
    });
  });

  group('decodeCopyTextRow', () {
    test('reverses encodeCopyTextRow', () {
      final values = <String?>[
        null,
        '',
        r'\N',
        r'\.',
        'tab\there',
        'nl\nhere\r\n',
        '\b\f\v',
        r'\x0102',
        '\u{1F600} \\ end',
      ];
      final line = encodeCopyTextRow(values);
      expect(decodeCopyTextRow(line.substring(0, line.length - 1)), values);
    });

    test('reads octal and hex escapes as UTF-8 bytes', () {
      expect(decodeCopyTextRow(r'\101\x42\303\251'), ['ABé']);
      expect(decodeCopyTextRow(r'\7'), ['\u0007']);
    });

    test('an escaped character that has no meaning is itself', () {
      expect(decodeCopyTextRow(r'\q\,'), ['q,']);
    });
  });
}

extension on List<String> {
  /// The fields as one COPY line.
  String get tabbed => '${join('\t')}\n';
}
