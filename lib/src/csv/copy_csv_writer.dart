// File: copy_csv_writer.dart
// Purpose: Writes values as canonical PostgreSQL CSV for
// `COPY ... FROM STDIN (FORMAT csv)`: UTF-8, LF line ends, NULL as an
// unquoted empty field, an empty string as `""`, quotes only when needed.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// Appends records to a byte buffer in PostgreSQL's CSV format (default
/// delimiter `,`, quote `"`, NULL = unquoted empty).
///
/// A value is quoted when it is empty, contains `,`, `"`, CR or LF, starts
/// or ends with a space or tab, or is exactly `\.` (the old end-of-data
/// marker). Quotes inside are doubled.
final class CopyCsvWriter {
  final _buffer = BytesBuilder(copy: false);
  final _line = StringBuffer();
  var _records = 0;
  var _lines = 0;

  /// Bytes written since the last [takeBytes].
  int get length => _buffer.length;

  /// Records written since the last [takeBytes].
  int get records => _records;

  /// Physical lines written since the last [takeBytes]. PostgreSQL counts
  /// line breaks inside quoted values when it reports an error's line, so
  /// this is what maps a server line number back to a record.
  int get lines => _lines;

  /// Writes one record. Returns the number of physical lines it took (1 +
  /// line feeds inside its values).
  int add(List<String?> values) {
    _line.clear();
    var lines = 1;
    for (var i = 0; i < values.length; i++) {
      if (i > 0) _line.write(',');
      final value = values[i];
      if (value == null) continue;
      if (_needsQuotes(value)) {
        _line
          ..write('"')
          ..write(value.replaceAll('"', '""'))
          ..write('"');
        lines += '\n'.allMatches(value).length;
      } else {
        _line.write(value);
      }
    }
    _line.write('\n');
    _buffer.add(utf8.encode(_line.toString()));
    _records++;
    _lines += lines;
    return lines;
  }

  /// The bytes written so far; the writer starts over empty.
  Uint8List takeBytes() {
    _records = 0;
    _lines = 0;
    return _buffer.takeBytes();
  }

  static bool _needsQuotes(String v) {
    if (v.isEmpty || v == r'\.') return true;
    final first = v.codeUnitAt(0);
    final last = v.codeUnitAt(v.length - 1);
    if (first == 0x20 || first == 0x09 || last == 0x20 || last == 0x09) {
      return true;
    }
    for (var i = 0; i < v.length; i++) {
      switch (v.codeUnitAt(i)) {
        case 0x2C || 0x22 || 0x0A || 0x0D:
          return true;
      }
    }
    return false;
  }
}

/// A piece of COPY data and the records it holds.
final class CopyChunk {
  /// Creates a chunk.
  const CopyChunk({
    required this.bytes,
    required this.firstRecord,
    required this.lastRecord,
  });

  /// PostgreSQL CSV bytes (whole records only).
  final Uint8List bytes;

  /// 0-based index of the first record in this chunk, counted over the
  /// whole stream.
  final int firstRecord;

  /// 0-based index of the last record in this chunk.
  final int lastRecord;
}

/// Values → COPY `FORMAT csv` bytes ([CopyCsvWriter]'s rules), in chunks
/// of about [chunkSize] bytes holding whole records, so a server error can
/// be mapped back to a record.
final class CopyCsvEncoder
    extends StreamTransformerBase<List<String?>, CopyChunk> {
  /// Creates an encoder.
  CopyCsvEncoder({this.chunkSize = 64 * 1024}) {
    if (chunkSize <= 0) throw ArgumentError.value(chunkSize, 'chunkSize');
  }

  /// Target chunk size in bytes; a single long record makes a larger one.
  final int chunkSize;

  @override
  Stream<CopyChunk> bind(Stream<List<String?>> stream) {
    final writer = CopyCsvWriter();
    var next = 0;
    var first = 0;
    return stream.transform(
      StreamTransformer<List<String?>, CopyChunk>.fromHandlers(
        handleData: (values, sink) {
          writer.add(values);
          next++;
          if (writer.length >= chunkSize) {
            sink.add(
              CopyChunk(
                bytes: writer.takeBytes(),
                firstRecord: first,
                lastRecord: next - 1,
              ),
            );
            first = next;
          }
        },
        handleDone: (sink) {
          if (writer.records > 0) {
            sink.add(
              CopyChunk(
                bytes: writer.takeBytes(),
                firstRecord: first,
                lastRecord: next - 1,
              ),
            );
          }
          sink.close();
        },
      ),
    );
  }
}
