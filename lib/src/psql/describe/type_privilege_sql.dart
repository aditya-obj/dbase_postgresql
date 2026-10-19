// File: type_privilege_sql.dart
// Purpose: The catalog queries behind psql's \dT (types), \dD (domains)
// and \dp / \z (access privileges). Version-gated like list_sql.dart.
//
// Ported from src/bin/psql/describe.c (describeTypes,
// map_typename_pattern, listDomains, permissionsList) - PostgreSQL
// License, (c) 1996-2026 PostgreSQL Global Development Group. See
// THIRD_PARTY_NOTICES.

// The SQL is assembled from psql's own string pieces, which join without
// spaces at commas and parentheses on purpose.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:dabase_postgresql/src/psql/describe/list_sql.dart';

const _typenameMap = {
  'decimal': 'numeric',
  'float': 'double precision',
  'int': 'integer',
  'bool[]': 'boolean[]',
  'decimal[]': 'numeric[]',
  'float[]': 'double precision[]',
  'float4[]': 'real[]',
  'float8[]': 'double precision[]',
  'int[]': 'integer[]',
  'int2[]': 'smallint[]',
  'int4[]': 'integer[]',
  'int8[]': 'bigint[]',
  'time[]': 'time without time zone[]',
  'timetz[]': 'time with time zone[]',
  'timestamp[]': 'timestamp without time zone[]',
  'timestamptz[]': 'timestamp with time zone[]',
  'varbit[]': 'bit varying[]',
  'varchar[]': 'character varying[]',
};

/// map_typename_pattern: grammar spellings to canonical type names.
String? mapTypenamePattern(String? pattern) =>
    pattern == null ? null : _typenameMap[pattern.toLowerCase()] ?? pattern;

/// describeTypes: `\dT`.
String listTypesSql(
  ListContext context,
  String? pattern, {
  required bool verbose,
  required bool showSystem,
}) {
  final b = StringBuffer(
    'SELECT n.nspname as "Schema",\n'
    '  pg_catalog.format_type(t.oid, NULL) AS "Name",\n',
  );
  if (verbose) {
    b.write(
      '  t.typname AS "Internal name",\n'
      '  CASE WHEN t.typrelid != 0\n'
      "      THEN CAST('tuple' AS pg_catalog.text)\n"
      '    WHEN t.typlen < 0\n'
      "      THEN CAST('var' AS pg_catalog.text)\n"
      '    ELSE CAST(t.typlen AS pg_catalog.text)\n'
      '  END AS "Size",\n'
      '  pg_catalog.array_to_string(\n'
      '      ARRAY(\n'
      '          SELECT e.enumlabel\n'
      '          FROM pg_catalog.pg_enum e\n'
      '          WHERE e.enumtypid = t.oid\n'
      '          ORDER BY e.enumsortorder\n'
      '      ),\n'
      "      E'\\n'\n"
      '  ) AS "Elements",\n'
      '  pg_catalog.pg_get_userbyid(t.typowner) AS "Owner",\n'
      '${aclColumn('t.typacl')},\n  ',
    );
  }
  b.write(
    "  pg_catalog.obj_description(t.oid, 'pg_type') as \"Description\"\n"
    'FROM pg_catalog.pg_type t\n'
    '     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace\n'
    'WHERE (t.typrelid = 0 '
    "OR (SELECT c.relkind = 'c' FROM pg_catalog.pg_class c "
    'WHERE c.oid = t.typrelid))\n',
  );
  if (pattern == null || !pattern.contains('[]')) {
    b.write(
      '  AND NOT EXISTS(SELECT 1 FROM pg_catalog.pg_type el '
      'WHERE el.oid = t.typelem AND el.typarray = t.oid)\n',
    );
  }
  if (!showSystem && pattern == null) b.write(notSystemSchemas);
  b
    ..write(
      namePatternSql(
        context,
        mapTypenamePattern(pattern),
        haveWhere: true,
        schemaVar: 'n.nspname',
        nameVar: 't.typname',
        altNameVar: 'pg_catalog.format_type(t.oid, NULL)',
        visibility: 'pg_catalog.pg_type_is_visible(t.oid)',
      ),
    )
    ..write('ORDER BY 1, 2;');
  return b.toString();
}

