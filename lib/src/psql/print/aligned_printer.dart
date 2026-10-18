// File: aligned_printer.dart
// Purpose: psql's aligned and wrapped table output (ASCII line style):
// centred headers, `-+-` rules, right-aligned numbers, `+` marks for
// multi-line cells, `.` marks for wrapped ones, then the footers.
//
// Ported from src/fe_utils/print.c (print_aligned_text,
// _print_horizontal_line, pg_asciiformat) - PostgreSQL License,
// (c) 1996-2026 PostgreSQL Global Development Group. See
// THIRD_PARTY_NOTICES.

import 'package:dbase_postgresql/src/psql/print/display_width.dart';
import 'package:dbase_postgresql/src/psql/print/print_table.dart';
import 'package:dbase_postgresql/src/psql/print/vertical_printer.dart';

enum _Rule { top, middle, bottom }

enum _Wrap { none, wrap, newline }

/// Writes [table] in psql's aligned (or wrapped) format to [out].
/// Falls back to the expanded layout when [PrintOptions.expanded] is
/// auto and the table is wider than [PrintOptions.columns].
void printAlignedText(
  PrintTable table,
  PrintOptions options,
  StringBuffer out,
) {
  final border = options.effectiveBorder;
  final colCount = table.headers.length;
  final widthHeader = List.filled(colCount, 0);
  final maxWidth = List.filled(colCount, 0);
  final widthAverage = List.filled(colCount, 0);
  final maxLines = List.filled(colCount, 0);

  for (var i = 0; i < colCount; i++) {
    final size = measureCell(table.headers[i]);
    if (size.width > maxWidth[i]) maxWidth[i] = size.width;
    if (size.height > maxLines[i]) maxLines[i] = size.height;
    widthHeader[i] = size.width;
  }
  for (final row in table.rows) {
    for (var i = 0; i < colCount; i++) {
      final size = measureCell(row[i]);
      if (size.width > maxWidth[i]) maxWidth[i] = size.width;
      if (size.height > maxLines[i]) maxLines[i] = size.height;
      widthAverage[i] += size.width;
    }
  }
  if (colCount != 0 && table.rows.isNotEmpty) {
    for (var i = 0; i < colCount; i++) {
      widthAverage[i] ~/= table.rows.length;
    }
  }

  var widthTotal = switch (border) {
    0 => colCount,
    1 => colCount * 3 - (colCount > 0 ? 1 : 0),
    _ => colCount * 3 + 1,
  };
  var totalHeaderWidth = widthTotal;
  for (var i = 0; i < colCount; i++) {
    widthTotal += maxWidth[i];
    totalHeaderWidth += widthHeader[i];
  }

  final widthWrap = [...maxWidth];
  final outputColumns = options.columns;

  if (options.format == PrintFormat.wrapped &&
      outputColumns > 0 &&
      outputColumns >= totalHeaderWidth) {
    // Shrink the column with the highest max/average ratio, one column
    // at a time, until the table fits.
    while (widthTotal > outputColumns) {
      var maxRatio = 0.0;
      var worst = -1;
      for (var i = 0; i < colCount; i++) {
        if (widthAverage[i] != 0 && widthWrap[i] > widthHeader[i]) {
          final ratio = widthWrap[i] / widthAverage[i] + maxWidth[i] * 0.01;
          if (ratio > maxRatio) {
            maxRatio = ratio;
            worst = i;
          }
        }
      }
      if (worst == -1) break;
      widthWrap[worst]--;
      widthTotal--;
    }
  }

  if (options.expanded == ExpandedMode.auto &&
      !table.forceNotExpanded &&
      outputColumns > 0 &&
      colCount > 1 &&
      (outputColumns < totalHeaderWidth || outputColumns < widthTotal)) {
    printAlignedVertical(table, options, out);
    return;
  }

  // Title.
  final title = table.title;
  if (title != null && !options.tuplesOnly) {
    final width = measureCell(title).width;
    if (width >= widthTotal) {
      out.writeln(title);
    } else {
      out
        ..write(' ' * ((widthTotal - width) ~/ 2))
        ..writeln(title);
    }
  }

  // Headers.
  if (!options.tuplesOnly) {
    if (border == 2) _rule(out, widthWrap, border, _Rule.top);
    final lines = [for (final h in table.headers) formatCell(h)];
    final done = List.filled(colCount, false);
    var remaining = colCount;
    var line = 0;
    while (remaining > 0) {
      if (border == 2) out.write('|');
      for (var i = 0; i < colCount; i++) {
        // The ASCII header newline mark on the left is a space too.
        if (border != 0) out.write(' ');
        if (!done[i]) {
          final cell = lines[i][line];
          final spaces = widthWrap[i] - cell.width;
          out
            ..write(' ' * (spaces ~/ 2))
            ..write(cell.text)
            ..write(' ' * ((spaces + 1) ~/ 2));
          if (line + 1 >= lines[i].length) {
            remaining--;
            done[i] = true;
          }
        } else {
          out.write(' ' * widthWrap[i]);
        }
        out.write(!done[i] ? '+' : ' ');
        if (border != 0 && i < colCount - 1) out.write('|');
      }
      line++;
      if (border == 2) out.write('|');
      out.write('\n');
    }
    _rule(out, widthWrap, border, _Rule.middle);
  }

  // Rows.
  for (final row in table.rows) {
    _printRow(out, table, row, widthWrap, border);
  }

  // Footers.
  if (border == 2) _rule(out, widthWrap, border, _Rule.bottom);
  if (!options.tuplesOnly) {
    table.footersWithDefault(options).forEach(out.writeln);
  }
  out.write('\n');
}

