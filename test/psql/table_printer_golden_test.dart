// File: table_printer_golden_test.dart
// Purpose: Golden-text tests for the psql table printer. Each file in
// test/psql/goldens/ is real psql 17 output (tool: the script in the file
// header of test/psql/goldens/README.md) for the same rows built here.

import 'dart:io';

import 'package:dbase_postgresql/psql.dart';
import 'package:test/test.dart';

const _int4 = 23;
const _text = 25;
const _numeric = 1700;

PrintTable _basic(String nullDisplay, {String? title}) => PrintTable.fromResult(
  columns: const ['id', 'name', 'amount'],
  typeOids: const [_int4, _text, _numeric],
  rows: const [
    ['1', 'alpha', '1.5'],
    ['22', 'b', null],
    ['333', 'gamma ray', '-2.25'],
  ],
  nullDisplay: nullDisplay,
  title: title,
);

final _unicode = PrintTable.fromResult(
  columns: const ['name', 'cjk', 'emoji', 'combining'],
  typeOids: const [_text, _text, _text, _text],
  rows: const [
    ['héllo', '日本語', '👍x', 'é'],
  ],
);

final _multiline = PrintTable.fromResult(
  columns: const ['multi', 'b', 'n'],
  typeOids: const [_text, _text, _int4],
  rows: const [
    ['line1\nline two\nl3', 'x', '7'],
  ],
);

const _fox =
    'The quick brown fox jumps over the lazy dog and keeps running far away';

final _wide = PrintTable.fromResult(
  columns: const ['id', 'description', 'tag'],
  typeOids: const [_int4, _text, _text],
  rows: const [
    ['1', _fox, 'short'],
  ],
);

final _control = PrintTable.fromResult(
  columns: const ['tab', 'cr', 'ctl'],
  typeOids: const [_text, _text, _text],
  rows: const [
    ['a\tb', 'cr\rhere', '\u0001z'],
  ],
);

final _empty = PrintTable.fromResult(
  columns: const ['a', 'b'],
  typeOids: const [_int4, _text],
  rows: const [],
);

final _one = PrintTable.fromResult(
  columns: const ['answer'],
  typeOids: const [_int4],
  rows: const [
    ['42'],
  ],
);

String _golden(String name) =>
    File('test/psql/goldens/$name.txt').readAsStringSync();

void main() {
  const aligned = PrintOptions();
  const expanded = PrintOptions(expanded: ExpandedMode.on);

  final cases = <String, (PrintTable, PrintOptions)>{
    'aligned_basic': (_basic(''), aligned),
    'aligned_one_row': (_one, aligned),
    'aligned_null': (_basic('(null)'), aligned),
    'aligned_border0': (_basic(''), const PrintOptions(border: 0)),
    'aligned_border2': (_basic(''), const PrintOptions(border: 2)),
    'aligned_unicode': (_unicode, aligned),
    'aligned_multiline': (_multiline, aligned),
    'aligned_multiline_border2': (_multiline, const PrintOptions(border: 2)),
    'aligned_multiline_border0': (_multiline, const PrintOptions(border: 0)),
    'aligned_control': (_control, aligned),
    'aligned_empty': (_empty, aligned),
    'aligned_title': (_basic('', title: 'My report'), aligned),
    'aligned_no_footer': (_basic(''), const PrintOptions(defaultFooter: false)),
    'tuples_only': (_basic(''), const PrintOptions(tuplesOnly: true)),
    'wrapped_40': (
      _wide,
      const PrintOptions(format: PrintFormat.wrapped, columns: 40),
    ),
    'wrapped_40_border2': (
      _wide,
      const PrintOptions(format: PrintFormat.wrapped, columns: 40, border: 2),
    ),
    'expanded_basic': (_basic(''), expanded),
    'expanded_null': (_basic('(null)'), expanded),
    'expanded_border0': (
      _basic(''),
      const PrintOptions(expanded: ExpandedMode.on, border: 0),
    ),
    'expanded_border2': (
      _basic(''),
      const PrintOptions(expanded: ExpandedMode.on, border: 2),
    ),
    'expanded_multiline': (_multiline, expanded),
    'expanded_unicode': (_unicode, expanded),
    'expanded_empty': (_empty, expanded),
    'expanded_wrapped_30': (
      _wide,
      const PrintOptions(
        expanded: ExpandedMode.on,
        format: PrintFormat.wrapped,
        columns: 30,
      ),
    ),
    'expanded_auto_narrow': (
      _wide,
      const PrintOptions(expanded: ExpandedMode.auto, columns: 30),
    ),
    'expanded_auto_wide': (
      _wide,
      const PrintOptions(expanded: ExpandedMode.auto, columns: 200),
    ),
    'unaligned_basic': (
      _basic(''),
      const PrintOptions(format: PrintFormat.unaligned),
    ),
    'unaligned_expanded': (
      _basic(''),
      const PrintOptions(
        format: PrintFormat.unaligned,
        expanded: ExpandedMode.on,
      ),
    ),
    'csv_basic': (_multiline, const PrintOptions(format: PrintFormat.csv)),
    'csv_expanded': (
      _basic(''),
      const PrintOptions(format: PrintFormat.csv, expanded: ExpandedMode.on),
    ),
  };

  group('printTable matches psql', () {
    for (final MapEntry(key: name, value: (table, options)) in cases.entries) {
      test(name, () {
        expect(printTable(table, options), _golden(name));
      });
    }
  });

  test('every golden file has a case', () {
    final files = Directory('test/psql/goldens')
        .listSync()
        .map((f) => f.uri.pathSegments.last)
        .where((n) => n.endsWith('.txt'))
        .map((n) => n.substring(0, n.length - 4))
        .toSet();
    expect(files, cases.keys.toSet());
  });

  group('display width', () {
    test('CJK and emoji take two columns, combining marks none', () {
      expect(displayWidth('日本語'), 6);
      expect(displayWidth('👍'), 2);
      expect(displayWidth('é'), 1);
      expect(runeWidth(0x07), -1);
    });

    test('cells escape control characters like psql', () {
      final lines = formatCell('a\tb\r\u0001\u0085');
      expect(lines.single.text, r'a       b\r\x01\u0085');
      expect(lines.single.width, 9 + 2 + 4 + 6);
      expect(measureCell('ab\nabcd').height, 2);
      expect(measureCell('ab\nabcd').width, 4);
    });
  });

  test('numeric types are right-aligned like psql', () {
    expect(alignmentForType(_int4), PrintAlign.right);
    expect(alignmentForType(_numeric), PrintAlign.right);
    expect(alignmentForType(_text), PrintAlign.left);
  });
}
