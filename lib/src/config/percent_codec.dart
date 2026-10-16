// File: percent_codec.dart
// Purpose: Strict UTF-8 percent-encoding helpers for connection URIs
// (internal, not exported).

import 'dart:convert';

import 'package:dbase_postgresql/src/config/pg_config_parse_exception.dart';

/// Decodes `%XX` escapes in [input] as UTF-8. Unlike form encoding, `+` is
/// left as-is (libpq does the same).
///
/// Throws [PgConfigParseException] for malformed escapes, `%00`, or invalid
/// UTF-8; offsets are reported relative to [baseOffset]. Messages never
/// include the input.
String percentDecode(String input, {required int baseOffset}) {
  if (!input.contains('%')) return input;
  final bytes = <int>[];
  var i = 0;
  var runStart = 0;
  while (i < input.length) {
    if (input.codeUnitAt(i) != 0x25) {
      i++;
      continue;
    }
    bytes.addAll(utf8.encode(input.substring(runStart, i)));
    final high = i + 1 < input.length ? _hexValue(input.codeUnitAt(i + 1)) : -1;
    final low = i + 2 < input.length ? _hexValue(input.codeUnitAt(i + 2)) : -1;
    if (high < 0 || low < 0) {
      throw PgConfigParseException(
        'Invalid percent-encoding: "%" must be followed by two hex digits.',
        offset: baseOffset + i,
      );
    }
    final byte = high * 16 + low;
    if (byte == 0) {
      // Same rule as libpq: NUL would truncate or inject protocol fields.
      throw PgConfigParseException(
        'Forbidden value %00 in percent-encoded value.',
        offset: baseOffset + i,
      );
    }
    bytes.add(byte);
    i += 3;
    runStart = i;
  }
  bytes.addAll(utf8.encode(input.substring(runStart)));
  try {
    return utf8.decode(bytes);
  } on FormatException {
    throw PgConfigParseException(
      'Percent-encoded value is not valid UTF-8.',
      offset: baseOffset,
    );
  }
}

/// Percent-encodes everything except RFC 3986 unreserved characters.
String percentEncode(String input) {
  final buffer = StringBuffer();
  for (final byte in utf8.encode(input)) {
    if (_isUnreserved(byte)) {
      buffer.writeCharCode(byte);
    } else {
      buffer
        ..write('%')
        ..write(byte.toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
  }
  return buffer.toString();
}

bool _isUnreserved(int byte) =>
    (byte >= 0x30 && byte <= 0x39) || // 0-9
    (byte >= 0x41 && byte <= 0x5A) || // A-Z
    (byte >= 0x61 && byte <= 0x7A) || // a-z
    byte == 0x2D || // -
    byte == 0x2E || // .
    byte == 0x5F || // _
    byte == 0x7E; // ~

int _hexValue(int unit) {
  if (unit >= 0x30 && unit <= 0x39) return unit - 0x30;
  if (unit >= 0x41 && unit <= 0x46) return unit - 0x41 + 10;
  if (unit >= 0x61 && unit <= 0x66) return unit - 0x61 + 10;
  return -1;
}
