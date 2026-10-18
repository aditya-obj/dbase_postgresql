// File: vertical_printer.dart
// Purpose: psql's expanded output (`\x`): one `-[ RECORD n ]-` block per
// row, column names on the left and values on the right, wrapped to the
// target width in the wrapped format.
//
// Ported from src/fe_utils/print.c (print_aligned_vertical,
// print_aligned_vertical_line; ASCII style, xheader_width full) -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

import 'package:dbase_postgresql/src/psql/print/display_width.dart';
import 'package:dbase_postgresql/src/psql/print/print_table.dart';

/// Writes [table] in psql's expanded layout to [out].
void printAlignedVertical(
  PrintTable table,
  PrintOptions options,
  StringBuffer out,
) {
  final border = options.effectiveBorder;
  final colCount = table.headers.length;

  if (table.rows.isEmpty) {
    if (!options.tuplesOnly) {
      table.footersWithDefault(options).forEach(out.writeln);
    }
    out.write('\n');
    return;
  }

  var hwidth = 0;
  var dwidth = 0;
  var hmultiline = false;
  var dmultiline = false;
  for (final header in table.headers) {
    final size = measureCell(header);
    if (size.width > hwidth) hwidth = size.width;
    if (size.height > 1) hmultiline = true;
  }
  for (final row in table.rows) {
    for (final cell in row) {
      final size = measureCell(cell);
      if (size.width > dwidth) dwidth = size.width;
      if (size.height > 1) dmultiline = true;
    }
  }

  if (!options.tuplesOnly && table.title != null) out.writeln(table.title);

  final outputColumns = options.columns;
  if (options.format == PrintFormat.wrapped ||
      options.format == PrintFormat.aligned) {
    var swidth = switch (border) {
      0 => hmultiline ? 2 : 1,
      1 => 3,
      _ => 7,
    };
    if (dmultiline && border < 2) swidth++;

    var rwidth = 0;
    if (!options.tuplesOnly) {
      // 1 + floor(log10(rows)): the digits of the row count.
      rwidth = '${table.rows.length}'.length;
      rwidth += switch (border) {
        0 => 9,
        1 => 12,
        _ => 15,
      };
    }

    int newDwidth;
    for (;;) {
      var width = hwidth + swidth + dwidth;
      if (width < rwidth) width = rwidth;
      if (options.format == PrintFormat.wrapped && outputColumns > 0) {
        var minWidth = hwidth + swidth + 3;
        if (minWidth < rwidth) minWidth = rwidth;
        if (outputColumns >= width) {
          newDwidth = width - hwidth - swidth;
        } else if (outputColumns < minWidth) {
          newDwidth = minWidth - hwidth - swidth;
        } else {
          newDwidth = outputColumns - hwidth - swidth;
        }
      } else {
        newDwidth = width - hwidth - swidth;
      }
      if (newDwidth < dwidth && !dmultiline && border < 2) {
        dmultiline = true;
        swidth++;
      } else {
        break;
      }
    }
    dwidth = newDwidth;
  }

  var record = 1;
  var cellIndex = 0;
  for (final row in table.rows) {
    for (var c = 0; c < colCount; c++, cellIndex++) {
      final position = cellIndex == 0 ? _Pos.top : _Pos.middle;
      if (c == 0) {
        if (!options.tuplesOnly) {
          _recordLine(out, border, record++, hwidth, dwidth, position);
        } else if (cellIndex != 0 || border == 2) {
          _recordLine(out, border, 0, hwidth, dwidth, position);
        }
      }
      _printPair(
        out,
        border: border,
        header: formatCell(table.headers[c]),
        data: formatCell(row[c]),
        hwidth: hwidth,
        dwidth: dwidth,
        hmultiline: hmultiline,
        dmultiline: dmultiline,
      );
    }
  }

  if (border == 2) _recordLine(out, border, 0, hwidth, dwidth, _Pos.bottom);
  final footers = table.footers;
  if (!options.tuplesOnly && footers != null) {
    if (border < 2) out.write('\n');
    footers.forEach(out.writeln);
  }
  out.write('\n');
}

