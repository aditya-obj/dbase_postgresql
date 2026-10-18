// File: copy_csv_test.dart
// Purpose: The PostgreSQL CSV encoder (NULL vs "", quoting, \., line
// counts, chunks), a decode → encode → decode round trip, the COPY and
// INSERT ... unnest SQL, and text[] literals.

import 'dart:convert';

import 'package:dbase_postgresql/csv.dart';
import 'package:test/test.dart';

String encode(List<List<String?>> records) {
  final w = CopyCsvWriter();
  records.forEach(w.add);
  return utf8.decode(w.takeBytes());
}

void main() {
  group('CopyCsvWriter', () {
    test('NULL is unquoted empty, an empty string is ""', () {
      expect(
        encode([
          ['a', null, ''],
        ]),
        'a,,""\n',
      );
    });

    test('quotes only when needed', () {
      expect(
        encode([
          ['x,y', 'say "hi"', 'two\nlines', 'cr\r', ' pad', 'tab\t', 'plain'],
        ]),
        '"x,y","say ""hi""","two\nlines","cr\r"," pad","tab\t",plain\n',
      );
    });

    test(r'a value equal to \. is quoted', () {
      expect(
        encode([
          [r'\.', r'\.x'],
        ]),
        '"\\.",\\.x\n',
      );
    });

    test('unicode is UTF-8', () {
      final w = CopyCsvWriter()..add(['é😀']);
      expect(w.takeBytes(), utf8.encode('é😀\n'));
    });

    test('line counts include line feeds in values', () {
      final w = CopyCsvWriter();
      expect(w.add(['a']), 1);
      expect(w.add(['b\nc\nd', 'e']), 3);
      expect(w.lines, 4);
      expect(w.records, 2);
      w.takeBytes();
      expect(w.lines, 0);
      expect(w.length, 0);
    });

    test('decode → fieldValue → encode → decode keeps every value', () {
      const source =
          'a,b,c\r\n1,,""\r\n"x ""q"", y","multi\nline","  sp "\r\n'
          '\\.,"\\.",é\r\n';
      const dialect = CsvDialect(hasHeader: false);
      final first = CsvDecoder(dialect).convert(utf8.encode(source));
      final values = [
        for (final r in first) [for (var i = 0; i < 3; i++) fieldValue(r, i)],
      ];
      final again = CsvDecoder(dialect).convert(utf8.encode(encode(values)));
      expect([
        for (final r in again) [for (var i = 0; i < 3; i++) fieldValue(r, i)],
      ], values);
      expect(values[1], ['1', null, '']);
      expect(values[3], [r'\.', r'\.', 'é']);
    });
  });

  group('CopyCsvEncoder', () {
    test('chunks hold whole records and say which', () async {
      final chunks = await Stream.fromIterable([
        for (var i = 0; i < 10; i++) ['row$i', null],
      ]).transform(CopyCsvEncoder(chunkSize: 20)).toList();
      expect(chunks.length, greaterThan(1));
      expect(chunks.first.firstRecord, 0);
      expect(chunks.last.lastRecord, 9);
      for (var i = 1; i < chunks.length; i++) {
        expect(chunks[i].firstRecord, chunks[i - 1].lastRecord + 1);
      }
      final text = chunks.map((c) => utf8.decode(c.bytes)).join();
      expect('\n'.allMatches(text).length, 10);
    });

    test('no records, no chunks', () async {
      expect(
        await const Stream<List<String?>>.empty()
            .transform(CopyCsvEncoder())
            .toList(),
        isEmpty,
      );
    });
  });

  group('copyFromStdinSql', () {
    test('every name quoted', () {
      expect(
        copyFromStdinSql('public', 'Order "x"', [
          'id',
          'Name',
        ], serverVersionNum: 130000),
        'COPY "public"."Order ""x""" ("id", "Name") FROM STDIN (FORMAT csv)',
      );
    });

    test('ON_ERROR ignore needs 17, REJECT_LIMIT needs 18', () {
      expect(
        copyFromStdinSql(
          's',
          't',
          ['a'],
          serverVersionNum: 170000,
          onError: CopyOnError.ignore,
        ),
        endsWith('(FORMAT csv, ON_ERROR ignore, LOG_VERBOSITY verbose)'),
      );
      expect(
        copyFromStdinSql(
          's',
          't',
          ['a'],
          serverVersionNum: 180000,
          onError: CopyOnError.ignore,
          rejectLimit: 5,
        ),
        endsWith('LOG_VERBOSITY verbose, REJECT_LIMIT 5)'),
      );
      expect(
        () => copyFromStdinSql(
          's',
          't',
          ['a'],
          serverVersionNum: 160000,
          onError: CopyOnError.ignore,
        ),
        throwsArgumentError,
      );
      expect(
        () => copyFromStdinSql(
          's',
          't',
          ['a'],
          serverVersionNum: 180000,
          rejectLimit: 5,
        ),
        throwsArgumentError,
      );
    });

    test('no columns or a bad name is refused', () {
      expect(
        () => copyFromStdinSql('s', 't', [], serverVersionNum: 170000),
        throwsArgumentError,
      );
      expect(
        () => copyFromStdinSql('s', '', ['a'], serverVersionNum: 170000),
        throwsArgumentError,
      );
      expect(
        () => copyFromStdinSql('s', 't', ['a\u0000'], serverVersionNum: 1),
        throwsArgumentError,
      );
    });
  });

  group('insertFromUnnestSql', () {
    test('one text[] parameter per column, cast to the column type', () {
      expect(
        insertFromUnnestSql(
          'public',
          't',
          ['id', 'price'],
          ['integer', 'numeric(10,2)'],
        ),
        'INSERT INTO "public"."t" ("id", "price") '
        'SELECT CAST(u.c1 AS integer), CAST(u.c2 AS numeric(10,2)) '
        r'FROM unnest($1::text[], $2::text[]) AS u(c1, c2)',
      );
    });

    test('types must match columns', () {
      expect(
        () => insertFromUnnestSql('s', 't', ['a'], []),
        throwsArgumentError,
      );
    });
  });

  group('pgArrayLiteral', () {
    test('elements quoted and escaped, null is NULL', () {
      expect(
        pgArrayLiteral(['a', 'b c', null, 'x"y', r'back\slash', 'NULL', '']),
        r'{"a","b c",NULL,"x\"y","back\\slash","NULL",""}',
      );
    });

    test('empty', () {
      expect(pgArrayLiteral(const []), '{}');
    });
  });
}
