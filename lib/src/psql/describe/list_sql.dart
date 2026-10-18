// File: list_sql.dart
// Purpose: The catalog queries behind psql's list commands: \dt \di \dv
// \dm \ds \dE (and \d without a pattern), \dn, \dx and \l.
// Version-gated for PostgreSQL 13–18; older servers get the 13 shape.
//
// Ported from src/bin/psql/describe.c (listTables, listSchemas,
// listExtensions, listAllDbs, printACLColumn) - PostgreSQL License,
// (c) 1996-2026 PostgreSQL Global Development Group. See
// THIRD_PARTY_NOTICES.

// The SQL is assembled from psql's own string pieces, which join without
// spaces at commas and parentheses on purpose.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:dbase_postgresql/src/psql/name_pattern.dart';

/// Which relation kinds a `\d?` list shows (the letters after `\d`).
final class RelationKinds {
  /// Reads [letters] (`t`, `i`, `v`, `m`, `s`, `E`; others ignored).
  /// None of them means psql's default `\dtvmsE`.
  factory RelationKinds.parse(String letters) {
    final t = letters.contains('t');
    final i = letters.contains('i');
    final v = letters.contains('v');
    final m = letters.contains('m');
    final s = letters.contains('s');
    final e = letters.contains('E');
    final count = [t, i, v, m, s, e].where((x) => x).length;
    if (count == 0) {
      return const RelationKinds._(
        tables: true,
        indexes: false,
        views: true,
        matViews: true,
        sequences: true,
        foreign: true,
        count: 0,
      );
    }
    return RelationKinds._(
      tables: t,
      indexes: i,
      views: v,
      matViews: m,
      sequences: s,
      foreign: e,
      count: count,
    );
  }

  const RelationKinds._({
    required this.tables,
    required this.indexes,
    required this.views,
    required this.matViews,
    required this.sequences,
    required this.foreign,
    required this.count,
  });

  /// Shown kinds.
  final bool tables;

  /// Shown kinds.
  final bool indexes;

  /// Shown kinds.
  final bool views;

  /// Shown kinds.
  final bool matViews;

  /// Shown kinds.
  final bool sequences;

  /// Shown kinds.
  final bool foreign;

  /// Kinds asked for explicitly (0 for the default set).
  final int count;

  /// psql's title for the list.
  String get title => count != 1
      ? 'List of relations'
      : tables
      ? 'List of tables'
      : indexes
      ? 'List of indexes'
      : views
      ? 'List of views'
      : matViews
      ? 'List of materialized views'
      : sequences
      ? 'List of sequences'
      : 'List of foreign tables';

  /// psql's message when nothing matched.
  String notFound(String? pattern) {
    final what = count != 1
        ? 'relations'
        : tables
        ? 'tables'
        : indexes
        ? 'indexes'
        : views
        ? 'views'
        : matViews
        ? 'materialized views'
        : sequences
        ? 'sequences'
        : 'foreign tables';
    return pattern == null
        ? 'Did not find any $what.'
        : 'Did not find any $what named "$pattern".';
  }
}

/// Shared inputs of the list queries.
final class ListContext {
  /// Creates the context.
  const ListContext({required this.version, this.currentDatabase});

  /// Server version number (`170002`).
  final int version;

  /// For `db.schema.name` patterns.
  final String? currentDatabase;
}

/// Hides pg_catalog and information_schema when there is no pattern.
const notSystemSchemas =
    "      AND n.nspname <> 'pg_catalog'\n"
    "      AND n.nspname <> 'information_schema'\n";

/// processNamePattern's clause for the list queries.
String namePatternSql(
  ListContext context,
  String? pattern, {
  required bool haveWhere,
  String? schemaVar,
  String? nameVar,
  String? altNameVar,
  String? visibility,
  int maxParts = 3,
}) => processNamePattern(
  pattern,
  haveWhere: haveWhere,
  schemaVar: schemaVar,
  nameVar: nameVar,
  altNameVar: altNameVar,
  visibilityRule: visibility,
  maxParts: maxParts,
  currentDatabase: context.currentDatabase,
).sql;

