// File: table_info.dart
// Purpose: The first two steps of psql's `\d name`: the relation's flags
// (pg_class), and the per-column query and cells, whose shape depends on
// the relation kind, `+` and the server version.
//
// Ported from src/bin/psql/describe.c (describeOneTableDetails) -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

import 'package:dabase_postgresql/src/psql/describe/psql_query.dart';

/// The general table info query (PostgreSQL 12+ shape).
String tableInfoSql(String oid, {required bool verbose}) {
  final options = verbose
      ? 'pg_catalog.array_to_string(c.reloptions || '
            "array(select 'toast.' || x from pg_catalog.unnest(tc.reloptions)"
            " x), ', ')\n"
      : "''";
  return 'SELECT c.relchecks, c.relkind, c.relhasindex, c.relhasrules, '
      'c.relhastriggers, c.relrowsecurity, c.relforcerowsecurity, '
      'false AS relhasoids, c.relispartition, $options, c.reltablespace, '
      "CASE WHEN c.reloftype = 0 THEN '' ELSE "
      'c.reloftype::pg_catalog.regtype::pg_catalog.text END, '
      'c.relpersistence, c.relreplident, am.amname\n'
      'FROM pg_catalog.pg_class c\n '
      'LEFT JOIN pg_catalog.pg_class tc ON (c.reltoastrelid = tc.oid)\n'
      'LEFT JOIN pg_catalog.pg_am am ON (c.relam = am.oid)\n'
      "WHERE c.oid = '$oid';";
}

/// psql's `tableinfo`.
final class TableInfo {
  /// Reads the first row of [tableInfoSql].
  factory TableInfo.fromRow(PsqlResult r) {
    String at(int column) => r.value(0, column);
    bool flag(int column) => at(column) == 't';
    final ofType = at(11);
    return TableInfo._(
      checks: int.tryParse(at(0)) ?? 0,
      relkind: at(1).isEmpty ? '?' : at(1)[0],
      hasIndex: flag(2),
      hasRules: flag(3),
      hasTriggers: flag(4),
      rowSecurity: flag(5),
      forceRowSecurity: flag(6),
      hasOids: flag(7),
      isPartition: flag(8),
      reloptions: at(9),
      tablespace: int.tryParse(at(10)) ?? 0,
      ofType: ofType.isEmpty ? null : ofType,
      relpersistence: at(12),
      replident: at(13).isEmpty ? 'd' : at(13),
      accessMethod: r.isNull(0, 14) ? null : at(14),
    );
  }

  const TableInfo._({
    required this.checks,
    required this.relkind,
    required this.hasIndex,
    required this.hasRules,
    required this.hasTriggers,
    required this.rowSecurity,
    required this.forceRowSecurity,
    required this.hasOids,
    required this.isPartition,
    required this.reloptions,
    required this.tablespace,
    required this.ofType,
    required this.relpersistence,
    required this.replident,
    required this.accessMethod,
  });

  /// Number of CHECK constraints.
  final int checks;

  /// `r`, `v`, `m`, `i`, `S`, `t`, `c`, `f`, `p` or `I`.
  final String relkind;

  /// pg_class flags.
  final bool hasIndex;

  /// pg_class flags.
  final bool hasRules;

  /// pg_class flags.
  final bool hasTriggers;

  /// pg_class flags.
  final bool rowSecurity;

  /// pg_class flags.
  final bool forceRowSecurity;

  /// Always false on 12+.
  final bool hasOids;

  /// pg_class flags.
  final bool isPartition;

  /// `reloptions` (and `toast.` ones) joined, `+` only.
  final String reloptions;

  /// Tablespace OID, 0 for the database default.
  final int tablespace;

  /// `OF type` of a typed table.
  final String? ofType;

  /// `p`, `u` or `t`.
  final String relpersistence;

  /// Replica identity: `d`, `n`, `f` or `i`.
  final String replident;

  /// Table access method.
  final String? accessMethod;

  /// The relation kinds whose footers describe a table.
  bool get isTableLike =>
      relkind == 'r' ||
      relkind == 'm' ||
      relkind == 'f' ||
      relkind == 'p' ||
      relkind == 'I' ||
      relkind == 't';

  /// The title line, e.g. `Table "public.users"`.
  String title(String schema, String name) {
    final q = '"$schema.$name"';
    final unlogged = relpersistence == 'u';
    return switch (relkind) {
      'r' => unlogged ? 'Unlogged table $q' : 'Table $q',
      'v' => 'View $q',
      'm' => 'Materialized view $q',
      'i' => unlogged ? 'Unlogged index $q' : 'Index $q',
      'I' =>
        unlogged ? 'Unlogged partitioned index $q' : 'Partitioned index $q',
      't' => 'TOAST table $q',
      'c' => 'Composite type $q',
      'f' => 'Foreign table $q',
      'p' =>
        unlogged ? 'Unlogged partitioned table $q' : 'Partitioned table $q',
      _ => '?$relkind? $q',
    };
  }
}

/// The per-column query of `\d` and how to turn its rows into cells.
final class ColumnQuery {
  ColumnQuery._(this.sql, this.headers, this._columns, this._details);

