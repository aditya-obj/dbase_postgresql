// File: print_table.dart
// Purpose: The table psql prints (title, headers, cells, footers) and the
// \pset options that shape it, plus psql's printQuery rules for turning a
// query result into one (NULL display, numeric columns right-aligned).
//
// Ported from src/fe_utils/print.c and src/include/fe_utils/print.h
// (printTableContent, printTableOpt, printQuery, column_type_alignment) -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

/// `\pset format`. Only the text formats a phone console needs.
enum PrintFormat {
  /// psql's default: padded columns with `|` and `-+-` rules.
  aligned,

  /// Like [aligned], but wide columns wrap to fit [PrintOptions.columns].
  wrapped,

  /// Values separated by [PrintOptions.fieldSeparator], no padding.
  unaligned,

  /// RFC 4180 CSV with [PrintOptions.csvFieldSeparator].
  csv,
}

/// `\x`: expanded (one line per column) display.
enum ExpandedMode {
  /// Normal table.
  off,

  /// Always one record block per row.
  on,

  /// Expanded only when the table is wider than [PrintOptions.columns].
  auto,
}

/// Column alignment.
enum PrintAlign {
  /// Text: padded on the right.
  left,

  /// Numbers: padded on the left.
  right,
}

/// The `\pset` options the printer uses. Immutable; change with
/// [copyWith].
final class PrintOptions {
  /// psql's defaults: aligned, border 1, footer on, empty NULL display.
  const PrintOptions({
    this.format = PrintFormat.aligned,
    this.border = 1,
    this.expanded = ExpandedMode.off,
    this.nullDisplay = '',
    this.defaultFooter = true,
    this.tuplesOnly = false,
    this.columns = 0,
    this.title,
    this.fieldSeparator = '|',
    this.csvFieldSeparator = ',',
  });

  /// Output format.
  final PrintFormat format;

  /// 0 (no rules), 1 (inner rules, default) or 2 (a full frame). Larger
  /// values print as 2.
  final int border;

  /// Expanded display.
  final ExpandedMode expanded;

  /// Text shown for SQL NULL in query results (`\pset null`).
  final String nullDisplay;

  /// Print the `(N rows)` footer.
  final bool defaultFooter;

  /// Rows only: no title, headers or footers (`\t`).
  final bool tuplesOnly;

  /// Target width for [PrintFormat.wrapped] and [ExpandedMode.auto]; 0
  /// when unknown (psql reads the terminal width; callers pass the
  /// screen width in characters).
  final int columns;

  /// `\pset title`: replaces the title of query results.
  final String? title;

  /// Field separator for [PrintFormat.unaligned].
  final String fieldSeparator;

  /// Field separator for [PrintFormat.csv].
  final String csvFieldSeparator;

  /// The border actually used (psql clamps it to 2).
  int get effectiveBorder => border > 2 ? 2 : (border < 0 ? 0 : border);

  /// A copy with the given fields replaced. [title] is cleared with
  /// [clearTitle].
  PrintOptions copyWith({
    PrintFormat? format,
    int? border,
    ExpandedMode? expanded,
    String? nullDisplay,
    bool? defaultFooter,
    bool? tuplesOnly,
    int? columns,
    String? title,
    bool clearTitle = false,
    String? fieldSeparator,
    String? csvFieldSeparator,
  }) => PrintOptions(
    format: format ?? this.format,
    border: border ?? this.border,
    expanded: expanded ?? this.expanded,
    nullDisplay: nullDisplay ?? this.nullDisplay,
    defaultFooter: defaultFooter ?? this.defaultFooter,
    tuplesOnly: tuplesOnly ?? this.tuplesOnly,
    columns: columns ?? this.columns,
    title: clearTitle ? null : (title ?? this.title),
    fieldSeparator: fieldSeparator ?? this.fieldSeparator,
    csvFieldSeparator: csvFieldSeparator ?? this.csvFieldSeparator,
  );
}

/// A table to print: psql's `printTableContent`.
final class PrintTable {
  /// Creates a table. Every row of [rows] has one cell per header; cells
  /// are already text (NULL replaced). [footers] replace the default
  /// `(N rows)` footer when not null.
  PrintTable({
    required this.headers,
    required this.rows,
    List<PrintAlign>? aligns,
    this.title,
    this.footers,
    this.defaultFooter = true,
    this.forceNotExpanded = false,
  }) : aligns = aligns ?? List.filled(headers.length, PrintAlign.left);

  /// psql's `printQuery`: a query result as a table. [typeOids] (one per
  /// column, or empty) right-align numeric columns; `null` cells show
  /// [nullDisplay].
  factory PrintTable.fromResult({
    required List<String> columns,
    required List<List<String?>> rows,
    List<int> typeOids = const [],
    String nullDisplay = '',
    String? title,
    List<String>? footers,
  }) => PrintTable(
    headers: columns,
    aligns: [
      for (var i = 0; i < columns.length; i++)
        if (i < typeOids.length)
          alignmentForType(typeOids[i])
        else
          PrintAlign.left,
    ],
    rows: [
      for (final row in rows) [for (final cell in row) cell ?? nullDisplay],
    ],
    title: title,
    footers: footers,
  );

  /// Column headers.
  final List<String> headers;

  /// Per-column alignment.
  final List<PrintAlign> aligns;

  /// Cells, row by row.
  final List<List<String>> rows;

  /// Printed above the table (centered when it fits).
  final String? title;

  /// Lines printed under the table; `null` prints the default footer.
  final List<String>? footers;

  /// Whether the default `(N rows)` footer may be printed (describe
  /// commands turn it off).
  final bool defaultFooter;

  /// psql prints `\d table` details unexpanded even with `\x on`.
  final bool forceNotExpanded;

  /// The footers to print: explicit ones, or `(N rows)` when allowed.
  List<String> footersWithDefault(PrintOptions options) {
    if (footers case final explicit?) return explicit;
    if (!options.defaultFooter || !defaultFooter) return const [];
    final count = rows.length;
    return [if (count == 1) '(1 row)' else '($count rows)'];
  }
}

/// PostgreSQL type OIDs psql right-aligns (`column_type_alignment`):
/// int2, int4, int8, float4, float8, numeric, oid, xid, xid8, cid, money.
const Set<int> rightAlignedTypeOids = {
  21, 23, 20, 700, 701, 1700, 26, 28, 5069, 29, 790, //
};

/// Alignment psql uses for a column of type [typeOid].
PrintAlign alignmentForType(int typeOid) =>
    rightAlignedTypeOids.contains(typeOid) ? PrintAlign.right : PrintAlign.left;
