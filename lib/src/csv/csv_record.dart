// File: csv_record.dart
// Purpose: One decoded CSV record, the notes the lenient parser attaches,
// and the typed format errors it throws.

/// Something the lenient parser accepted but a strict one would reject.
enum CsvRecordNote {
  /// A closing quote was followed by text other than a delimiter or line
  /// break (`"abc"def`); the text was kept.
  strayQuote,

  /// A quote appeared inside an unquoted field (`5" pipe`) and was kept as
  /// a literal character.
  quoteInUnquotedField,
}

/// One record of a CSV file.
final class CsvRecord {
  /// Creates a record.
  const CsvRecord({
    required this.fields,
    required this.quoted,
    required this.number,
    required this.line,
    required this.byteOffset,
    this.notes = const {},
  });

  /// The field values, unquoted.
  final List<String> fields;

  /// Per field: whether it was quoted. An empty quoted field (`""`) is an
  /// empty string; an empty unquoted one is NULL in PostgreSQL's rules.
  final List<bool> quoted;

  /// 1-based data record number. The header record has number 0.
  final int number;

  /// 1-based physical line where the record starts.
  final int line;

  /// Input bytes read when the record ended (for progress).
  final int byteOffset;

  /// What the lenient parser had to accept in this record.
  final Set<CsvRecordNote> notes;

  /// The record is the header (the first record of a file with one).
  bool get isHeader => number == 0;

  @override
  String toString() => 'CsvRecord(#$number, line $line, $fields)';
}

/// A CSV file that cannot be decoded.
sealed class CsvFormatException implements Exception {
  const CsvFormatException(this.line);

  /// 1-based physical line of the record (or byte sequence) at fault.
  final int line;
}

/// A quoted field was still open at the end of the file.
final class CsvUnterminatedQuoteException extends CsvFormatException {
  /// Creates the exception for the record starting at [line].
  const CsvUnterminatedQuoteException(super.line);

  @override
  String toString() => 'CsvUnterminatedQuoteException(line $line)';
}

/// A field is longer than `CsvLimits.maxFieldBytes`.
final class CsvFieldTooLargeException extends CsvFormatException {
  /// Creates the exception for the record starting at [line].
  const CsvFieldTooLargeException(super.line);

  @override
  String toString() => 'CsvFieldTooLargeException(line $line)';
}

/// A record is longer than `CsvLimits.maxRecordBytes`.
final class CsvRecordTooLargeException extends CsvFormatException {
  /// Creates the exception for the record starting at [line].
  const CsvRecordTooLargeException(super.line);

  @override
  String toString() => 'CsvRecordTooLargeException(line $line)';
}

/// A record has more fields than `CsvLimits.maxFields`.
final class CsvTooManyFieldsException extends CsvFormatException {
  /// Creates the exception for the record starting at [line].
  const CsvTooManyFieldsException(super.line);

  @override
  String toString() => 'CsvTooManyFieldsException(line $line)';
}

/// The bytes are not valid in the chosen encoding (strict decoding only).
final class CsvInvalidEncodingException extends CsvFormatException {
  /// Creates the exception; [line] is where decoding stopped.
  const CsvInvalidEncodingException(super.line);

  @override
  String toString() => 'CsvInvalidEncodingException(line $line)';
}
