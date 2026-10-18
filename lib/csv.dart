// File: csv.dart
// Purpose: Narrow entrypoint for CSV import: sniffing, streaming decoding,
// PostgreSQL CSV encoding for COPY, the COPY / INSERT-from-unnest SQL, and
// client-side value checks and type inference.

/// Read CSV files leniently and load them into PostgreSQL: sniff the
/// encoding, delimiter and header, decode records from a byte stream,
/// re-encode them as canonical PostgreSQL CSV for `COPY ... FROM STDIN`,
/// and check values against column types before sending. Pure Dart.
library;

export 'src/csv/copy_csv_writer.dart'
    show CopyChunk, CopyCsvEncoder, CopyCsvWriter;
export 'src/csv/copy_sql.dart'
    show CopyOnError, copyFromStdinSql, insertFromUnnestSql, pgArrayLiteral;
export 'src/csv/csv_decoder.dart' show CsvDecoder;
export 'src/csv/csv_dialect.dart' show CsvDialect, CsvLimits;
export 'src/csv/csv_field_value.dart' show EmptyFieldRule, fieldValue;
export 'src/csv/csv_record.dart'
    show
        CsvFieldTooLargeException,
        CsvFormatException,
        CsvInvalidEncodingException,
        CsvRecord,
        CsvRecordNote,
        CsvRecordTooLargeException,
        CsvTooManyFieldsException,
        CsvUnterminatedQuoteException;
export 'src/csv/csv_sniffer.dart'
    show CsvSniff, CsvSniffNote, csvDelimiterCandidates, sniffCsv;
export 'src/csv/csv_text_encoding.dart' show CsvTextEncoding;
export 'src/csv/pg_text_check.dart' show PgTextCheck, checkPgText, inferPgType;
