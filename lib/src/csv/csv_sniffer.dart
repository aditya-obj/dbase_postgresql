// File: csv_sniffer.dart
// Purpose: Guesses a CSV file's encoding, delimiter and header from its
// first bytes, with a confidence the app uses to decide whether to ask.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dbase_postgresql/src/csv/csv_decoder.dart';
import 'package:dbase_postgresql/src/csv/csv_dialect.dart';
import 'package:dbase_postgresql/src/csv/csv_parser.dart';
import 'package:dbase_postgresql/src/csv/csv_record.dart';
import 'package:dbase_postgresql/src/csv/csv_text_encoding.dart';
import 'package:dbase_postgresql/src/csv/pg_text_check.dart';

/// Something the sniffer noticed that the user may want to know.
enum CsvSniffNote {
  /// Records in the sample have different field counts.
  inconsistentFieldCounts,

  /// The sample mixes CRLF, LF and CR line ends.
  mixedLineEndings,

  /// The bytes are not valid UTF-8; Windows-1252 was assumed.
  notUtf8,

  /// UTF-16 detected from zero bytes, without a byte order mark.
  utf16WithoutBom,

  /// The sample holds no records.
  empty,
}

/// What [sniffCsv] found.
final class CsvSniff {
  /// Creates a result.
  const CsvSniff({
    required this.dialect,
    required this.encoding,
    required this.hadBom,
    required this.hadExcelSepLine,
    required this.headerNames,
    required this.columnCount,
    required this.confidence,
    this.notes = const [],
  });

  /// The delimiter and header guess (quote `"`, no escape character).
  final CsvDialect dialect;

  /// The text encoding.
  final CsvTextEncoding encoding;

  /// The file starts with a byte order mark.
  final bool hadBom;

  /// The first line is Excel's `sep=X` delimiter hint.
  final bool hadExcelSepLine;

  /// Column names from the header, or `column1` … `columnN` without one.
  final List<String> headerNames;

  /// The most common field count in the sample.
  final int columnCount;

  /// 0 to 1. Below 0.6 the app should ask the user to check the guess.
  final double confidence;

  /// What else was noticed.
  final List<CsvSniffNote> notes;
}

/// Delimiters tried, in tie-break order.
const csvDelimiterCandidates = [',', ';', '\t', '|'];

/// Detects the encoding (byte order mark; else UTF-16 by zero bytes; else
/// UTF-8 if valid; else Windows-1252), the delimiter (the candidate with
/// the most consistent field count above one across the sample, ties in
/// [csvDelimiterCandidates] order; Excel's `sep=` line wins) and the header
/// (first-row names that match [knownColumns] case-insensitively, or a
/// first row of distinct non-empty non-numeric text above data that holds
/// numbers, dates or booleans in some column).
///
/// [sample] is the start of the file (64 KB is plenty). Unless [complete]
/// is set, its last line is treated as cut and ignored.
CsvSniff sniffCsv(
  Uint8List sample, {
  Iterable<String> knownColumns = const [],
  bool complete = false,
}) {
  final notes = <CsvSniffNote>[];
  final (encoding, bomLength) = _detectEncoding(sample, notes);
  var text = _decode(sample, bomLength, encoding, complete: complete);
  final hadBom = bomLength > 0;
  if (text.isNotEmpty && text.codeUnitAt(0) == byteOrderMarkChar) {
    text = text.substring(1);
  }

  String? sepHint;
  final lf = text.indexOf('\n');
  final firstLine = lf < 0 ? text : text.substring(0, lf);
  if (excelSepLine.firstMatch(firstLine) case final m?) {
    sepHint = m.group(1);
    text = lf < 0 ? '' : text.substring(lf + 1);
  }

  var best = _tryDelimiter(text, sepHint ?? ',', complete: complete);
  if (sepHint == null) {
    for (final d in csvDelimiterCandidates.skip(1)) {
      final next = _tryDelimiter(text, d, complete: complete);
      if (next.score > best.score) best = next;
    }
  }

  final records = best.records;
  if (records.isEmpty) {
    return CsvSniff(
      dialect: CsvDialect(delimiter: best.delimiter, hasHeader: false),
      encoding: encoding,
      hadBom: hadBom,
      hadExcelSepLine: sepHint != null,
      headerNames: const [],
      columnCount: 0,
      confidence: 0,
      notes: [...notes, CsvSniffNote.empty],
    );
  }
  if (best.consistency < 1) notes.add(CsvSniffNote.inconsistentFieldCounts);
  if (best.mixedLineEndings) notes.add(CsvSniffNote.mixedLineEndings);

  final hasHeader = _looksLikeHeader(records, knownColumns);
  final count = best.modalCount;
  String nameOf(int i) {
    final first = records.first;
    final name = hasHeader && i < first.length ? first[i].trim() : '';
    return name.isEmpty ? 'column${i + 1}' : name;
  }

  final names = List.generate(count, nameOf);

  var confidence = count > 1 ? best.consistency : 0.3;
  if (sepHint != null) confidence = 1;
  if (records.length < 2 && sepHint == null) confidence *= 0.7;
  if (notes.contains(CsvSniffNote.notUtf8)) confidence *= 0.9;

  return CsvSniff(
    dialect: CsvDialect(delimiter: best.delimiter, hasHeader: hasHeader),
    encoding: encoding,
    hadBom: hadBom,
    hadExcelSepLine: sepHint != null,
    headerNames: names,
    columnCount: count,
    confidence: confidence,
    notes: notes,
  );
}