/// printACLColumn.
String aclColumn(String column) =>
    "CASE WHEN pg_catalog.array_length($column, 1) = 0 THEN '(none)'"
    " ELSE pg_catalog.array_to_string($column, E'\\n')"
    ' END AS "Access privileges"';

/// listTables: `\dt`, `\di`, `\dv`, `\dm`, `\ds`, `\dE` and `\d`.
String listTablesSql(
  ListContext context,
  RelationKinds kinds,
  String? pattern, {
  required bool verbose,
  required bool showSystem,
}) {
  final b = StringBuffer()
    ..write(
      'SELECT n.nspname as "Schema",\n'
      '  c.relname as "Name",\n'
      "  CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view'"
      " WHEN 'm' THEN 'materialized view' WHEN 'i' THEN 'index'"
      " WHEN 'S' THEN 'sequence' WHEN 't' THEN 'TOAST table'"
      " WHEN 'f' THEN 'foreign table' WHEN 'p' THEN 'partitioned table'"
      " WHEN 'I' THEN 'partitioned index' END as \"Type\",\n"
      '  pg_catalog.pg_get_userbyid(c.relowner) as "Owner"',
    );
  if (kinds.indexes) b.write(',\n  c2.relname as "Table"');
  final showAm = kinds.tables || kinds.matViews || kinds.indexes;
  if (verbose) {
    b.write(
      ",\n  CASE c.relpersistence WHEN 'p' THEN 'permanent' "
      "WHEN 't' THEN 'temporary' WHEN 'u' THEN 'unlogged' "
      'END as "Persistence"',
    );
    if (showAm) b.write(',\n  am.amname as "Access method"');
    b.write(
      ',\n  pg_catalog.pg_size_pretty(pg_catalog.pg_table_size(c.oid))'
      ' as "Size"'
      ",\n  pg_catalog.obj_description(c.oid, 'pg_class') as "
      '"Description"',
    );
  }
  b.write(
    '\nFROM pg_catalog.pg_class c'
    '\n     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace',
  );
  if (showAm) {
    b.write('\n     LEFT JOIN pg_catalog.pg_am am ON am.oid = c.relam');
  }
  if (kinds.indexes) {
    b.write(
      '\n     LEFT JOIN pg_catalog.pg_index i ON i.indexrelid = c.oid'
      '\n     LEFT JOIN pg_catalog.pg_class c2 ON i.indrelid = c2.oid',
    );
  }
  b.write('\nWHERE c.relkind IN (');
  if (kinds.tables) {
    b.write("'r','p',");
    if (showSystem || pattern != null) b.write("'t',");
  }
  if (kinds.views) b.write("'v',");
  if (kinds.matViews) b.write("'m',");
  if (kinds.indexes) b.write("'i','I',");
  if (kinds.sequences) b.write("'S',");
  if (showSystem || pattern != null) b.write("'s',");
  if (kinds.foreign) b.write("'f',");
  b.write("'')\n");
  if (!showSystem && pattern == null) {
    b.write(
      "      AND n.nspname <> 'pg_catalog'\n"
      "      AND n.nspname !~ '^pg_toast'\n"
      "      AND n.nspname <> 'information_schema'\n",
    );
  }
  b
    ..write(
      namePatternSql(
        context,
        pattern,
        haveWhere: true,
        schemaVar: 'n.nspname',
        nameVar: 'c.relname',
        visibility: 'pg_catalog.pg_table_is_visible(c.oid)',
      ),
    )
    ..write('ORDER BY 1,2;');
  return b.toString();
}

