// File: table_details.dart
// Purpose: psql's `\d name` / `\d+ name`: finds the matching relations,
// then describes each one (columns table with title, then footers:
// indexes, constraints, references, policies, triggers, partitions...).
// Sequences get their own table.
//
// Ported from src/bin/psql/describe.c (describeTableDetails,
// describeOneTableDetails) - PostgreSQL License, (c) 1996-2026 PostgreSQL
// Global Development Group. See THIRD_PARTY_NOTICES.

import 'package:dbase_postgresql/src/psql/describe/describe_context.dart';
import 'package:dbase_postgresql/src/psql/describe/psql_query.dart';
import 'package:dbase_postgresql/src/psql/describe/table_footers.dart';
import 'package:dbase_postgresql/src/psql/describe/table_info.dart';
import 'package:dbase_postgresql/src/psql/name_pattern.dart';
import 'package:dbase_postgresql/src/psql/print/print_table.dart';

/// The query that finds the relations `\d pattern` describes.
String findRelationsSql(
  DescribeContext context,
  String? pattern, {
  required bool showSystem,
}) {
  final hideSystem = !showSystem && pattern == null;
  final b = StringBuffer(
    'SELECT c.oid,\n'
    '  n.nspname,\n'
    '  c.relname\n'
    'FROM pg_catalog.pg_class c\n'
    '     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace\n',
  );
  if (hideSystem) {
    b.write(
      "WHERE n.nspname <> 'pg_catalog'\n"
      "      AND n.nspname <> 'information_schema'\n",
    );
  }
  b
    ..write(
      processNamePattern(
        pattern,
        haveWhere: hideSystem,
        schemaVar: 'n.nspname',
        nameVar: 'c.relname',
        visibilityRule: 'pg_catalog.pg_table_is_visible(c.oid)',
        currentDatabase: context.currentDatabase,
      ).sql,
    )
    ..write('ORDER BY 2, 3;');
  return b.toString();
}

/// describeTableDetails: one output per matching relation, or psql's
/// "Did not find any relation named" error.
Future<List<PsqlOutput>> describeTableDetails(
  DescribeContext context,
  String pattern, {
  required bool verbose,
  required bool showSystem,
}) async {
  final found = await context.query(
    findRelationsSql(context, pattern, showSystem: showSystem),
  );
  if (found.rows.isEmpty) {
    return [
      PsqlMessageOutput(
        'Did not find any relation named "$pattern".',
        isError: true,
      ),
    ];
  }
  final outputs = <PsqlOutput>[];
  for (var i = 0; i < found.rows.length; i++) {
    final output = await describeOneTable(
      context,
      schema: found.value(i, 1),
      name: found.value(i, 2),
      oid: found.value(i, 0),
      verbose: verbose,
    );
    outputs.add(output);
    if (output is PsqlMessageOutput && output.isError) break;
  }
  return outputs;
}

/// describeOneTableDetails for the relation [oid] (`schema.name`).
Future<PsqlOutput> describeOneTable(
  DescribeContext context, {
  required String schema,
  required String name,
  required String oid,
  required bool verbose,
}) async {
  if (!RegExp(r'^[0-9]+$').hasMatch(oid)) {
    return PsqlMessageOutput('invalid OID: $oid', isError: true);
  }
  final infoResult = await context.query(tableInfoSql(oid, verbose: verbose));
  if (infoResult.rows.isEmpty) {
    return PsqlMessageOutput(
      'Did not find any relation with OID $oid.',
      isError: true,
    );
  }
  final info = TableInfo.fromRow(infoResult);

  if (info.relkind == 'S') {
    return await _describeSequence(context, info, schema, name, oid);
  }

  final columns = ColumnQuery.build(
    info,
    oid,
    verbose: verbose,
    version: context.version,
  );
  final res = await context.query(columns.sql);

  final rows = <List<String>>[
    for (var i = 0; i < res.rows.length; i++) columns.cells(res, i),
  ];
  final footers = await tableFooters(
    context,
    info,
    schema: schema,
    oid: oid,
    verbose: verbose,
  );
  return PsqlTableOutput(
    PrintTable(
      title: info.title(schema, name),
      headers: columns.headers,
      rows: rows,
      footers: footers,
      defaultFooter: false,
      forceNotExpanded: true,
    ),
  );
}

Future<PsqlOutput> _describeSequence(
  DescribeContext context,
  TableInfo info,
  String schema,
  String name,
  String oid,
) async {
  final res = await context.query(
    'SELECT pg_catalog.format_type(seqtypid, NULL) AS "Type",\n'
    '       seqstart AS "Start",\n'
    '       seqmin AS "Minimum",\n'
    '       seqmax AS "Maximum",\n'
    '       seqincrement AS "Increment",\n'
    "       CASE WHEN seqcycle THEN 'yes' ELSE 'no' END AS \"Cycles?\",\n"
    '       seqcache AS "Cache"\n'
    'FROM pg_catalog.pg_sequence\n'
    "WHERE seqrelid = '$oid';",
  );
  final owner = await context.query(
    "SELECT pg_catalog.quote_ident(nspname) || '.' ||"
    "\n   pg_catalog.quote_ident(relname) || '.' ||"
    '\n   pg_catalog.quote_ident(attname),'
    '\n   d.deptype'
    '\nFROM pg_catalog.pg_class c'
    '\nINNER JOIN pg_catalog.pg_depend d ON c.oid=d.refobjid'
    '\nINNER JOIN pg_catalog.pg_namespace n ON n.oid=c.relnamespace'
    '\nINNER JOIN pg_catalog.pg_attribute a ON ('
    '\n a.attrelid=c.oid AND'
    '\n a.attnum=d.refobjsubid)'
    "\nWHERE d.classid='pg_catalog.pg_class'::pg_catalog.regclass"
    "\n AND d.refclassid='pg_catalog.pg_class'::pg_catalog.regclass"
    "\n AND d.objid='$oid'"
    "\n AND d.deptype IN ('a', 'i')",
  );
  String? footer;
  if (owner.rows.length == 1) {
    footer = switch (owner.value(0, 1)) {
      'a' => 'Owned by: ${owner.value(0, 0)}',
      'i' => 'Sequence for identity column: ${owner.value(0, 0)}',
      _ => null,
    };
  }
  final title = info.relpersistence == 'u'
      ? 'Unlogged sequence "$schema.$name"'
      : 'Sequence "$schema.$name"';
  final table = queryTable(
    res,
    title: title,
    nullDisplay: context.nullDisplay,
    footers: footer == null ? null : [footer],
  );
  return PsqlTableOutput(
    PrintTable(
      headers: table.headers,
      aligns: table.aligns,
      rows: table.rows,
      title: table.title,
      footers: table.footers,
      defaultFooter: false,
    ),
  );
}
