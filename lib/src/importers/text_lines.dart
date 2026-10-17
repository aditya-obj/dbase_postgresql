// File: text_lines.dart
// Purpose: Splits an imported text file into lines the way libpq's fgets()
// loops see them (internal, not exported).

/// The byte order mark some Windows editors write at the start of a file.
const byteOrderMark = '\uFEFF';

/// One physical line of an imported file.
final class TextLine {
  /// Creates a line.
  const TextLine({
    required this.number,
    required this.text,
    required this.offset,
    required this.hasNewline,
  });

  /// One-based line number.
  final int number;

  /// The line without its terminating `\n` (a `\r` before it is kept; each
  /// format strips it the way libpq does).
  final String text;

  /// Offset of [text] in the source, after any stripped byte order mark.
  final int offset;

  /// Whether the line ended with `\n` (the last line may not).
  final bool hasNewline;
}

/// Splits [source] at `\n` only, like `fgets()`. A lone `\r` stays inside
/// the line. A final empty line after a trailing `\n` is not returned.
///
/// A leading byte order mark is dropped (libpq would treat it as part of
/// the first line); `bomStripped` reports whether one was.
({List<TextLine> lines, bool bomStripped}) splitTextLines(String source) {
  final bom = source.startsWith(byteOrderMark);
  final lines = <TextLine>[];
  var start = bom ? 1 : 0;
  var number = 1;
  while (start < source.length) {
    final end = source.indexOf('\n', start);
    final hasNewline = end >= 0;
    final stop = hasNewline ? end : source.length;
    lines.add(
      TextLine(
        number: number++,
        text: source.substring(start, stop),
        offset: start,
        hasNewline: hasNewline,
      ),
    );
    start = stop + 1;
  }
  return (lines: lines, bomStripped: bom);
}

/// Whether [unit] is whitespace for C's `isspace()` in the C locale:
/// space, `\t`, `\n`, `\v`, `\f` or `\r`.
bool isCSpace(int unit) => unit == 0x20 || (unit >= 0x09 && unit <= 0x0D);

/// The UTF-8 length of [text] in bytes, as libpq's `strlen()` sees it.
/// Unpaired surrogates count as three bytes (U+FFFD).
int utf8Length(String text) {
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes += 1;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xD800 &&
        unit <= 0xDBFF &&
        i + 1 < text.length &&
        (text.codeUnitAt(i + 1) & 0xFC00) == 0xDC00) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
  }
  return bytes;
}
