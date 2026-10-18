// File: table_printer.dart
// Purpose: psql's printTable: picks the layout for the format and the
// expanded setting, and the unaligned and CSV formats.
//
// Ported from src/fe_utils/print.c (printTable, print_unaligned_text,
// print_unaligned_vertical, print_csv_text, print_csv_vertical,
// csv_print_field) - PostgreSQL License, (c) 1996-2026 PostgreSQL Global
// Development Group. See THIRD_PARTY_NOTICES.

import 'package:dbase_postgresql/src/psql/print/aligned_printer.dart';
import 'package:dbase_postgresql/src/psql/print/print_table.dart';
import 'package:dbase_postgresql/src/psql/print/vertical_printer.dart';

/// Prints [table] the way psql would with [options], and returns the
/// text. Like psql, aligned output ends with an empty line.
String printTable(PrintTable table, PrintOptions options) {
  final out = StringBuffer();
  final expanded =
      options.expanded == ExpandedMode.on && !table.forceNotExpanded;
  switch (options.format) {
    case PrintFormat.aligned || PrintFormat.wrapped:
      if (expanded) {
        printAlignedVertical(table, options, out);
      } else {
        printAlignedText(table, options, out);
      }
    case PrintFormat.unaligned:
      if (expanded) {
        _unalignedVertical(table, options, out);
      } else {
        _unalignedText(table, options, out);
      }
    case PrintFormat.csv:
      if (expanded) {
        _csvVertical(table, options, out);
      } else {
        _csvText(table, options, out);
      }
  }
  return out.toString();
}

const _recordSeparator = '\n';

void _unalignedText(PrintTable table, PrintOptions options, StringBuffer out) {
  final separator = options.fieldSeparator;
  var needRecordSep = false;
  if (!options.tuplesOnly) {
    if (table.title case final title?) {
      out
        ..write(title)
        ..write(_recordSeparator);
    }
    out.write(table.headers.join(separator));
    needRecordSep = true;
  }
  for (final row in table.rows) {
    if (needRecordSep) out.write(_recordSeparator);
    out.write(row.join(separator));
    needRecordSep = true;
  }
  if (!options.tuplesOnly) {
    for (final footer in table.footersWithDefault(options)) {
      if (needRecordSep) out.write(_recordSeparator);
      out.write(footer);
      needRecordSep = true;
    }
  }
  if (needRecordSep) out.write('\n');
}

void _unalignedVertical(
  PrintTable table,
  PrintOptions options,
  StringBuffer out,
) {
  final separator = options.fieldSeparator;
  var needRecordSep = false;
  if (!options.tuplesOnly && table.title != null) {
    out.write(table.title);
    needRecordSep = true;
  }
  final columns = table.headers.length;
  for (final row in table.rows) {
    for (var c = 0; c < columns; c++) {
      if (needRecordSep) {
        out.write(_recordSeparator * 2);
        needRecordSep = false;
      }
      out
        ..write(table.headers[c])
        ..write(separator)
        ..write(row[c]);
      if (c + 1 < columns) {
        out.write(_recordSeparator);
      } else {
        needRecordSep = true;
      }
    }
  }
  if (!options.tuplesOnly && table.footers != null) {
    out.write(_recordSeparator);
    for (final footer in table.footers!) {
      out
        ..write(_recordSeparator)
        ..write(footer);
    }
  }
  if (needRecordSep) out.write('\n');
}

void _csvText(PrintTable table, PrintOptions options, StringBuffer out) {
  final separator = options.csvFieldSeparator;
  if (!options.tuplesOnly) {
    out
      ..write(table.headers.map((h) => _csvField(h, separator)).join(separator))
      ..write('\n');
  }
  for (final row in table.rows) {
    out
      ..write(row.map((c) => _csvField(c, separator)).join(separator))
      ..write('\n');
  }
}

void _csvVertical(PrintTable table, PrintOptions options, StringBuffer out) {
  final separator = options.csvFieldSeparator;
  for (final row in table.rows) {
    for (var c = 0; c < table.headers.length; c++) {
      out
        ..write(_csvField(table.headers[c], separator))
        ..write(separator)
        ..write(_csvField(row[c], separator))
        ..write('\n');
    }
  }
}

/// psql's csv_print_field: quoted when it holds the separator, CR, LF or
/// a quote, is exactly `\.`, or the separator is `\` or `.`.
String _csvField(String value, String separator) {
  final quote =
      value.contains(separator) ||
      value.contains('\r') ||
      value.contains('\n') ||
      value.contains('"') ||
      value == r'\.' ||
      separator == r'\' ||
      separator == '.';
  return quote ? '"${value.replaceAll('"', '""')}"' : value;
}