(CsvTextEncoding, int) _detectEncoding(Uint8List b, List<CsvSniffNote> notes) {
  if (b.length >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF) {
    return (CsvTextEncoding.utf8, 3);
  }
  if (b.length >= 2 && b[0] == 0xFF && b[1] == 0xFE) {
    return (CsvTextEncoding.utf16le, 2);
  }
  if (b.length >= 2 && b[0] == 0xFE && b[1] == 0xFF) {
    return (CsvTextEncoding.utf16be, 2);
  }
  // ASCII text in UTF-16 has a zero in every other byte.
  final pairs = b.length ~/ 2;
  if (pairs >= 2) {
    var evenZeros = 0;
    var oddZeros = 0;
    for (var i = 0; i + 1 < b.length; i += 2) {
      if (b[i] == 0) evenZeros++;
      if (b[i + 1] == 0) oddZeros++;
    }
    if (oddZeros > pairs * 0.4 && evenZeros < pairs * 0.05) {
      notes.add(CsvSniffNote.utf16WithoutBom);
      return (CsvTextEncoding.utf16le, 0);
    }
    if (evenZeros > pairs * 0.4 && oddZeros < pairs * 0.05) {
      notes.add(CsvSniffNote.utf16WithoutBom);
      return (CsvTextEncoding.utf16be, 0);
    }
  }
  if (_isUtf8(b)) return (CsvTextEncoding.utf8, 0);
  notes.add(CsvSniffNote.notUtf8);
  return (CsvTextEncoding.windows1252, 0);
}

/// Valid UTF-8, allowing a sequence cut at the very end of the sample.
bool _isUtf8(Uint8List b) {
  var end = b.length;
  // Back up over a possibly cut multi-byte sequence (at most 3 bytes).
  for (var k = 1; k <= 3 && end - k >= 0; k++) {
    final c = b[end - k];
    if (c & 0xC0 == 0x80) continue; // Continuation byte.
    if (c >= 0xC0) {
      final need = c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : 2);
      if (need > k) end -= k;
    }
    break;
  }
  try {
    const Utf8Decoder().convert(b, 0, end);
    return true;
  } on FormatException {
    return false;
  }
}

String _decode(
  Uint8List sample,
  int skip,
  CsvTextEncoding encoding, {
  required bool complete,
}) {
  final out = StringBuffer();
  final decoder = ChunkedTextDecoder(encoding, out.write, strict: false)
    ..add(Uint8List.sublistView(sample, skip));
  if (complete) {
    try {
      decoder.close();
    } on InvalidTextBytes {
      // A dangling byte at the end of a sniff sample doesn't matter.
    }
  }
  return out.toString();
}

final class _Trial {
  _Trial(this.delimiter, this.records, {required this.mixedLineEndings}) {
    final counts = <int, int>{};
    for (final r in records) {
      counts[r.length] = (counts[r.length] ?? 0) + 1;
    }
    var modal = 0;
    var modalHits = 0;
    for (final MapEntry(key: count, value: hits) in counts.entries) {
      if (hits > modalHits || (hits == modalHits && count > modal)) {
        modal = count;
        modalHits = hits;
      }
    }
    modalCount = modal;
    consistency = records.isEmpty ? 0 : modalHits / records.length;
  }

  final String delimiter;
  final List<List<String>> records;
  final bool mixedLineEndings;
  late final int modalCount;
  late final double consistency;

  /// A delimiter that splits nothing scores below every one that does.
  double get score => modalCount > 1 ? consistency + modalCount / 1e6 : -1;
}

_Trial _tryDelimiter(String text, String delimiter, {required bool complete}) {
  final records = <List<String>>[];
  final parser = CsvParser(
    CsvDialect(delimiter: delimiter),
    onRecord: (r) => records.add(r.fields),
    // Generous limits; the sample itself is small.
    limits: const CsvLimits(maxFields: 1 << 20),
  );
  try {
    parser.add(text);
    if (complete) parser.close();
  } on CsvFormatException {
    // An open quote at the end of a sample: use the records so far.
  }
  final kinds = [
    parser.crlfEndings > 0,
    parser.lfEndings > 0,
    parser.crEndings > 0,
  ].where((k) => k).length;
  return _Trial(delimiter, records, mixedLineEndings: kinds > 1);
}

bool _looksLikeHeader(List<List<String>> records, Iterable<String> known) {
  final first = records.first;
  final knownNames = {for (final k in known) k.toLowerCase()};
  if (knownNames.isNotEmpty) {
    final hits = first.where(
      (f) => knownNames.contains(f.trim().toLowerCase()),
    );
    if (hits.length * 2 >= first.length) return true;
  }
  final names = first.map((f) => f.trim()).toList();
  if (names.any((n) => n.isEmpty || _isTyped(n))) return false;
  if (names.toSet().length != names.length) return false;
  if (records.length < 2) return true;
  // Some column holds typed values below a text name.
  for (var c = 0; c < first.length; c++) {
    final values = [
      for (final r in records.skip(1).take(50))
        if (c < r.length && r[c].isNotEmpty) r[c],
    ];
    if (values.isNotEmpty && values.every(_isTyped)) return true;
  }
  // Every column is text: a first row of names is the common case.
  return true;
}

bool _isTyped(String value) => switch (inferPgType([value])) {
  'text' || 'jsonb' => false,
  _ => true,
};
