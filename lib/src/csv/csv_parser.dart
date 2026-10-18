// File: csv_parser.dart
// Purpose: Incremental, lenient RFC 4180 parser over decoded text (internal,
// not exported). Shared by CsvDecoder and sniffCsv.
// Rules: CRLF, LF and CR all end a record, mixed in one file. A quote
// inside an unquoted field is literal. Text after a closing quote is kept
// (noted as a stray quote). Empty lines are skipped. Line numbers count
// physical lines, including line breaks inside quoted fields.

import 'package:dbase_postgresql/src/csv/csv_dialect.dart';
import 'package:dbase_postgresql/src/csv/csv_record.dart';

/// A record as parsed, before numbering.
typedef RawCsvRecord = ({
  List<String> fields,
  List<bool> quoted,
  int line,
  Set<CsvRecordNote> notes,
});

enum _State { fieldStart, unquoted, quoted, quoteInQuoted, escapeNext }

const _cr = 0x0D;
const _lf = 0x0A;

/// Parses text added in chunks; calls [onRecord] for each complete record.
final class CsvParser {
  /// Creates a parser. Throws [ArgumentError] for an unusable [dialect].
  CsvParser(
    CsvDialect dialect, {
    required this.onRecord,
    this.limits = const CsvLimits(),
  }) : _delimiter = dialect.delimiter.codeUnitAt(0),
       _quote = dialect.quote.codeUnitAt(0),
       _escape = dialect.escape?.codeUnitAt(0) {
    dialect.validate();
  }

  /// Receives each record.
  final void Function(RawCsvRecord record) onRecord;

  /// Size limits.
  final CsvLimits limits;

  final int _delimiter;
  final int _quote;
  final int? _escape;

  _State _state = _State.fieldStart;
  final _field = StringBuffer();
  var _fieldQuoted = false;
  var _fields = <String>[];
  var _quoted = <bool>[];
  var _notes = <CsvRecordNote>{};
  var _recordSize = 0;
  var _recordStarted = false;

  /// The last character was a CR (a following LF belongs to it).
  var _afterCr = false;

  /// Current physical line (1-based).
  int get line => _line;
  var _line = 1;
  var _recordLine = 1;

  /// Record terminators seen, by kind (for the sniffer's notes).
  int crlfEndings = 0;

  /// See [crlfEndings].
  int lfEndings = 0;

  /// See [crlfEndings].
  int crEndings = 0;

  /// Parses [text]. Throws a [CsvFormatException] when a limit is exceeded.
  void add(String text) {
    final n = text.length;
    var i = 0;
    while (i < n) {
      final c = text.codeUnitAt(i);
      if (_afterCr) {
        _afterCr = false;
        if (c == _lf) {
          // The LF of a CRLF already counted with its CR.
          if (_state == _State.fieldStart && !_recordStarted) {
            crEndings--;
            crlfEndings++;
          } else {
            _append(text, i, i + 1);
          }
          i++;
          continue;
        }
      }
      switch (_state) {
        case _State.fieldStart:
          if (c == _quote) {
            _recordStarted = true;
            _fieldQuoted = true;
            _state = _State.quoted;
            i++;
          } else if (c == _delimiter) {
            _recordStarted = true;
            _endField();
            i++;
          } else if (c == _cr || c == _lf) {
            _endRecord();
            _lineBreak(c);
            i++;
          } else {
            _recordStarted = true;
            _state = _State.unquoted;
          }
        case _State.unquoted:
          var j = i;
          while (j < n) {
            final d = text.codeUnitAt(j);
            if (d == _delimiter || d == _cr || d == _lf) break;
            if (d == _quote) _notes.add(CsvRecordNote.quoteInUnquotedField);
            j++;
          }
          _append(text, i, j);
          i = j;
          if (i < n) {
            final d = text.codeUnitAt(i);
            if (d == _delimiter) {
              _endField();
            } else {
              _endRecord();
              _lineBreak(d);
            }
            i++;
          }
        case _State.quoted:
          var j = i;
          while (j < n) {
            final d = text.codeUnitAt(j);
            if (d == _quote || d == _escape || d == _cr || d == _lf) break;
            j++;
          }
          _append(text, i, j);
          i = j;
          if (i < n) {
            final d = text.codeUnitAt(i);
            if (d == _quote && (_escape == null || _escape == _quote)) {
              _state = _State.quoteInQuoted;
            } else if (d == _escape) {
              _state = _State.escapeNext;
            } else if (d == _quote) {
              // A distinct escape character: a quote closes the field.
              _state = _State.quoteInQuoted;
            } else {
              // A line break inside quotes is data.
              _append(text, i, i + 1);
              _line++;
              _afterCr = d == _cr;
            }
            i++;
          }
        case _State.escapeNext:
          _append(text, i, i + 1);
          if (c == _cr || c == _lf) {
            _line++;
            _afterCr = c == _cr;
          }
          _state = _State.quoted;
          i++;
        case _State.quoteInQuoted:
          if (c == _quote) {
            _append(text, i, i + 1);
            _state = _State.quoted;
            i++;
          } else if (c == _delimiter) {
            _endField();
            i++;
          } else if (c == _cr || c == _lf) {
            _endRecord();
            _lineBreak(c);
            i++;
          } else {
            _notes.add(CsvRecordNote.strayQuote);
            _state = _State.unquoted;
          }
      }
    }
  }

  /// Ends the input. Throws [CsvUnterminatedQuoteException] when a quoted
  /// field is still open.
  void close() {
    _afterCr = false;
    if (_state == _State.quoted || _state == _State.escapeNext) {
      throw CsvUnterminatedQuoteException(_recordLine);
    }
    if (_recordStarted) _endRecord();
  }

  /// Whether a record is in progress (used by the sniffer to drop a record
  /// cut by the end of its sample).
  bool get hasPartialRecord => _recordStarted || _state != _State.fieldStart;

  void _append(String text, int start, int end) {
    final length = end - start;
    if (length <= 0) return;
    if (_field.length + length > limits.maxFieldBytes) {
      throw CsvFieldTooLargeException(_recordLine);
    }
    _recordSize += length;
    if (_recordSize > limits.maxRecordBytes) {
      throw CsvRecordTooLargeException(_recordLine);
    }
    _field.write(text.substring(start, end));
  }

  void _endField() {
    if (_fields.length >= limits.maxFields) {
      throw CsvTooManyFieldsException(_recordLine);
    }
    _fields.add(_field.toString());
    _quoted.add(_fieldQuoted);
    _field.clear();
    _fieldQuoted = false;
    _state = _State.fieldStart;
  }

  void _endRecord() {
    if (_recordStarted) {
      _endField();
      onRecord((
        fields: _fields,
        quoted: _quoted,
        line: _recordLine,
        notes: _notes,
      ));
      _fields = [];
      _quoted = [];
      _notes = {};
    }
    _recordSize = 0;
    _recordStarted = false;
    _state = _State.fieldStart;
  }

  void _lineBreak(int c) {
    _line++;
    _recordLine = _line;
    if (c == _cr) {
      _afterCr = true;
      crEndings++;
    } else {
      lfEndings++;
    }
  }
}
