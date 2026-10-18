// File: function_role_sql.dart
// Purpose: The catalog queries behind psql's \df (functions, with the
// a/n/p/t/w kind letters and argument-type patterns) and \du / \dg
// (roles, whose Attributes column psql builds on the client).
//
// Ported from src/bin/psql/describe.c (describeFunctions, describeRoles,
// add_role_attribute) - PostgreSQL License, (c) 1996-2026 PostgreSQL
// Global Development Group. See THIRD_PARTY_NOTICES.

// The SQL is assembled from psql's own string pieces, which join without
// spaces at commas and parentheses on purpose.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:dbase_postgresql/src/psql/describe/list_sql.dart';
import 'package:dbase_postgresql/src/psql/describe/psql_query.dart';
import 'package:dbase_postgresql/src/psql/describe/type_privilege_sql.dart';
import 'package:dbase_postgresql/src/psql/name_pattern.dart';
import 'package:dbase_postgresql/src/psql/print/print_table.dart';

/// The `\df` kind letters psql accepts.
const functionOptionLetters = 'anptwSx+';

/// describeFunctions: `\df[anptwS+]`. [kinds] are the letters after
/// `\df`; [argPatterns] the type patterns after the name pattern (`-`
/// means "no such argument").
String listFunctionsSql(
  ListContext context,
  String kinds,
  String? pattern,
  List<String> argPatterns, {
  required bool verbose,
  required bool showSystem,
}) {
  var showAggregate = kinds.contains('a');
  var showNormal = kinds.contains('n');
  var showProcedure = kinds.contains('p');
  var showTrigger = kinds.contains('t');
  var showWindow = kinds.contains('w');
  if (!showAggregate &&
      !showNormal &&
      !showProcedure &&
      !showTrigger &&
      !showWindow) {
    showAggregate = showNormal = showTrigger = showWindow = true;
    showProcedure = true;
  }

  final b = StringBuffer(
    'SELECT n.nspname as "Schema",\n'
    '  p.proname as "Name",\n'
    '  pg_catalog.pg_get_function_result(p.oid) as "Result data type",\n'
    '  pg_catalog.pg_get_function_arguments(p.oid) as '
    '"Argument data types",\n'
    ' CASE p.prokind\n'
    "  WHEN 'a' THEN 'agg'\n"
    "  WHEN 'w' THEN 'window'\n"
    "  WHEN 'p' THEN 'proc'\n"
    "  ELSE 'func'\n"
    ' END as "Type"',
  );
  if (verbose) {
    b.write(
      ',\n CASE\n'
      "  WHEN p.provolatile = 'i' THEN 'immutable'\n"
      "  WHEN p.provolatile = 's' THEN 'stable'\n"
      "  WHEN p.provolatile = 'v' THEN 'volatile'\n"
      ' END as "Volatility"'
      ',\n CASE\n'
      "  WHEN p.proparallel = 'r' THEN 'restricted'\n"
      "  WHEN p.proparallel = 's' THEN 'safe'\n"
      "  WHEN p.proparallel = 'u' THEN 'unsafe'\n"
      ' END as "Parallel"'
      ',\n pg_catalog.pg_get_userbyid(p.proowner) as "Owner"'
      ",\n CASE WHEN prosecdef THEN 'definer' ELSE 'invoker' END AS "
      '"Security"'
      ",\n CASE WHEN p.proleakproof THEN 'yes' ELSE 'no' END as "
      '"Leakproof?"'
      ',\n ${aclColumn('p.proacl')}'
      ',\n l.lanname as "Language"'
      ",\n CASE WHEN l.lanname IN ('internal', 'c') THEN p.prosrc END as "
      '"Internal name"'
      ",\n pg_catalog.obj_description(p.oid, 'pg_proc') as "
      '"Description"',
    );
  }
  b.write(
    '\nFROM pg_catalog.pg_proc p'
    '\n     LEFT JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace\n',
  );
  for (var i = 0; i < argPatterns.length; i++) {
    b.write(
      '     LEFT JOIN pg_catalog.pg_type t$i ON t$i.oid = p.proargtypes[$i]\n'
      '     LEFT JOIN pg_catalog.pg_namespace nt$i ON nt$i.oid = '
      't$i.typnamespace\n',
    );
  }
  if (verbose) {
    b.write('     LEFT JOIN pg_catalog.pg_language l ON l.oid = p.prolang\n');
  }

  var haveWhere = false;
  void and(String condition) {
    b
      ..write(haveWhere ? '      AND ' : 'WHERE ')
      ..write(condition);
    haveWhere = true;
  }

  if (showNormal &&
      showAggregate &&
      showProcedure &&
      showTrigger &&
      showWindow) {
    // Everything: no filter.
  } else if (showNormal) {
    if (!showAggregate) and("p.prokind <> 'a'\n");
    if (!showProcedure) and("p.prokind <> 'p'\n");
    if (!showTrigger) {
      and("p.prorettype <> 'pg_catalog.trigger'::pg_catalog.regtype\n");
    }
    if (!showWindow) and("p.prokind <> 'w'\n");
  } else {
    final options = [
      if (showAggregate) "p.prokind = 'a'\n",
      if (showTrigger)
        "p.prorettype = 'pg_catalog.trigger'::pg_catalog.regtype\n",
      if (showProcedure) "p.prokind = 'p'\n",
      if (showWindow) "p.prokind = 'w'\n",
    ];
    b
      ..write('WHERE (\n       ')
      ..write(options.join('       OR '))
      ..write('      )\n');
    haveWhere = true;
  }

  b.write(
    processNamePattern(
      pattern,
      haveWhere: haveWhere,
      schemaVar: 'n.nspname',
      nameVar: 'p.proname',
      visibilityRule: 'pg_catalog.pg_function_is_visible(p.oid)',
      currentDatabase: context.currentDatabase,
    ).sql,
  );
  for (var i = 0; i < argPatterns.length; i++) {
    if (argPatterns[i] != '-') {
      b.write(
        processNamePattern(
          mapTypenamePattern(argPatterns[i]),
          haveWhere: true,
          schemaVar: 'nt$i.nspname',
          nameVar: 't$i.typname',
          altNameVar: 'pg_catalog.format_type(t$i.oid, NULL)',
          visibilityRule: 'pg_catalog.pg_type_is_visible(t$i.oid)',
          currentDatabase: context.currentDatabase,
        ).sql,
      );
    } else {
      b.write('  AND t$i.typname IS NULL\n');
    }
  }
  if (!showSystem && pattern == null) {
    b.write(
      "      AND n.nspname <> 'pg_catalog'\n"
      "      AND n.nspname <> 'information_schema'\n",
    );
  }
  b.write('ORDER BY 1, 2, 4;');
  return b.toString();
}