  /// Builds the query for [info] (relation [oid]).
  factory ColumnQuery.build(
    TableInfo info,
    String oid, {
    required bool verbose,
    required int version,
  }) {
    final k = info.relkind;
    final details =
        k == 'r' || k == 'v' || k == 'm' || k == 'f' || k == 'c' || k == 'p';
    final cols = <String, int>{};
    var n = 0;
    final b = StringBuffer('SELECT a.attname');
    cols['name'] = n++;
    b.write(',\n  pg_catalog.format_type(a.atttypid, a.atttypmod)');
    cols['type'] = n++;
    final headers = ['Column', 'Type'];
    if (details) {
      b.write(
        ',\n  (SELECT pg_catalog.pg_get_expr(d.adbin, d.adrelid, true)'
        '\n   FROM pg_catalog.pg_attrdef d'
        '\n   WHERE d.adrelid = a.attrelid AND d.adnum = a.attnum AND '
        'a.atthasdef)'
        ',\n  a.attnotnull',
      );
      cols['default'] = n++;
      cols['notnull'] = n++;
      b.write(
        ',\n  (SELECT c.collname FROM pg_catalog.pg_collation c, '
        'pg_catalog.pg_type t\n'
        '   WHERE c.oid = a.attcollation AND t.oid = a.atttypid AND '
        'a.attcollation <> t.typcollation) AS attcollation',
      );
      cols['collation'] = n++;
      b.write(',\n  a.attidentity');
      cols['identity'] = n++;
      b.write(',\n  a.attgenerated');
      cols['generated'] = n++;
      headers.addAll(['Collation', 'Nullable', 'Default']);
    }
    if (k == 'i' || k == 'I') {
      b.write(
        ',\n  CASE WHEN a.attnum <= (SELECT i.indnkeyatts FROM '
        "pg_catalog.pg_index i WHERE i.indexrelid = '$oid') THEN 'yes' "
        "ELSE 'no' END AS is_key",
      );
      cols['iskey'] = n++;
      headers.add('Key?');
      b.write(
        ',\n  pg_catalog.pg_get_indexdef(a.attrelid, a.attnum, TRUE) AS '
        'indexdef',
      );
      cols['indexdef'] = n++;
      headers.add('Definition');
    }
    if (k == 'f') {
      b.write(
        ",\n  CASE WHEN attfdwoptions IS NULL THEN '' ELSE "
        "  '(' || pg_catalog.array_to_string(ARRAY(SELECT "
        "pg_catalog.quote_ident(option_name) || ' ' || "
        'pg_catalog.quote_literal(option_value)  FROM '
        "  pg_catalog.pg_options_to_table(attfdwoptions)), ', ') || ')' "
        'END AS attfdwoptions',
      );
      cols['fdw'] = n++;
      headers.add('FDW options');
    }
    if (verbose) {
      b.write(',\n  a.attstorage');
      cols['storage'] = n++;
      headers.add('Storage');
      if (version >= 140000 && (k == 'r' || k == 'p' || k == 'm')) {
        b.write(',\n  a.attcompression AS attcompression');
        cols['compression'] = n++;
        headers.add('Compression');
      }
      if (k == 'r' ||
          k == 'i' ||
          k == 'I' ||
          k == 'm' ||
          k == 'f' ||
          k == 'p') {
        b.write(
          ',\n  CASE WHEN a.attstattarget=-1 THEN NULL ELSE a.attstattarget '
          'END AS attstattarget',
        );
        cols['stattarget'] = n++;
        headers.add('Stats target');
      }
      if (k == 'r' ||
          k == 'v' ||
          k == 'm' ||
          k == 'f' ||
          k == 'c' ||
          k == 'p') {
        b.write(',\n  pg_catalog.col_description(a.attrelid, a.attnum)');
        cols['description'] = n++;
        headers.add('Description');
      }
    }
    b
      ..write('\nFROM pg_catalog.pg_attribute a')
      ..write(
        "\nWHERE a.attrelid = '$oid' AND a.attnum > 0 AND NOT a.attisdropped",
      )
      ..write('\nORDER BY a.attnum;');
    return ColumnQuery._(b.toString(), headers, cols, details);
  }

  /// The query.
  final String sql;

  /// Header row.
  final List<String> headers;

  final Map<String, int> _columns;
  final bool _details;

  /// The cells of row [i] of the query's [result].
  List<String> cells(PsqlResult result, int i) {
    String at(String key) => result.value(i, _columns[key]!);
    final cells = [at('name'), at('type')];
    if (_details) {
      cells
        ..add(at('collation'))
        ..add(at('notnull') == 't' ? 'not null' : '');
      final identity = at('identity');
      final generated = at('generated');
      cells.add(switch ((identity, generated)) {
        ('a', _) => 'generated always as identity',
        ('d', _) => 'generated by default as identity',
        (_, 's') => 'generated always as (${at('default')}) stored',
        (_, 'v') => 'generated always as (${at('default')})',
        _ => at('default'),
      });
    }
    if (_columns.containsKey('iskey')) cells.add(at('iskey'));
    if (_columns.containsKey('indexdef')) cells.add(at('indexdef'));
    if (_columns.containsKey('fdw')) cells.add(at('fdw'));
    if (_columns.containsKey('storage')) {
      cells.add(switch (at('storage')) {
        'p' => 'plain',
        'm' => 'main',
        'x' => 'extended',
        'e' => 'external',
        _ => '???',
      });
    }
    if (_columns.containsKey('compression')) {
      cells.add(switch (at('compression')) {
        'p' => 'pglz',
        'l' => 'lz4',
        '' => '',
        _ => '???',
      });
    }
    if (_columns.containsKey('stattarget')) cells.add(at('stattarget'));
    if (_columns.containsKey('description')) cells.add(at('description'));
    return cells;
  }
}