enum _Pos { top, middle, bottom }

/// psql's print_aligned_vertical_line: `-[ RECORD n ]-+-----`.
void _recordLine(
  StringBuffer out,
  int border,
  int record,
  int hwidth,
  int dwidth,
  _Pos position,
) {
  // The ASCII style uses the same characters at every position.
  assert(position.index >= 0, 'position is only for readability');
  if (border == 2) {
    out.write('+-');
  } else if (border == 1) {
    out.write('-');
  }
  var reclen = 0;
  if (record != 0) {
    final label = border == 0 ? '* Record $record' : '[ RECORD $record ]';
    out.write(label);
    reclen = label.length;
  }
  if (border != 2) reclen++;
  for (var i = reclen; i < hwidth; i++) {
    out.write(border > 0 ? '-' : ' ');
  }
  reclen -= hwidth;
  if (border > 0) {
    if (reclen-- <= 0) out.write('-');
    if (reclen-- <= 0) out.write('+');
    if (reclen-- <= 0) out.write('-');
  } else {
    if (reclen-- <= 0) out.write(' ');
  }
  if (reclen < 0) reclen = 0;
  var width = dwidth;
  if (width < reclen) width = reclen;
  for (var i = reclen; i < width; i++) {
    out.write(border > 0 ? '-' : ' ');
  }
  if (border == 2) out.write('-+');
  out.write('\n');
}

void _printPair(
  StringBuffer out, {
  required int border,
  required List<CellLine> header,
  required List<CellLine> data,
  required int hwidth,
  required int dwidth,
  required bool hmultiline,
  required bool dmultiline,
}) {
  var dline = 0;
  var hline = 0;
  var dcomplete = false;
  var hcomplete = false;
  var offset = 0;
  var charsToOutput = data[0].width;
  while (!dcomplete || !hcomplete) {
    if (border == 2) out.write('|');

    if (!hcomplete) {
      if (border == 2) out.write(' ');
      final (_, used) = takeWidth(header[hline].text, 0, hwidth);
      out.write(header[hline].text);
      final pad = hwidth - used;
      if (pad > 0) out.write(' ' * pad);
      if (hline + 1 < header.length) {
        if (border > 0 || hmultiline) out.write('+');
        hline++;
      } else {
        if (border > 0 || hmultiline) out.write(' ');
        hcomplete = true;
      }
    } else {
      var pad = hwidth + border;
      if (border == 0 && hmultiline) pad++;
      // printf("%*s", pad, " ") prints at least the one space.
      out.write(' ' * (pad < 1 ? 1 : pad));
    }

    if (border > 0) {
      // ASCII: wrap, newline and plain separators are all `|`.
      out.write('|');
    }

    if (!dcomplete) {
      out.write(offset == 0 ? ' ' : '.');
      final text = data[dline].text;
      final (end, used) = takeWidth(text, offset, dwidth);
      out.write(text.substring(offset, end));
      charsToOutput -= used;
      offset = end;
      final pad = dwidth - used;
      if (charsToOutput != 0) {
        if (border > 1 || dmultiline) {
          if (pad > 0) out.write(' ' * pad);
          out.write('.');
        }
      } else if (dline + 1 < data.length) {
        if (border > 1 || dmultiline) {
          if (pad > 0) out.write(' ' * pad);
          out.write('+');
        }
        dline++;
        offset = 0;
        charsToOutput = data[dline].width;
      } else {
        if (border > 1) {
          if (pad > 0) out.write(' ' * pad);
          out.write(' ');
        }
        dcomplete = true;
      }
      if (border == 2) out.write('|');
      out.write('\n');
    } else {
      if (border < 2) {
        out.write('\n');
      } else {
        out
          ..write(' ' * dwidth)
          ..write('  |\n');
      }
    }
  }
}
