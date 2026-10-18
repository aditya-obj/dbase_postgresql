// File: dump_writer.dart
// Purpose: The text of a plain-SQL dump around the planned items: a header
// comment (no host, user or connection details), pg_dump's SET preamble so
// `psql -f` restores it, TOC comments before every item, and the COPY
// blocks of table data.

import 'package:dbase_postgresql/src/catalog/schema_model.dart';
import 'package:dbase_postgresql/src/dump/dump_options.dart';
import 'package:dbase_postgresql/src/dump/dump_planner.dart';
import 'package:dbase_postgresql/src/sql/sql_quoting.dart';

/// What the header comment of a dump says.
final class DumpHeader {
  /// Creates a header.
  const DumpHeader({
    required this.generator,
    required this.serverVersion,
    required this.createdUtc,
    required this.content,
    this.includeGrants = false,
    this.visibleRowsOnly = false,
    this.skipped = const SkippedObjects(),
    this.warnings = const [],
    this.tablesNotExported = const [],
  });

  /// The program that wrote the dump, e.g. `dbase 1.0`.
  final String generator;

  /// The source server's `server_version`.
  final String serverVersion;

  /// When the snapshot was taken (written in UTC).
  final DateTime createdUtc;

  /// Which sections the file holds.
  final DumpContent content;

  /// GRANTs are included.
  final bool includeGrants;

  /// Row-level security was applied to the exporting role's reads.
  final bool visibleRowsOnly;

  /// Objects the dump does not cover.
  final SkippedObjects skipped;

  /// Planner warnings.
  final List<DumpWarning> warnings;

  /// Tables whose data the file does not hold (`schema.table`).
  final List<String> tablesNotExported;
}

/// The statements a restore needs before the dump's own: pg_dump's
/// preamble (search_path empty, function bodies unchecked, row security
/// off so a restore fails instead of loading a filtered subset).
const dumpPreamble = [
  'SET statement_timeout = 0;',
  'SET lock_timeout = 0;',
  'SET idle_in_transaction_session_timeout = 0;',
  "SET client_encoding = 'UTF8';",
  'SET standard_conforming_strings = on;',
  "SELECT pg_catalog.set_config('search_path', '', false);",
  'SET check_function_bodies = false;',
  'SET xmloption = content;',
  'SET client_min_messages = warning;',
  'SET row_security = off;',
];

/// Renders the parts of a dump file.
final class DumpWriter {
  /// Creates a writer.
  const DumpWriter();

  /// The header comment and the preamble.
  String start(DumpHeader h) {
    final created = h.createdUtc.toUtc();
    String two(int n) => n.toString().padLeft(2, '0');
    final when =
        '${created.year.toString().padLeft(4, '0')}-${two(created.month)}-'
        '${two(created.day)} ${two(created.hour)}:${two(created.minute)}:'
        '${two(created.second)} UTC';
    final content = switch (h.content) {
      DumpContent.schemaAndData => 'schema and data',
      DumpContent.schemaOnly => 'schema only',
      DumpContent.dataOnly => 'data only',
    };
    final grants = h.includeGrants ? 'included' : 'not included';
    final skipped = [
      for (final MapEntry(:key, :value) in h.skipped.counts.entries)
        '$value ${key.replaceAll('_', ' ')}',
    ].join(', ');
    final notExported = h.tablesNotExported.map(_oneLine).join(', ');
    final lines = [
      '--',
      '-- PostgreSQL SQL export',
      '--',
      '-- Written by: ${_oneLine(h.generator)}',
      '-- Server version: ${_oneLine(h.serverVersion)}',
      '-- Snapshot taken: $when',
      '-- Content: $content; grants $grants; no ownership',
      if (h.visibleRowsOnly)
        '-- Row-level security: only rows visible to the exporting role',
      if (!h.skipped.isEmpty) '-- Not included: $skipped',
      if (h.tablesNotExported.isNotEmpty)
        '-- Data not exported (row-level security): $notExported',
      for (final w in h.warnings) '-- Warning: ${_oneLine(w.toString())}',
      '--',
      '-- Restore with: psql -X -v ON_ERROR_STOP=1 -f <this file> <database>',
      '--',
      '',
      ...dumpPreamble,
      '',
    ];
    return '${lines.join('\n')}\n';
  }

  /// One item: its TOC comment and statements.
  String item(DumpItem item) {
    final toc = _toc(item.name, item.type, item.schema);
    final warning = item.inCycle
        ? '-- WARNING: dependency cycle; written before an object it needs\n'
        : '';
    return '$toc$warning\n${item.statements.join('\n')}\n\n';
  }

  /// The TOC comment and `COPY ... FROM stdin;` line starting a table's
  /// data.
  String copyStart(TableInfo table, {bool visibleRowsOnly = false}) {
    final toc = _toc(
      table.name,
      'TABLE DATA',
      table.schema,
      prefix: 'Data for ',
    );
    final note = visibleRowsOnly
        ? '-- Only the rows row-level security lets the exporting role see.\n'
        : '';
    return '$toc$note\n${copyFromStdinStatement(table)}\n';
  }

  /// The end-of-data marker after a table's rows.
  String copyEnd() => '\\.\n\n';

  /// A comment in place of a table's data when it was not exported.
  String dataNotExported(TableInfo table, String reason) =>
      '${_toc(table.name, 'TABLE DATA', table.schema, prefix: 'Data for ')}'
      '-- NOT EXPORTED: ${_oneLine(reason)}\n\n';

  /// The closing comment.
  String end() => '--\n-- SQL export complete\n--\n';

  /// `COPY schema.table (columns) FROM stdin;`.
  static String copyFromStdinStatement(TableInfo table) {
    final columns = table.dataColumns;
    final list = columns.isEmpty
        ? ''
        : ' (${columns.map(quoteIdent).join(', ')})';
    return 'COPY ${qualifiedName(table.schema, table.name)}$list FROM stdin;';
  }

  static String _toc(
    String name,
    String type,
    String? schema, {
    String prefix = '',
  }) =>
      '--\n-- ${prefix}Name: ${_oneLine(name)}; Type: $type; '
      'Schema: ${schema == null ? '-' : _oneLine(schema)}\n--\n';

  /// Names can hold line breaks; a comment must not.
  static String _oneLine(String text) =>
      text.replaceAll('\r', r'\r').replaceAll('\n', r'\n');
}
