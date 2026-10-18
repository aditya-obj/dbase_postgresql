// File: bytea_text.dart
// Purpose: Decodes the text output of a PostgreSQL `bytea` value, in both
// `bytea_output` formats: hex (`\x0a1b`, the default since 9.0) and
// the legacy escape format (`a\\b\001`).

import 'dart:convert';
import 'dart:typed_data';

/// Decodes [text], a `bytea` value as the server prints it, into bytes.
///
/// Hex format starts with `\x`; whitespace between digit pairs is skipped
/// (the server accepts it on input). Anything else is read as escape
/// format: `\\` is a backslash, `\ooo` an octal byte, and every other
/// character stands for its UTF-8 bytes (the server prints only ASCII).
///
/// With [allowTruncated], input cut short by a client size cap is
/// accepted: a trailing odd hex digit or an unfinished escape is dropped.
/// Otherwise such input, and any invalid digit or escape, throws a
/// [FormatException] that names the offset but never repeats the value.
Uint8List decodeByteaText(String text, {bool allowTruncated = false}) =>
    text.startsWith(r'\x')
    ? _decodeHex(text, allowTruncated)
    : _decodeEscape(text, allowTruncated);

Uint8List _decodeHex(String text, bool allowTruncated) {
  final out = Uint8List((text.length - 2) >> 1);
  var length = 0;
  int? high;
  for (var i = 2; i < text.length; i++) {
    final c = text.codeUnitAt(i);
    if (high == null && _isSpace(c)) continue;
    final digit = _hexValue(c);
    if (digit < 0) {
      throw FormatException('Invalid hex digit in bytea text at offset $i');
    }
    if (high == null) {
      high = digit;
    } else {
      out[length++] = (high << 4) | digit;
      high = null;
    }
  }
  if (high != null && !allowTruncated) {
    throw const FormatException('Odd number of hex digits in bytea text');
  }
  return Uint8List.sublistView(out, 0, length);
}

Uint8List _decodeEscape(String text, bool allowTruncated) {
  final out = BytesBuilder(copy: false);
  var plainStart = 0;
  void flushPlain(int end) {
    if (end > plainStart) {
      out.add(utf8.encode(text.substring(plainStart, end)));
    }
  }

  var i = 0;
  while (i < text.length) {
    if (text.codeUnitAt(i) != 0x5C) {
      i++;
      continue;
    }
    flushPlain(i);
    if (i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5C) {
      out.addByte(0x5C);
      i += 2;
    } else if (i + 3 < text.length &&
        _isOctal(text.codeUnitAt(i + 1), first: true) &&
        _isOctal(text.codeUnitAt(i + 2)) &&
        _isOctal(text.codeUnitAt(i + 3))) {
      out.addByte(
        ((text.codeUnitAt(i + 1) - 0x30) << 6) |
            ((text.codeUnitAt(i + 2) - 0x30) << 3) |
            (text.codeUnitAt(i + 3) - 0x30),
      );
      i += 4;
    } else if (allowTruncated && _isUnfinishedEscape(text, i)) {
      return out.takeBytes();
    } else {
      throw FormatException('Invalid escape in bytea text at offset $i');
    }
    plainStart = i;
  }
  flushPlain(text.length);
  return out.takeBytes();
}

/// A backslash followed only by up to two octal digits, at the very end.
bool _isUnfinishedEscape(String text, int at) {
  final rest = text.length - at - 1;
  if (rest > 2) return false;
  for (var k = 1; k <= rest; k++) {
    if (!_isOctal(text.codeUnitAt(at + k), first: k == 1)) return false;
  }
  return true;
}

bool _isOctal(int c, {bool first = false}) =>
    c >= 0x30 && c <= (first ? 0x33 : 0x37);

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

int _hexValue(int c) {
  if (c >= 0x30 && c <= 0x39) return c - 0x30;
  if (c >= 0x61 && c <= 0x66) return c - 0x61 + 10;
  if (c >= 0x41 && c <= 0x46) return c - 0x41 + 10;
  return -1;
}

/// Lower-case hex of [bytes], without a prefix.
String bytesToHex(List<int> bytes) {
  const digits = '0123456789abcdef';
  final out = StringBuffer();
  for (final b in bytes) {
    out
      ..write(digits[(b >> 4) & 0xF])
      ..write(digits[b & 0xF]);
  }
  return out.toString();
}
