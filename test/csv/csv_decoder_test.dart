// File: csv_decoder_test.dart
// Purpose: CsvDecoder against RFC 4180 examples and the lenient rules:
// quotes, NULL vs empty string, line ends, BOM, Excel's sep= line, line
// numbers, chunk boundaries, encodings and limits.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dabase_postgresql/csv.dart';
import 'package:test/test.dart';

List<CsvRecord> decode(
  String text, {
  CsvDialect dialect = const CsvDialect(hasHeader: false),
  CsvLimits limits = const CsvLimits(),
}) => CsvDecoder(dialect, limits: limits).convert(utf8.encode(text));

List<List<String>> fields(String text, {bool header = false}) => [
  for (final r in decode(text, dialect: CsvDialect(hasHeader: header)))
    r.fields,
];

/// Decodes [bytes] fed one byte at a time through the stream API.
Future<List<CsvRecord>> decodeBytewise(
  List<int> bytes, {
  CsvDialect dialect = const CsvDialect(hasHeader: false),
  CsvTextEncoding encoding = CsvTextEncoding.utf8,
}) => Stream.fromIterable([
  for (final b in bytes) [b],
]).transform(CsvDecoder(dialect, encoding: encoding)).toList();

void main() {
  group('RFC 4180', () {
    test('records separated by CRLF, last one without a line break', () {
      expect(fields('aaa,bbb,ccc\r\nzzz,yyy,xxx'), [
        ['aaa', 'bbb', 'ccc'],
        ['zzz', 'yyy', 'xxx'],
      ]);
    });

    test('quoted fields with line breaks, quotes and commas', () {
      expect(fields('"aaa","b\r\nbb","ccc"\r\n"a""b",",",x\r\n'), [
        ['aaa', 'b\r\nbb', 'ccc'],
        ['a"b', ',', 'x'],
      ]);
    });

    test('a trailing comma is an empty last field', () {
      expect(fields('a,b,\n'), [
        ['a', 'b', ''],
      ]);
    });
  });

  group('NULL versus empty string', () {
    test('unquoted empty and quoted empty are told apart', () {
      final r = decode('1,,""\n').single;
      expect(r.fields, ['1', '', '']);
      expect(r.quoted, [false, false, true]);
      expect(fieldValue(r, 1), isNull);
      expect(fieldValue(r, 2), '');
    });

    test('empty field rules and a NULL marker', () {
      final r = decode(
        r'x,,"",\N,"\N"'
        '\n',
      ).single;
      expect(fieldValue(r, 1, empty: EmptyFieldRule.emptyString), '');
      expect(fieldValue(r, 2, empty: EmptyFieldRule.alwaysNull), isNull);
      expect(fieldValue(r, 3, nullMarker: r'\N'), isNull);
      // A quoted marker is text.
      expect(fieldValue(r, 4, nullMarker: r'\N'), r'\N');
      // A field the record doesn't have.
      expect(fieldValue(r, 9), isNull);
    });
  });

  group('lenient parsing', () {
    test('a quote inside an unquoted field is literal', () {
      final r = decode('5" pipe,ok\n').single;
      expect(r.fields, ['5" pipe', 'ok']);
      expect(r.notes, {CsvRecordNote.quoteInUnquotedField});
    });

    test('text after a closing quote is kept', () {
      final r = decode('"abc"def,x\n').single;
      expect(r.fields, ['abcdef', 'x']);
      expect(r.notes, {CsvRecordNote.strayQuote});
    });

    test('LF, CR and CRLF line ends mixed in one file', () {
      expect(fields('a\nb\rc\r\nd'), [
        ['a'],
        ['b'],
        ['c'],
        ['d'],
      ]);
    });

    test('empty lines are skipped', () {
      expect(fields('a\n\n\r\nb\n\n'), [
        ['a'],
        ['b'],
      ]);
    });

    test('a backslash escape character (MySQL style)', () {
      final r = decode(
        r'"a\"b","c\\d"'
        '\n',
        dialect: const CsvDialect(escape: r'\', hasHeader: false),
      ).single;
      expect(r.fields, ['a"b', r'c\d']);
    });

    test('other delimiters', () {
      expect(
        decode(
          'a;b\t;"c;d"\n',
          dialect: const CsvDialect(delimiter: ';', hasHeader: false),
        ).single.fields,
        ['a', 'b\t', 'c;d'],
      );
    });
  });

  group('numbering', () {
    test('the header is number 0, data records count from 1', () {
      final records = decode(
        'id,name\n1,a\n2,b\n',
        dialect: const CsvDialect(),
      );
      expect(records.map((r) => r.number), [0, 1, 2]);
      expect(records.first.isHeader, isTrue);
    });

    test('lines count line breaks inside quoted fields', () {
      final records = decode('a,"x\ny\r\nz"\nb,c\r\n\nd,e\n');
      expect(records.map((r) => r.line), [1, 4, 6]);
    });

    test('byte offsets grow', () {
      final records = decode('a\nb\n');
      expect(records.last.byteOffset, 4);
    });
  });

  group('BOM and sep= line', () {
    test('a UTF-8 byte order mark is stripped', () {
      final bytes = [0xEF, 0xBB, 0xBF, ...utf8.encode('a,b\n')];
      final r = CsvDecoder(const CsvDialect(hasHeader: false)).convert(bytes);
      expect(r.single.fields, ['a', 'b']);
    });

    test("Excel's sep= first line is consumed and still counted", () {
      final r = decode(
        'sep=;\r\na;b\r\n',
        dialect: const CsvDialect(delimiter: ';', hasHeader: false),
      );
      expect(r.single.fields, ['a', 'b']);
      expect(r.single.line, 2);
    });
  });

  group('chunk boundaries', () {
    test('byte-at-a-time input gives the same records', () async {
      const text = 'h1,"h 2"\r\n"multi\r\nline","é ✓ 😀"\r\n"a""b",\r\n"",x';
      final whole = decode(text);
      final split = await decodeBytewise(utf8.encode(text));
      String show(CsvRecord r) => '${r.fields}|${r.quoted}|${r.line}';
      expect(split.map(show), whole.map(show));
      expect(split[1].fields, ['multi\r\nline', 'é ✓ 😀']);
    });
  });

  group('encodings', () {
    test('UTF-16 LE with BOM, split across chunks', () async {
      final units = '﻿a,ü\n€,b\n'.codeUnits;
      final bytes = [
        for (final u in units) ...[u & 0xFF, u >> 8],
      ];
      final r = await decodeBytewise(bytes, encoding: CsvTextEncoding.utf16le);
      expect(r.map((e) => e.fields), [
        ['a', 'ü'],
        ['€', 'b'],
      ]);
    });

    test('UTF-16 BE', () {
      final units = 'x,y\n'.codeUnits;
      final bytes = [
        for (final u in units) ...[u >> 8, u & 0xFF],
      ];
      final r = CsvDecoder(
        const CsvDialect(hasHeader: false),
        encoding: CsvTextEncoding.utf16be,
      ).convert(bytes);
      expect(r.single.fields, ['x', 'y']);
    });

    test('Windows-1252 maps 0x80–0x9F to their characters', () {
      final r = CsvDecoder(
        const CsvDialect(hasHeader: false),
        encoding: CsvTextEncoding.windows1252,
      ).convert([0x80, 0x2C, 0x93, 0x41, 0x94, 0x2C, 0xE9, 0x0A]);
      expect(r.single.fields, ['€', '“A”', 'é']);
    });

    test('Latin-1 is byte = code point', () {
      final r = CsvDecoder(
        const CsvDialect(hasHeader: false),
        encoding: CsvTextEncoding.latin1,
      ).convert([0x80, 0x2C, 0xE9]);
      expect(r.single.fields, ['\u0080', 'é']);
    });

    test('invalid UTF-8 is an error with the line (strict)', () async {
      final bytes = [...utf8.encode('a\nb\n'), 0xC3, 0x28, 0x0A];
      await expectLater(
        Stream.value(bytes)
            .transform(CsvDecoder(const CsvDialect(hasHeader: false))),
        emitsInOrder([
          isA<CsvRecord>(),
          isA<CsvRecord>(),
          emitsError(
            isA<CsvInvalidEncodingException>().having((e) => e.line, 'line', 3),
          ),
          emitsDone,
        ]),
      );
    });

    test('lenient decoding replaces invalid UTF-8', () {
      final r = CsvDecoder(
        const CsvDialect(hasHeader: false),
        strictEncoding: false,
      ).convert([0x61, 0xFF, 0x0A]);
      expect(r.single.fields, ['a�']);
    });
  });

  group('errors', () {
    test('an unterminated quote names the line where the record starts', () {
      expect(
        () => decode('a\nb,"open\nmore\n'),
        throwsA(
          isA<CsvUnterminatedQuoteException>().having((e) => e.line, 'l', 2),
        ),
      );
    });

    test('limits', () {
      const limits = CsvLimits(
        maxFieldBytes: 4,
        maxFields: 3,
        maxRecordBytes: 8,
      );
      expect(
        () => decode('12345\n', limits: limits),
        throwsA(isA<CsvFieldTooLargeException>()),
      );
      expect(
        () => decode('a,b,c,d\n', limits: limits),
        throwsA(isA<CsvTooManyFieldsException>()),
      );
      expect(
        () => decode('1234,1234,1\n', limits: limits),
        throwsA(isA<CsvRecordTooLargeException>()),
      );
    });

    test('the stream ends after the first error', () async {
      final events = <Object>[];
      await Stream<List<int>>.fromIterable([
            utf8.encode('a\n"x'),
            utf8.encode('\n'),
          ])
          .transform(CsvDecoder(const CsvDialect(hasHeader: false)))
          .handleError(events.add)
          .forEach(events.add);
      expect(events, [isA<CsvRecord>(), isA<CsvUnterminatedQuoteException>()]);
    });

    test('an unusable dialect is refused', () {
      expect(
        () => CsvDecoder(const CsvDialect(delimiter: '"')),
        throwsArgumentError,
      );
      expect(
        () => CsvDecoder(const CsvDialect(delimiter: ',,')),
        throwsArgumentError,
      );
    });
  });

  test('decoding is lossless for a typed sample', () {
    final bytes = Uint8List.fromList(utf8.encode('n\n42\n'));
    expect(CsvDecoder(const CsvDialect()).convert(bytes).last.fields, ['42']);
  });
}
