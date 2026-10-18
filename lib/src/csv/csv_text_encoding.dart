// File: csv_text_encoding.dart
// Purpose: The text encodings a CSV file may use, and chunked byte → text
// decoders for each (UTF-8 through dart:convert, the rest by hand).

import 'dart:convert';

/// The text encoding of a CSV file.
enum CsvTextEncoding {
  /// UTF-8, with or without a byte order mark.
  utf8,

  /// UTF-16 little endian (Excel's "Unicode text").
  utf16le,

  /// UTF-16 big endian.
  utf16be,

  /// Windows code page 1252 (Western European; Excel's default ANSI).
  windows1252,

  /// ISO 8859-1.
  latin1,
}

/// Thrown by a strict decoder at the first byte sequence that is not valid
/// in the encoding (internal; the CSV decoder adds the line number).
final class InvalidTextBytes implements Exception {
  /// Creates the exception.
  const InvalidTextBytes();
}

/// Decodes bytes in chunks; text goes to the callback as it is complete.
abstract base class ChunkedTextDecoder {
  /// Creates a decoder for [encoding]. A strict decoder throws
  /// [InvalidTextBytes] on malformed input instead of writing U+FFFD.
  factory ChunkedTextDecoder(
    CsvTextEncoding encoding,
    void Function(String text) onText, {
    bool strict = true,
  }) => switch (encoding) {
    CsvTextEncoding.utf8 => _Utf8TextDecoder(onText, strict: strict),
    CsvTextEncoding.utf16le => _Utf16TextDecoder(onText, littleEndian: true),
    CsvTextEncoding.utf16be => _Utf16TextDecoder(onText, littleEndian: false),
    CsvTextEncoding.windows1252 => _SingleByteTextDecoder(onText, cp1252: true),
    CsvTextEncoding.latin1 => _SingleByteTextDecoder(onText, cp1252: false),
  };

  ChunkedTextDecoder._(this.onText);

  /// Receives decoded text.
  final void Function(String text) onText;

  /// Decodes one chunk of bytes.
  void add(List<int> bytes);

  /// Ends the input; a truncated sequence at the end is malformed.
  void close();
}

final class _Utf8TextDecoder extends ChunkedTextDecoder {
  _Utf8TextDecoder(super.onText, {required bool strict}) : super._() {
    _sink = Utf8Decoder(allowMalformed: !strict)
        .startChunkedConversion(_CallbackSink(onText));
  }

  late final ByteConversionSink _sink;

  @override
  void add(List<int> bytes) {
    try {
      _sink.add(bytes);
    } on FormatException {
      throw const InvalidTextBytes();
    }
  }

  @override
  void close() {
    try {
      _sink.close();
    } on FormatException {
      throw const InvalidTextBytes();
    }
  }
}

final class _CallbackSink implements Sink<String> {
  _CallbackSink(this._onText);

  final void Function(String text) _onText;

  @override
  void add(String data) {
    if (data.isNotEmpty) _onText(data);
  }

  @override
  void close() {}
}

final class _Utf16TextDecoder extends ChunkedTextDecoder {
  _Utf16TextDecoder(super.onText, {required this.littleEndian}) : super._();

  final bool littleEndian;
  int? _carry;

  @override
  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    final units = <int>[];
    var i = 0;
    if (_carry case final first?) {
      units.add(_unit(first, bytes[0]));
      _carry = null;
      i = 1;
    }
    for (; i + 1 < bytes.length; i += 2) {
      units.add(_unit(bytes[i], bytes[i + 1]));
    }
    if (i < bytes.length) _carry = bytes[i];
    if (units.isNotEmpty) onText(String.fromCharCodes(units));
  }

  int _unit(int a, int b) => littleEndian ? a | (b << 8) : (a << 8) | b;

  @override
  void close() {
    // An odd trailing byte cannot be a code unit.
    if (_carry != null) throw const InvalidTextBytes();
  }
}

final class _SingleByteTextDecoder extends ChunkedTextDecoder {
  _SingleByteTextDecoder(super.onText, {required this.cp1252}) : super._();

  final bool cp1252;

  @override
  void add(List<int> bytes) {
    if (bytes.isEmpty) return;
    if (!cp1252) {
      onText(String.fromCharCodes(bytes));
      return;
    }
    onText(String.fromCharCodes(bytes.map(_cp1252)));
  }

  @override
  void close() {}
}

int _cp1252(int b) => b >= 0x80 && b < 0xA0 ? _cp1252High[b - 0x80] : b;

/// Windows-1252 0x80–0x9F. The five undefined bytes map to the C1 control
/// with the same value, as the WHATWG encoding standard does.
const _cp1252High = [
  0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, //
  0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
  0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014,
  0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
];

/// The byte order mark, after decoding.
const byteOrderMarkChar = 0xFEFF;