void _printRow(
  StringBuffer out,
  PrintTable table,
  List<String> row,
  List<int> widthWrap,
  int border,
) {
  final colCount = table.headers.length;
  final lines = [for (final cell in row) formatCell(cell)];
  final currentLine = List.filled(colCount, 0);
  final offset = List.filled(colCount, 0);
  final wrap = List.filled(colCount, _Wrap.none);

  CellLine? lineAt(int column) {
    final index = currentLine[column];
    return index < lines[column].length ? lines[column][index] : null;
  }

  bool moreLines;
  do {
    moreLines = false;
    if (border == 2) out.write('|');
    for (var j = 0; j < colCount; j++) {
      final thisLine = lineAt(j);
      var charsToOutput = widthWrap[j];
      final finalSpaces = border == 2 || j < colCount - 1;

      if (border != 0) {
        out.write(switch (wrap[j]) {
          _Wrap.wrap => '.',
          _Wrap.newline || _Wrap.none => ' ',
        });
      }

      if (thisLine == null) {
        if (finalSpaces) out.write(' ' * charsToOutput);
      } else {
        final (end, width) = takeWidth(thisLine.text, offset[j], widthWrap[j]);
        charsToOutput = width > widthWrap[j] ? widthWrap[j] : width;
        final piece = thisLine.text.substring(offset[j], end);
        if (table.aligns[j] == PrintAlign.right) {
          out
            ..write(' ' * (widthWrap[j] - charsToOutput))
            ..write(piece);
        } else {
          out.write(piece);
        }
        offset[j] = end;
        if (end < thisLine.text.length) {
          moreLines = true;
        } else {
          currentLine[j]++;
          if (lineAt(j) != null) moreLines = true;
          offset[j] = 0;
        }
      }

      wrap[j] = _Wrap.none;
      if (lineAt(j) != null) {
        if (offset[j] != 0) {
          wrap[j] = _Wrap.wrap;
        } else if (currentLine[j] != 0) {
          wrap[j] = _Wrap.newline;
        }
      }

      if (table.aligns[j] != PrintAlign.right) {
        if (finalSpaces || wrap[j] != _Wrap.none) {
          out.write(' ' * (widthWrap[j] - charsToOutput));
        }
      }

      if (wrap[j] == _Wrap.wrap) {
        out.write('.');
      } else if (wrap[j] == _Wrap.newline) {
        out.write('+');
      } else if (border == 2 || j < colCount - 1) {
        out.write(' ');
      }

      // Column divider (ASCII style uses `|` for every kind).
      if (border != 0 && j < colCount - 1) out.write('|');
    }
    if (border == 2) out.write('|');
    out.write('\n');
  } while (moreLines);
}

void _rule(StringBuffer out, List<int> widths, int border, _Rule position) {
  if (border == 1) {
    out.write('-');
  } else if (border == 2) {
    out.write('+-');
  }
  for (var i = 0; i < widths.length; i++) {
    out.write('-' * widths[i]);
    if (i < widths.length - 1) {
      out.write(border == 0 ? ' ' : '-+-');
    }
  }
  if (border == 2) {
    out.write('-+');
  } else if (border == 1) {
    out.write('-');
  }
  out.write('\n');
  // The ASCII style uses the same characters for every rule position.
  assert(position.index >= 0, 'position is only for readability');
}
