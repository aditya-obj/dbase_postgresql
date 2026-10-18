// File: copy_text.dart
// Purpose: PostgreSQL's COPY text format (the format pg_dump writes and
// psql restores): one row per line, fields separated by TAB, NULL as \N.
// The encoder escapes like CopyAttributeOutText in copyto.c (backslash,
// BS, FF, LF, CR, TAB, VT); values are the server's text output, so this
// is all a type needs. The decoder reverses it (CopyReadAttributesText),
// including octal and hex escapes, for tests and for reading dumps.

import 'dart:convert';

/// Encodes one row as a COPY text line, terminated by `\n`.
///
/// A `null` value is SQL NULL (`\N`); an empty string stays empty.
String encodeCopyTextRow(List<String?> values) {
  final out = StringBuffer();
  for (var i = 0; i < values.length; i++) {
    if (i > 0) out.write('\t');
    final value = values[i];
    if (value == null) {
      out.write(r'\N');
    } else {
      _escapeInto(out, value);
    }
  }
  out.write('\n');
  return out.toString();
}

void _escapeInto(StringBuffer out, String value) {
  var start = 0;
  for (var i = 0; i < value.length; i++) {
    final escaped = switch (value.codeUnitAt(i)) {
      0x5C => r'\\',
      0x08 => r'\b',
      0x0C => r'\f',
      0x0A => r'\n',
      0x0D => r'\r',
      0x09 => r'\t',
      0x0B => r'\v',
      _ => null,
    };
    if (escaped == null) continue;
    if (i > start) out.write(value.substring(start, i));
    out.write(escaped);
    start = i + 1;
  }
  if (start == 0) {
    out.write(value);
  } else if (start < value.length) {
    out.write(value.substring(start));
  }
}

/// A [Converter] from rows to COPY text lines ([encodeCopyTextRow]).
final class CopyTextEncoder extends Converter<List<String?>, String> {
  /// Creates an encoder.
  const CopyTextEncoder();

  @override
  String convert(List<String?> input) => encodeCopyTextRow(input);
}

/// Decodes one COPY text line (without its line ending) into values;
/// `\N` alone is NULL.
///
/// Escapes follow PostgreSQL: `\b \f \n \r \t \v`, octal `\0`–`\777`
/// (one to three digits) and hex `\xh` / `\xhh` give that byte, any other
/// escaped character is itself. Bytes from octal and hex escapes are read
/// as UTF-8, as the server does for a UTF-8 database. Throws a
/// [FormatException] when those bytes are not valid UTF-8.
List<String?> decodeCopyTextRow(String line) {
  final out = <String?>[];
  var fieldStart = 0;
  for (var i = 0; i <= line.length; i++) {
    if (i == line.length || line.codeUnitAt(i) == 0x09) {
      final raw = line.substring(fieldStart, i);
      out.add(raw == r'\N' ? null : _unescape(raw));
      fieldStart = i + 1;
    } else if (line.codeUnitAt(i) == 0x5C) {
      i++; // The escaped character can't end the field.
    }
  }
  return out;
}

String _unescape(String raw) {
  if (!raw.contains(r'\')) return raw;
  final bytes = <int>[];
  void addText(String s) => bytes.addAll(utf8.encode(s));
  var i = 0;
  while (i < raw.length) {
    final backslash = raw.indexOf(r'\', i);
    if (backslash < 0 || backslash + 1 >= raw.length) {
      // Whole runs of text, so surrogate pairs stay together.
      addText(raw.substring(i));
      break;
    }
    if (backslash > i) addText(raw.substring(i, backslash));
    i = backslash;
    final next = raw[i + 1];
    i += 2;
    switch (next) {
      case 'b':
        bytes.add(0x08);
      case 'f':
        bytes.add(0x0C);
      case 'n':
        bytes.add(0x0A);
      case 'r':
        bytes.add(0x0D);
      case 't':
        bytes.add(0x09);
      case 'v':
        bytes.add(0x0B);
      case 'x' when i < raw.length && _hex(raw.codeUnitAt(i)) >= 0:
        var value = _hex(raw.codeUnitAt(i++));
        if (i < raw.length && _hex(raw.codeUnitAt(i)) >= 0) {
          value = value * 16 + _hex(raw.codeUnitAt(i++));
        }
        bytes.add(value);
      case final d when _octal(d.codeUnitAt(0)) >= 0:
        var value = _octal(d.codeUnitAt(0));
        for (var n = 0; n < 2 && i < raw.length; n++) {
          final digit = _octal(raw.codeUnitAt(i));
          if (digit < 0) break;
          value = value * 8 + digit;
          i++;
        }
        bytes.add(value & 0xFF);
      default:
        final unit = next.codeUnitAt(0);
        if (unit >= 0xD800 && unit <= 0xDBFF && i < raw.length) {
          addText(raw.substring(i - 1, i + 1)); // A surrogate pair.
          i++;
        } else {
          addText(next);
        }
    }
  }
  return utf8.decode(bytes);
}

int _hex(int c) => switch (c) {
  >= 0x30 && <= 0x39 => c - 0x30,
  >= 0x41 && <= 0x46 => c - 0x41 + 10,
  >= 0x61 && <= 0x66 => c - 0x61 + 10,
  _ => -1,
};

int _octal(int c) => c >= 0x30 && c <= 0x37 ? c - 0x30 : -1;