/// listDomains: `\dD`.
String listDomainsSql(
  ListContext context,
  String? pattern, {
  required bool verbose,
  required bool showSystem,
}) {
  final b = StringBuffer(
    'SELECT n.nspname as "Schema",\n'
    '       t.typname as "Name",\n'
    '       pg_catalog.format_type(t.typbasetype, t.typtypmod) as "Type",\n'
    '       (SELECT c.collname FROM pg_catalog.pg_collation c, '
    'pg_catalog.pg_type bt\n'
    '        WHERE c.oid = t.typcollation AND bt.oid = t.typbasetype '
    'AND t.typcollation <> bt.typcollation) as "Collation",\n'
    "       CASE WHEN t.typnotnull THEN 'not null' END as \"Nullable\",\n"
    '       t.typdefault as "Default",\n'
    '       pg_catalog.array_to_string(ARRAY(\n'
    '         SELECT pg_catalog.pg_get_constraintdef(r.oid, true) '
    'FROM pg_catalog.pg_constraint r WHERE t.oid = r.contypid '
    "AND r.contype = 'c' ORDER BY r.conname\n"
    "       ), ' ') as \"Check\"",
  );
  if (verbose) {
    b.write(
      ',\n  ${aclColumn('t.typacl')}'
      ',\n       d.description as "Description"',
    );
  }
  b.write(
    '\nFROM pg_catalog.pg_type t\n'
    '     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = t.typnamespace\n',
  );
  if (verbose) {
    b.write(
      '     LEFT JOIN pg_catalog.pg_description d '
      'ON d.classoid = t.tableoid AND d.objoid = t.oid '
      'AND d.objsubid = 0\n',
    );
  }
  b.write("WHERE t.typtype = 'd'\n");
  if (!showSystem && pattern == null) b.write(notSystemSchemas);
  b
    ..write(
      namePatternSql(
        context,
        pattern,
        haveWhere: true,
        schemaVar: 'n.nspname',
        nameVar: 't.typname',
        visibility: 'pg_catalog.pg_type_is_visible(t.oid)',
      ),
    )
    ..write('ORDER BY 1, 2;');
  return b.toString();
}

/// permissionsList: `\dp` (and `\z`).
String permissionsSql(
  ListContext context,
  String? pattern, {
  required bool showSystem,
}) {
  final b = StringBuffer(
    'SELECT n.nspname as "Schema",\n'
    '  c.relname as "Name",\n'
    "  CASE c.relkind WHEN 'r' THEN 'table' WHEN 'v' THEN 'view'"
    " WHEN 'm' THEN 'materialized view' WHEN 'S' THEN 'sequence'"
    " WHEN 'f' THEN 'foreign table' WHEN 'p' THEN 'partitioned table'"
    ' END as "Type",\n'
    '  ${aclColumn('c.relacl')}'
    ',\n  pg_catalog.array_to_string(ARRAY(\n'
    r"    SELECT attname || E':\n  ' || "
    "pg_catalog.array_to_string(attacl, E'\\n  ')\n"
    '    FROM pg_catalog.pg_attribute a\n'
    '    WHERE attrelid = c.oid AND NOT attisdropped '
    'AND attacl IS NOT NULL\n'
    "  ), E'\\n') AS \"Column privileges\""
    ',\n  pg_catalog.array_to_string(ARRAY(\n'
    '    SELECT polname\n'
    '    || CASE WHEN NOT polpermissive THEN\n'
    "       E' (RESTRICTIVE)'\n"
    "       ELSE '' END\n"
    "    || CASE WHEN polcmd != '*' THEN\n"
    "           E' (' || polcmd::pg_catalog.text || E'):'\n"
    "       ELSE E':'\n"
    '       END\n'
    '    || CASE WHEN polqual IS NOT NULL THEN\n'
    "           E'\\n  (u): ' || pg_catalog.pg_get_expr(polqual, polrelid)\n"
    "       ELSE E''\n"
    '       END\n'
    '    || CASE WHEN polwithcheck IS NOT NULL THEN\n'
    r"           E'\n  (c): ' || "
    'pg_catalog.pg_get_expr(polwithcheck, polrelid)\n'
    "       ELSE E''\n"
    '       END'
    "    || CASE WHEN polroles <> '{0}' THEN\n"
    "           E'\\n  to: ' || pg_catalog.array_to_string(\n"
    '               ARRAY(\n'
    '                   SELECT rolname\n'
    '                   FROM pg_catalog.pg_roles\n'
    '                   WHERE oid = ANY (polroles)\n'
    '                   ORDER BY 1\n'
    "               ), E', ')\n"
    "       ELSE E''\n"
    '       END\n'
    '    FROM pg_catalog.pg_policy pol\n'
    "    WHERE polrelid = c.oid), E'\\n')\n"
    '    AS "Policies"'
    '\nFROM pg_catalog.pg_class c\n'
    '     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace\n'
    "WHERE c.relkind IN ('r','v','m','S','f','p')\n",
  );
  if (!showSystem && pattern == null) b.write(notSystemSchemas);
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
    ..write('ORDER BY 1, 2;');
  return b.toString();
}