/// describeRoles: `\du` / `\dg`.
String listRolesSql(
  ListContext context,
  String? pattern, {
  required bool verbose,
  required bool showSystem,
}) {
  final b = StringBuffer(
    'SELECT r.rolname, r.rolsuper, r.rolinherit,\n'
    '  r.rolcreaterole, r.rolcreatedb, r.rolcanlogin,\n'
    '  r.rolconnlimit, r.rolvaliduntil',
  );
  if (verbose) {
    b.write(
      "\n, pg_catalog.shobj_description(r.oid, 'pg_authid') AS description",
    );
  }
  b.write(
    '\n, r.rolreplication\n, r.rolbypassrls\nFROM pg_catalog.pg_roles r\n',
  );
  if (!showSystem && pattern == null) b.write("WHERE r.rolname !~ '^pg_'\n");
  b
    ..write(
      processNamePattern(
        pattern,
        haveWhere: false,
        nameVar: 'r.rolname',
        maxParts: 1,
        currentDatabase: context.currentDatabase,
      ).sql,
    )
    ..write('ORDER BY 1;');
  return b.toString();
}

/// The `List of roles` table from [listRolesSql]'s rows: psql builds the
/// Attributes column on the client.
PrintTable rolesTable(PsqlResult result, {required bool verbose}) {
  final rows = <List<String>>[];
  for (var i = 0; i < result.rows.length; i++) {
    final attributes = <String>[];
    bool isTrue(int column) => result.value(i, column) == 't';
    if (isTrue(1)) attributes.add('Superuser');
    if (!isTrue(2)) attributes.add('No inheritance');
    if (isTrue(3)) attributes.add('Create role');
    if (isTrue(4)) attributes.add('Create DB');
    if (!isTrue(5)) attributes.add('Cannot login');
    if (isTrue(verbose ? 9 : 8)) attributes.add('Replication');
    if (isTrue(verbose ? 10 : 9)) attributes.add('Bypass RLS');
    final text = StringBuffer(attributes.join(', '));
    final connections = int.tryParse(result.value(i, 6)) ?? -1;
    if (connections >= 0) {
      if (text.isNotEmpty) text.write('\n');
      text.write(
        connections == 0
            ? 'No connections'
            : connections == 1
            ? '1 connection'
            : '$connections connections',
      );
    }
    final validUntil = result.value(i, 7);
    if (validUntil.isNotEmpty) {
      if (text.isNotEmpty) text.write('\n');
      text.write('Password valid until $validUntil');
    }
    rows.add([
      result.value(i, 0),
      text.toString(),
      if (verbose) result.value(i, 8),
    ]);
  }
  return PrintTable(
    title: 'List of roles',
    headers: ['Role name', 'Attributes', if (verbose) 'Description'],
    rows: rows,
    defaultFooter: false,
  );
}
