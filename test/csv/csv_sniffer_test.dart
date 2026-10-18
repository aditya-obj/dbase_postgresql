// File: csv_sniffer_test.dart
// Purpose: sniffCsv: delimiter, header, encoding (BOM, UTF-16 without BOM,
// invalid UTF-8 → Windows-1252), Excel's sep= line, notes and confidence.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dbase_postgresql/csv.dart';
import 'package:test/test.dart';

CsvSniff sniff(
  String text, {
  bool complete = true,
  Iterable<String> known = const [],
}) => sniffCsv(
  Uint8List.fromList(utf8.encode(text)),
  complete: complete,
  knownColumns: known,
);

void main() {
  group('delimiter', () {
    for (final (name, d) in [
      ('comma', ','),
      ('semicolon', ';'),
      ('tab', '\t'),
      ('pipe', '|'),
    ]) {
      test(name, () {
        final s = sniff('id${d}name${d}price\n1${d}a${d}2.5\n2${d}b${d}3\n');
        expect(s.dialect.delimiter, d);
        expect(s.columnCount, 3);
        expect(s.confidence, greaterThanOrEqualTo(0.6));
      });
    }

    test('commas inside quotes do not fool a semicolon file', () {
      final s = sniff('a;b\n"1,5";"2,5"\n"3,1";"4,2"\n');
      expect(s.dialect.delimiter, ';');
    });

    test("Excel's sep= line decides", () {
      final s = sniff('sep=|\na|b\n1|2\n');
      expect(s.dialect.delimiter, '|');
      expect(s.hadExcelSepLine, isTrue);
      expect(s.confidence, 1);
    });

    test('a single column has low confidence', () {
      final s = sniff('name\nalice\nbob\n');
      expect(s.columnCount, 1);
      expect(s.confidence, lessThan(0.6));
    });
  });

  group('header', () {
    test('names above typed values', () {
      final s = sniff('id,created\n1,2026-01-02\n2,2026-01-03\n');
      expect(s.dialect.hasHeader, isTrue);
      expect(s.headerNames, ['id', 'created']);
    });

    test('a numeric first row is data', () {
      final s = sniff('1,2\n3,4\n');
      expect(s.dialect.hasHeader, isFalse);
      expect(s.headerNames, ['column1', 'column2']);
    });

    test('names matching the table columns', () {
      final s = sniff('ID,Qty\n1,2\n', known: ['id', 'qty']);
      expect(s.dialect.hasHeader, isTrue);
    });

    test('duplicate or empty names are not a header', () {
      expect(sniff('a,a\n1,2\n').dialect.hasHeader, isFalse);
      expect(sniff('a,\n1,2\n').dialect.hasHeader, isFalse);
    });
  });

  group('encoding', () {
    test('UTF-8 with BOM', () {
      final s = sniffCsv(
        Uint8List.fromList([0xEF, 0xBB, 0xBF, ...utf8.encode('a,b\n1,2\n')]),
        complete: true,
      );
      expect(s.encoding, CsvTextEncoding.utf8);
      expect(s.hadBom, isTrue);
      expect(s.headerNames, ['a', 'b']);
    });

    test('UTF-16 LE with BOM (Excel "Unicode text")', () {
      final units = '﻿a\tb\n1\t2\n'.codeUnits;
      final s = sniffCsv(
        Uint8List.fromList([
          for (final u in units) ...[u & 0xFF, u >> 8],
        ]),
        complete: true,
      );
      expect(s.encoding, CsvTextEncoding.utf16le);
      expect(s.hadBom, isTrue);
      expect(s.dialect.delimiter, '\t');
    });

    test('UTF-16 BE without BOM', () {
      final units = 'a,b\n1,2\n'.codeUnits;
      final s = sniffCsv(
        Uint8List.fromList([
          for (final u in units) ...[u >> 8, u & 0xFF],
        ]),
        complete: true,
      );
      expect(s.encoding, CsvTextEncoding.utf16be);
      expect(s.notes, contains(CsvSniffNote.utf16WithoutBom));
    });

    test('invalid UTF-8 is read as Windows-1252', () {
      final s = sniffCsv(
        Uint8List.fromList([...utf8.encode('name\n'), 0x80, 0x0A]),
        complete: true,
      );
      expect(s.encoding, CsvTextEncoding.windows1252);
      expect(s.notes, contains(CsvSniffNote.notUtf8));
    });

    test('a UTF-8 sequence cut at the end of the sample is still UTF-8', () {
      final bytes = utf8.encode('a,b\n1,é');
      final s = sniffCsv(
        Uint8List.fromList(bytes.sublist(0, bytes.length - 1)),
      );
      expect(s.encoding, CsvTextEncoding.utf8);
    });
  });

  group('notes', () {
    test('inconsistent field counts and mixed line ends', () {
      final s = sniff('a,b\r\n1,2\n3\n');
      expect(
        s.notes,
        containsAll([
          CsvSniffNote.inconsistentFieldCounts,
          CsvSniffNote.mixedLineEndings,
        ]),
      );
      expect(s.columnCount, 2);
    });

    test('an empty file', () {
      final s = sniff('');
      expect(s.notes, [CsvSniffNote.empty]);
      expect(s.confidence, 0);
    });

    test('a cut last line is ignored in an incomplete sample', () {
      final s = sniff('a,b\n1,2\n3,4\n5', complete: false);
      expect(s.notes, isNot(contains(CsvSniffNote.inconsistentFieldCounts)));
    });
  });
}
