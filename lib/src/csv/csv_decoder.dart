// File: csv_decoder.dart
// Purpose: Streaming bytes → CsvRecord transformer: decodes the text
// encoding, strips a byte order mark and Excel's "sep=" first line, and
// parses leniently (csv_parser.dart).

import 'dart:async';
import 'dart:convert';

import 'package:dabase_postgresql/src/csv/csv_dialect.dart';
import 'package:dabase_postgresql/src/csv/csv_parser.dart';
import 'package:dabase_postgresql/src/csv/csv_record.dart';
import 'package:dabase_postgresql/src/csv/csv_text_encoding.dart';

/// Matches Excel's `sep=;` first line (the delimiter hint).
final excelSepLine = RegExp(r'^sep=(.)\r?$');

/// Bytes → records. Accepts CRLF, LF and CR line ends, mixed. A quote
/// inside an unquoted field is literal; a closing quote followed by other
/// text keeps that text ([CsvRecordNote.strayQuote]). Strips a byte order
/// mark and an Excel `sep=` first line. Empty lines are skipped.
///
/// With [CsvDialect.hasHeader] the first record is emitted with number 0.
/// Errors are [CsvFormatException]s; the stream ends after the first one.
/// With [strictEncoding] (the default) bytes that are not valid in
/// [encoding] are an error ([CsvInvalidEncodingException]) instead of
/// becoming U+FFFD.
final class CsvDecoder extends StreamTransformerBase<List<int>, CsvRecord> {
  /// Creates a decoder. Throws [ArgumentError] for an unusable [dialect].
  CsvDecoder(
    this.dialect, {
    this.encoding = CsvTextEncoding.utf8,
    this.limits = const CsvLimits(),
    this.strictEncoding = true,
  }) {
    dialect.validate();
  }

  /// How the file is written.
  final CsvDialect dialect;

  /// The file's text encoding.
  final CsvTextEncoding encoding;

  /// Size limits.
  final CsvLimits limits;

  /// Malformed bytes are an error rather than U+FFFD.
  final bool strictEncoding;

  @override
  Stream<CsvRecord> bind(Stream<List<int>> stream) =>
      Stream.eventTransformed(stream, (sink) => _DecoderSink(this, sink));

  /// Decodes a whole file held in memory (for tests and small inputs).
  List<CsvRecord> convert(List<int> bytes) {
    final out = <CsvRecord>[];
    final sink = _DecoderSink(this, _ListSink(out))
      ..add(bytes)
      ..close();
    if (sink.error case final error?) throw error;
    return out;
  }
}

final class _ListSink implements EventSink<CsvRecord> {
  _ListSink(this._out);

  final List<CsvRecord> _out;

  @override
  void add(CsvRecord event) => _out.add(event);

  @override
  void addError(Object error, [StackTrace? stackTrace]) {}

  @override
  void close() {}
}

final class _DecoderSink implements EventSink<List<int>> {
  _DecoderSink(this._config, this._out) {
    _parser = CsvParser(
      _config.dialect,
      limits: _config.limits,
      onRecord: _onRecord,
    );
    _text = ChunkedTextDecoder(
      _config.encoding,
      _onText,
      strict: _config.strictEncoding,
    );
  }

  final CsvDecoder _config;
  final EventSink<CsvRecord> _out;
  late final CsvParser _parser;
  late final ChunkedTextDecoder _text;

  /// Text before the first line break, held back to check for BOM and
  /// `sep=`; `null` once released.
  StringBuffer? _head = StringBuffer();
  var _lineOffset = 0;
  var _bytes = 0;
  var _number = 0;
  var _headerDone = false;

  /// The first error, after which input is ignored.
  CsvFormatException? error;

  @override
  void add(List<int> data) {
    if (error != null) return;
    _bytes += data.length;
    _guard(() => _text.add(data), chunk: data);
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) =>
      _out.addError(error, stackTrace);

  @override
  void close() {
    if (error == null) {
      _guard(() {
        _text.close();
        _releaseHead();
        _parser.close();
      });
    }
    _out.close();
  }

  void _guard(void Function() body, {List<int>? chunk}) {
    try {
      body();
    } on CsvFormatException catch (e) {
      _fail(e);
    } on InvalidTextBytes {
      if (chunk != null) _parseUpToInvalid(chunk);
      _releaseHeadQuietly();
      _fail(CsvInvalidEncodingException(_parser.line + _lineOffset));
    }
  }

  /// A strict UTF-8 decoder drops the whole chunk it fails on; parse the
  /// text before the bad bytes so the error names the right line.
  void _parseUpToInvalid(List<int> chunk) {
    if (_config.encoding != CsvTextEncoding.utf8) return;
    final text = utf8.decode(chunk, allowMalformed: true);
    final bad = text.indexOf('\uFFFD');
    try {
      _onText(bad < 0 ? text : text.substring(0, bad));
    } on CsvFormatException {
      // The encoding error is reported instead.
    }
  }

  void _releaseHeadQuietly() {
    try {
      _releaseHead();
    } on CsvFormatException {
      // The encoding error is reported instead.
    }
  }

  void _fail(CsvFormatException e) {
    error = e;
    _out.addError(e);
  }

  void _onText(String text) {
    final head = _head;
    if (head == null) {
      _parser.add(text);
      return;
    }
    head.write(text);
    final buffered = head.toString();
    final lf = buffered.indexOf('\n');
    if (lf < 0 && buffered.length < 64) return;
    _releaseHead();
  }

  /// Strips the BOM and an Excel `sep=` line, then hands the text on.
  void _releaseHead() {
    final head = _head;
    if (head == null) return;
    _head = null;
    var text = head.toString();
    if (text.isNotEmpty && text.codeUnitAt(0) == byteOrderMarkChar) {
      text = text.substring(1);
    }
    final lf = text.indexOf('\n');
    final first = lf < 0 ? text : text.substring(0, lf);
    if (excelSepLine.hasMatch(first)) {
      text = lf < 0 ? '' : text.substring(lf + 1);
      _lineOffset = 1;
    }
    _parser.add(text);
  }

  void _onRecord(RawCsvRecord raw) {
    final header = _config.dialect.hasHeader && !_headerDone;
    _headerDone = true;
    final number = header ? 0 : ++_number;
    _out.add(
      CsvRecord(
        fields: raw.fields,
        quoted: raw.quoted,
        number: number,
        line: raw.line + _lineOffset,
        byteOffset: _bytes,
        notes: raw.notes,
      ),
    );
  }
}
