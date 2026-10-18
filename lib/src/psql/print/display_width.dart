// File: display_width.dart
// Purpose: Terminal display width of text the way psql measures it, and
// the formatting psql applies to a cell before printing it (newlines split
// lines, tabs expand, control characters become escapes).
//
// Ported from src/common/wchar.c (ucs_wcwidth) and src/fe_utils/mbprint.c
// (pg_wcssize, pg_wcsformat) and print.c (strlen_max_width) - PostgreSQL
// License, (c) 1996-2026 PostgreSQL Global Development Group. See
// THIRD_PARTY_NOTICES.

import 'package:dbase_postgresql/src/psql/print/unicode_width_tables.dart';

/// Display columns code point [rune] takes in a terminal, as psql's
/// `ucs_wcwidth`: 0 for NUL and non-spacing marks, -1 for control
/// characters, 2 for East Asian wide and full-width characters (CJK,
/// most emoji), else 1.
int runeWidth(int rune) {
  if (rune == 0) return 0;
  if (rune < 0x20 || (rune >= 0x7f && rune < 0xa0) || rune > 0x10ffff) {
    return -1;
  }
  if (_inRanges(rune, nonSpacingRanges)) return 0;
  if (_inRanges(rune, wideRanges)) return 2;
  return 1;
}

/// Display width of [text] on one line (control characters count as 0
/// here; use [measureCell] for psql's cell rules).
int displayWidth(String text) {
  var width = 0;
  for (final rune in text.runes) {
    final w = runeWidth(rune);
    if (w > 0) width += w;
  }
  return width;
}

bool _inRanges(int rune, List<int> ranges) {
  final count = ranges.length ~/ 2;
  if (rune < ranges[0] || rune > ranges[ranges.length - 1]) return false;
  var low = 0;
  var high = count - 1;
  while (low <= high) {
    final mid = (low + high) >> 1;
    if (rune > ranges[mid * 2 + 1]) {
      low = mid + 1;
    } else if (rune < ranges[mid * 2]) {
      high = mid - 1;
    } else {
      return true;
    }
  }
  return false;
}

/// The size of a cell as psql computes it (`pg_wcssize`).
final class CellSize {
  /// Creates a size.
  const CellSize(this.width, this.height);

  /// Widest line, in display columns.
  final int width;

  /// Number of lines (1 + newlines).
  final int height;
}

/// One display line of a formatted cell.
final class CellLine {
  /// Creates a line.
  const CellLine(this.text, this.width);

  /// The text to print.
  final String text;

  /// Its display width.
  final int width;
}

/// Width and height of [text] as psql prints it in a cell.
CellSize measureCell(String text) {
  var width = 0;
  var lineWidth = 0;
  var height = 1;
  for (final rune in text.runes) {
    if (rune == 0x0A) {
      if (lineWidth > width) width = lineWidth;
      lineWidth = 0;
      height++;
    } else {
      lineWidth = _advance(rune, lineWidth);
    }
  }
  if (lineWidth > width) width = lineWidth;
  return CellSize(width, height);
}

/// Splits [text] into display lines with psql's escapes: `\r` for CR,
/// tabs expanded to the next multiple of 8, other ASCII controls as
/// `\xNN` and non-ASCII controls as `\uNNNN`.
List<CellLine> formatCell(String text) {
  final lines = <CellLine>[];
  final buffer = StringBuffer();
  var lineWidth = 0;
  for (final rune in text.runes) {
    if (rune == 0x0A) {
      lines.add(CellLine(buffer.toString(), lineWidth));
      buffer.clear();
      lineWidth = 0;
      continue;
    }
    final w = runeWidth(rune);
    if (rune == 0x0D) {
      buffer.write(r'\r');
      lineWidth += 2;
    } else if (rune == 0x09) {
      do {
        buffer.write(' ');
        lineWidth++;
      } while (lineWidth % 8 != 0);
    } else if (w < 0) {
      if (rune < 0x80) {
        buffer.write('\\x${_hex(rune, 2)}');
        lineWidth += 4;
      } else {
        buffer.write('\\u${_hex(rune, 4)}');
        lineWidth += 6;
      }
    } else {
      buffer.writeCharCode(rune);
      lineWidth += w;
    }
  }
  lines.add(CellLine(buffer.toString(), lineWidth));
  return lines;
}

int _advance(int rune, int lineWidth) {
  if (rune == 0x0D) return lineWidth + 2;
  if (rune == 0x09) {
    var w = lineWidth;
    do {
      w++;
    } while (w % 8 != 0);
    return w;
  }
  final w = runeWidth(rune);
  if (w < 0) return lineWidth + (rune < 0x80 ? 4 : 6);
  return lineWidth + w;
}

String _hex(int value, int digits) =>
    value.toRadixString(16).toUpperCase().padLeft(digits, '0');

/// psql's `strlen_max_width`: how much of [text] from [start] fits in
/// [targetWidth] columns. Returns the end index (UTF-16) and the width
/// used. The first character is always taken, even when wider.
(int end, int width) takeWidth(String text, int start, int targetWidth) {
  var width = 0;
  var i = start;
  while (i < text.length) {
    final unit = text.codeUnitAt(i);
    final isPair = unit >= 0xD800 && unit <= 0xDBFF && i + 1 < text.length;
    final rune = isPair
        ? 0x10000 + ((unit - 0xD800) << 10) + (text.codeUnitAt(i + 1) - 0xDC00)
        : unit;
    final w = runeWidth(rune);
    if (targetWidth < width + w && width != 0) break;
    width += w;
    i += isPair ? 2 : 1;
  }
  return (i, width);
}