/// listSchemas: `\dn`.
String listSchemasSql(
  ListContext context,
  String? pattern, {
  required bool verbose,
  required bool showSystem,
}) {
  final b = StringBuffer(
    'SELECT n.nspname AS "Name",\n'
    '  pg_catalog.pg_get_userbyid(n.nspowner) AS "Owner"',
  );
  if (verbose) {
    b.write(
      ',\n  ${aclColumn('n.nspacl')}'
      ",\n  pg_catalog.obj_description(n.oid, 'pg_namespace') AS "
      '"Description"',
    );
  }
  b.write('\nFROM pg_catalog.pg_namespace n\n');
  final hideSystem = !showSystem && pattern == null;
  if (hideSystem) {
    b.write(
      "WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'\n",
    );
  }
  b
    ..write(
      namePatternSql(
        context,
        pattern,
        haveWhere: hideSystem,
        nameVar: 'n.nspname',
        maxParts: 2,
      ),
    )
    ..write('ORDER BY 1;');
  return b.toString();
}

/// listExtensions: `\dx`.
String listExtensionsSql(ListContext context, String? pattern) =>
    'SELECT e.extname AS "Name", '
    'e.extversion AS "Version", ae.default_version AS "Default version",'
    'n.nspname AS "Schema", d.description AS "Description"\n'
    'FROM pg_catalog.pg_extension e '
    'LEFT JOIN pg_catalog.pg_namespace n ON n.oid = e.extnamespace '
    'LEFT JOIN pg_catalog.pg_description d ON d.objoid = e.oid '
    "AND d.classoid = 'pg_catalog.pg_extension'::pg_catalog.regclass "
    'LEFT JOIN pg_catalog.pg_available_extensions() '
    'ae(name, default_version, comment) ON ae.name = e.extname\n'
    '${namePatternSql(
      context,
      pattern,
      haveWhere: false,
      nameVar: 'e.extname', //
      maxParts: 1,
    )}'
    'ORDER BY 1;';

/// listAllDbs: `\l`.
String listDatabasesSql(
  ListContext context,
  String? pattern, {
  required bool verbose,
}) {
  final v = context.version;
  final b = StringBuffer(
    'SELECT\n'
    '  d.datname as "Name",\n'
    '  pg_catalog.pg_get_userbyid(d.datdba) as "Owner",\n'
    '  pg_catalog.pg_encoding_to_char(d.encoding) as "Encoding",\n',
  );
  if (v >= 150000) {
    b.write(
      "  CASE d.datlocprovider WHEN 'b' THEN 'builtin' WHEN 'c' THEN 'libc' "
      "WHEN 'i' THEN 'icu' END AS \"Locale Provider\",\n",
    );
  } else {
    b.write("  'libc' AS \"Locale Provider\",\n");
  }
  b.write(
    '  d.datcollate as "Collate",\n'
    '  d.datctype as "Ctype",\n',
  );
  if (v >= 170000) {
    b.write('  d.datlocale as "Locale",\n');
  } else if (v >= 150000) {
    b.write('  d.daticulocale as "Locale",\n');
  } else {
    b.write('  NULL as "Locale",\n');
  }
  b
    ..write(
      v >= 160000
          ? '  d.daticurules as "ICU Rules",\n'
          : '  NULL as "ICU Rules",\n',
    )
    ..write('  ${aclColumn('d.datacl')}');
  if (verbose) {
    b.write(
      ",\n  CASE WHEN pg_catalog.has_database_privilege(d.datname, 'CONNECT')\n"
      "       OR pg_catalog.pg_has_role('pg_read_all_stats', 'USAGE')\n"
      '       THEN pg_catalog.pg_size_pretty('
      'pg_catalog.pg_database_size(d.datname))\n'
      "       ELSE 'No Access'\n"
      '  END as "Size"'
      ',\n  t.spcname as "Tablespace"'
      ",\n  pg_catalog.shobj_description(d.oid, 'pg_database') as "
      '"Description"',
    );
  }
  b.write('\nFROM pg_catalog.pg_database d\n');
  if (verbose) {
    b.write('  JOIN pg_catalog.pg_tablespace t on d.dattablespace = t.oid\n');
  }
  if (pattern != null) {
    b.write(
      namePatternSql(
        context,
        pattern,
        haveWhere: false,
        nameVar: 'd.datname',
        maxParts: 1,
      ),
    );
  }
  b.write('ORDER BY 1;');
  return b.toString();
}
