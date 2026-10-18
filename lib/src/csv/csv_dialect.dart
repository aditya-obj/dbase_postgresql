// File: csv_dialect.dart
// Purpose: How a CSV file is written (delimiter, quote, escape, header) and
// the decoder's size limits.

/// How a CSV file is written.
final class CsvDialect {
  /// Creates a dialect. [delimiter], [quote] and [escape] are one character
  /// each; the delimiter and quote must differ.
  const CsvDialect({
    this.delimiter = ',',
    this.quote = '"',
    this.escape,
    this.hasHeader = true,
  });

  /// Separates fields: usually `,`, `;`, a tab or `|`.
  final String delimiter;

  /// Encloses fields that contain the delimiter, quotes or line breaks.
  final String quote;

  /// Escapes the next character inside a quoted field, e.g. a backslash in
  /// MySQL dumps. `null`: a quote inside a quoted field is written twice
  /// (RFC 4180).
  final String? escape;

  /// The first record holds column names.
  final bool hasHeader;

  /// The same dialect with some values replaced.
  CsvDialect copyWith({
    String? delimiter,
    String? quote,
    String? escape,
    bool clearEscape = false,
    bool? hasHeader,
  }) => CsvDialect(
    delimiter: delimiter ?? this.delimiter,
    quote: quote ?? this.quote,
    escape: clearEscape ? null : escape ?? this.escape,
    hasHeader: hasHeader ?? this.hasHeader,
  );

  /// Throws [ArgumentError] unless the characters are usable.
  void validate() {
    for (final (name, value) in [
      ('delimiter', delimiter),
      ('quote', quote),
      ('escape', escape ?? '"'),
    ]) {
      if (value.length != 1 || value == '\r' || value == '\n') {
        throw ArgumentError.value(value, name, 'must be one character');
      }
    }
    if (delimiter == quote) {
      throw ArgumentError.value(delimiter, 'delimiter', 'equals the quote');
    }
  }

  @override
  bool operator ==(Object other) =>
      other is CsvDialect &&
      other.delimiter == delimiter &&
      other.quote == quote &&
      other.escape == escape &&
      other.hasHeader == hasHeader;

  @override
  int get hashCode => Object.hash(delimiter, quote, escape, hasHeader);

  @override
  String toString() =>
      'CsvDialect(delimiter: ${_show(delimiter)}, quote: $quote, '
      'escape: $escape, hasHeader: $hasHeader)';

  static String _show(String c) => c == '\t' ? r'\t' : c;
}

/// Size limits that stop a malformed or hostile file from using up memory.
///
/// Sizes are counted in UTF-16 code units of the decoded text, which for
/// ASCII equals the byte count.
final class CsvLimits {
  /// Creates limits. The defaults fit PostgreSQL: 1,600 columns per table
  /// and values far below its 1 GB maximum.
  const CsvLimits({
    this.maxFieldBytes = 64 << 20,
    this.maxFields = 1600,
    this.maxRecordBytes = 256 << 20,
  });

  /// Longest single field.
  final int maxFieldBytes;

  /// Most fields in one record.
  final int maxFields;

  /// Longest record (all fields together).
  final int maxRecordBytes;
}
