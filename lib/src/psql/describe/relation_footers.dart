// File: relation_footers.dart
// Purpose: The longer footer sections of psql's `\d name`: an index's
// summary line, a table's indexes, constraints, references, policies,
// statistics objects, rules, publications and not-null constraints, and
// the trigger lists.
//
// Ported from src/bin/psql/describe.c (describeOneTableDetails) -
// PostgreSQL License, (c) 1996-2026 PostgreSQL Global Development Group.
// See THIRD_PARTY_NOTICES.

// The SQL is assembled from psql's own string pieces, which join without
// spaces at commas and parentheses on purpose.
// ignore_for_file: missing_whitespace_between_adjacent_strings

import 'package:dabase_postgresql/src/psql/describe/describe_context.dart';
import 'package:dabase_postgresql/src/psql/describe/table_footers.dart';
import 'package:dabase_postgresql/src/psql/describe/table_info.dart';

/// The one-line summary under an index (`primary key, btree, for table
/// "public.t"`), or `null` when the index row is missing.
Future<String?> indexFooter(
  DescribeContext context,
  String schema,
  String oid,
) async {
  final v = context.version;
  const deferrable =
      '(NOT i.indimmediate) AND EXISTS (SELECT 1 FROM pg_catalog.pg_constraint '
      'WHERE conrelid = i.indrelid AND conindid = i.indexrelid AND '
      "contype IN ('p','u','x') AND ";
  final r = await context.query(
    'SELECT i.indisunique, i.indisprimary, i.indisclustered, '
    'i.indisvalid,\n'
    '  ${deferrable}condeferrable) AS condeferrable,\n'
    '  ${deferrable}condeferred) AS condeferred,\n'
    'i.indisreplident,\n'
    '${v >= 150000 //
            ? 'i.indnullsnotdistinct' : 'false AS indnullsnotdistinct'},\n'
    '  a.amname, c2.relname, '
    'pg_catalog.pg_get_expr(i.indpred, i.indrelid, true)\n'
    'FROM pg_catalog.pg_index i, pg_catalog.pg_class c, '
    'pg_catalog.pg_class c2, pg_catalog.pg_am a\n'
    "WHERE i.indexrelid = c.oid AND c.oid = '$oid' AND c.relam = a.oid\n"
    'AND i.indrelid = c2.oid;',
  );
  if (r.rows.length != 1) return null;
  bool flag(int column) => r.value(0, column) == 't';
  final b = StringBuffer();
  if (flag(1)) {
    b.write('primary key, ');
  } else if (flag(0)) {
    b.write('unique');
    if (flag(7)) b.write(' nulls not distinct');
    b.write(', ');
  }
  b.write('${r.value(0, 8)}, for table "$schema.${r.value(0, 9)}"');
  final predicate = r.value(0, 10);
  if (predicate.isNotEmpty) b.write(', predicate ($predicate)');
  if (flag(2)) b.write(', clustered');
  if (!flag(3)) b.write(', invalid');
  if (flag(4)) b.write(', deferrable');
  if (flag(5)) b.write(', initially deferred');
  if (flag(6)) b.write(', replica identity');
  return b.toString();
}

/// The table footers from "Indexes:" to "Not-null constraints:".
Future<void> addConstraintFooters(
  DescribeContext context,
  List<String> footers,
  TableInfo info,
  String oid, {
  required bool verbose,
}) async {
  final q = context.query;
  final v = context.version;

  if (info.hasIndex) {
    final r = await q(
      'SELECT c2.relname, i.indisprimary, i.indisunique, '
      'i.indisclustered, i.indisvalid, '
      'pg_catalog.pg_get_indexdef(i.indexrelid, 0, true),\n  '
      'pg_catalog.pg_get_constraintdef(con.oid, true), '
      'contype, condeferrable, condeferred'
      ', i.indisreplident'
      ', c2.reltablespace'
      '${v >= 180000 ? ', con.conperiod' : ', false AS conperiod'}'
      '\nFROM pg_catalog.pg_class c, pg_catalog.pg_class c2, '
      'pg_catalog.pg_index i\n'
      '  LEFT JOIN pg_catalog.pg_constraint con ON (conrelid = i.indrelid '
      "AND conindid = i.indexrelid AND contype IN ('p','u','x'))\n"
      "WHERE c.oid = '$oid' AND c.oid = i.indrelid AND "
      'i.indexrelid = c2.oid\n'
      'ORDER BY i.indisprimary DESC, c2.relname;',
    );
    if (r.rows.isNotEmpty) footers.add('Indexes:');
    for (var i = 0; i < r.rows.length; i++) {
      bool flag(int column) => r.value(i, column) == 't';
      final b = StringBuffer('    "${r.value(i, 0)}"');
      if (r.value(i, 7) == 'x' || flag(12)) {
        b.write(' ${r.value(i, 6)}');
      } else {
        if (flag(1)) {
          b.write(' PRIMARY KEY,');
        } else if (flag(2)) {
          b.write(r.value(i, 7) == 'u' ? ' UNIQUE CONSTRAINT,' : ' UNIQUE,');
        }
        var indexdef = r.value(i, 5);
        final using = indexdef.indexOf(' USING ');
        if (using >= 0) indexdef = indexdef.substring(using + 7);
        b.write(' $indexdef');
        if (flag(8)) b.write(' DEFERRABLE');
        if (flag(9)) b.write(' INITIALLY DEFERRED');
      }
      if (flag(3)) b.write(' CLUSTER');
      if (!flag(4)) b.write(' INVALID');
      if (flag(10)) b.write(' REPLICA IDENTITY');
      footers.add(b.toString());
      await addTablespaceFooter(
        context,
        footers,
        'i',
        int.tryParse(r.value(i, 11)) ?? 0,
        newLine: false,
      );
    }
  }

  if (info.checks > 0) {
    final r = await q(
      'SELECT r.conname, pg_catalog.pg_get_constraintdef(r.oid, true)\n'
      'FROM pg_catalog.pg_constraint r\n'
      "WHERE r.conrelid = '$oid' AND r.contype = 'c'\n"
      'ORDER BY 1;',
    );
    if (r.rows.isNotEmpty) footers.add('Check constraints:');
    for (var i = 0; i < r.rows.length; i++) {
      footers.add('    "${r.value(i, 0)}" ${r.value(i, 1)}');
    }
  }

  final partitionTree = info.isPartition || info.relkind == 'p';
  final fks = await q(
    partitionTree
        ? "SELECT conrelid = '$oid'::pg_catalog.regclass AS sametable,\n"
              '       conname,\n'
              '       pg_catalog.pg_get_constraintdef(oid, true) AS condef,\n'
              '       conrelid::pg_catalog.regclass AS ontable\n'
              '  FROM pg_catalog.pg_constraint,\n'
              "       pg_catalog.pg_partition_ancestors('$oid')\n"
              " WHERE conrelid = relid AND contype = 'f' AND conparentid = 0\n"
              'ORDER BY sametable DESC, conname;'
        : 'SELECT true as sametable, conname,\n'
              '  pg_catalog.pg_get_constraintdef(r.oid, true) as condef,\n'
              '  conrelid::pg_catalog.regclass AS ontable\n'
              'FROM pg_catalog.pg_constraint r\n'
              "WHERE r.conrelid = '$oid' AND r.contype = 'f'\n"
              '     AND conparentid = 0\n'
              'ORDER BY conname',
  );
  if (fks.rows.isNotEmpty) footers.add('Foreign-key constraints:');
  for (var i = 0; i < fks.rows.length; i++) {
    footers.add(
      fks.value(i, 0) == 'f'
          ? '    TABLE "${fks.value(i, 3)}" CONSTRAINT "${fks.value(i, 1)}" '
                '${fks.value(i, 2)}'
          : '    "${fks.value(i, 1)}" ${fks.value(i, 2)}',
    );
  }

  final refs = await q(
    'SELECT conname, conrelid::pg_catalog.regclass AS ontable,\n'
    '       pg_catalog.pg_get_constraintdef(oid, true) AS condef\n'
    '  FROM pg_catalog.pg_constraint c\n'
    " WHERE confrelid IN (SELECT pg_catalog.pg_partition_ancestors('$oid')\n"
    "                     UNION ALL VALUES ('$oid'::pg_catalog.regclass))\n"
    "       AND contype = 'f' AND conparentid = 0\n"
    'ORDER BY conname;',
  );
  if (refs.rows.isNotEmpty) footers.add('Referenced by:');
  for (var i = 0; i < refs.rows.length; i++) {
    footers.add(
      '    TABLE "${refs.value(i, 1)}" CONSTRAINT "${refs.value(i, 0)}" '
      '${refs.value(i, 2)}',
    );
  }

  await _policyFooters(context, footers, info, oid);
  await _statisticsFooters(context, footers, oid);

  if (info.hasRules && info.relkind != 'm') {
    final r = await q(
      "SELECT r.rulename, trim(trailing ';' from "
      'pg_catalog.pg_get_ruledef(r.oid, true)), ev_enabled\n'
      'FROM pg_catalog.pg_rewrite r\n'
      "WHERE r.ev_class = '$oid' ORDER BY 1;",
    );
    const headings = {
      'O': 'Rules:',
      'D': 'Disabled rules:',
      'A': 'Rules firing always:',
      'R': 'Rules firing on replica only:',
    };
    for (final MapEntry(key: state, value: heading) in headings.entries) {
      var printed = false;
      for (var i = 0; i < r.rows.length; i++) {
        if (r.value(i, 2) != state) continue;
        if (!printed) footers.add(heading);
        printed = true;
        final def = r.value(i, 1);
        footers.add('    ${def.length > 12 ? def.substring(12) : def}');
      }
    }
  }

  await _publicationFooters(context, footers, oid);

  if (verbose) {
    final r = await q(
      'SELECT c.conname, a.attname, c.connoinherit,\n'
      '  c.conislocal, c.coninhcount <> 0,\n'
      '  c.convalidated\n'
      'FROM pg_catalog.pg_constraint c JOIN\n'
      '  pg_catalog.pg_attribute a ON\n'
      '    (a.attrelid = c.conrelid AND a.attnum = c.conkey[1])\n'
      "WHERE c.contype = 'n' AND\n"
      "  c.conrelid = '$oid'::pg_catalog.regclass\n"
      'ORDER BY a.attnum',
    );
    if (r.rows.isNotEmpty) footers.add('Not-null constraints:');
    for (var i = 0; i < r.rows.length; i++) {
      final local = r.value(i, 3) == 't';
      final inherited = r.value(i, 4) == 't';
      final suffix = r.value(i, 2) == 't'
          ? ' NO INHERIT'
          : local && inherited
          ? ' (local, inherited)'
          : inherited
          ? ' (inherited)'
          : '';
      final notValid = r.value(i, 5) == 't' ? '' : ' NOT VALID';
      footers.add(
        '    "${r.value(i, 0)}" NOT NULL "${r.value(i, 1)}"$suffix$notValid',
      );
    }
  }
}

Future<void> _policyFooters(
  DescribeContext context,
  List<String> footers,
  TableInfo info,
  String oid,
) async {
  final r = await context.query(
    'SELECT pol.polname, pol.polpermissive,\n'
    "  CASE WHEN pol.polroles = '{0}' THEN NULL ELSE "
    'pg_catalog.array_to_string(array(select rolname from '
    'pg_catalog.pg_roles where oid = any (pol.polroles) order by 1),'
    "',') END,\n"
    '  pg_catalog.pg_get_expr(pol.polqual, pol.polrelid),\n'
    '  pg_catalog.pg_get_expr(pol.polwithcheck, pol.polrelid),\n'
    '  CASE pol.polcmd\n'
    "    WHEN 'r' THEN 'SELECT'\n"
    "    WHEN 'a' THEN 'INSERT'\n"
    "    WHEN 'w' THEN 'UPDATE'\n"
    "    WHEN 'd' THEN 'DELETE'\n"
    '    END AS cmd\n'
    'FROM pg_catalog.pg_policy pol\n'
    "WHERE pol.polrelid = '$oid' ORDER BY 1;",
  );
  final count = r.rows.length;
  final rls = info.rowSecurity;
  final forced = info.forceRowSecurity;
  if (rls && !forced && count > 0) footers.add('Policies:');
  if (rls && forced && count > 0) {
    footers.add('Policies (forced row security enabled):');
  }
  if (rls && !forced && count == 0) {
    footers.add('Policies (row security enabled): (none)');
  }
  if (rls && forced && count == 0) {
    footers.add('Policies (forced row security enabled): (none)');
  }
  if (!rls && count > 0) footers.add('Policies (row security disabled):');
  for (var i = 0; i < count; i++) {
    final b = StringBuffer('    POLICY "${r.value(i, 0)}"');
    if (r.value(i, 1).startsWith('f')) b.write(' AS RESTRICTIVE');
    if (!r.isNull(i, 5)) b.write(' FOR ${r.value(i, 5)}');
    if (!r.isNull(i, 2)) b.write('\n      TO ${r.value(i, 2)}');
    if (!r.isNull(i, 3)) b.write('\n      USING (${r.value(i, 3)})');
    if (!r.isNull(i, 4)) b.write('\n      WITH CHECK (${r.value(i, 4)})');
    footers.add(b.toString());
  }
}

Future<void> _statisticsFooters(
  DescribeContext context,
  List<String> footers,
  String oid,
) async {
  final v = context.version;
  final r = await context.query(
    v >= 140000
        ? 'SELECT oid, '
              'stxrelid::pg_catalog.regclass, '
              'stxnamespace::pg_catalog.regnamespace::pg_catalog.text AS nsp, '
              'stxname,\n'
              'pg_catalog.pg_get_statisticsobjdef_columns(oid) AS columns,\n'
              "  'd' = any(stxkind) AS ndist_enabled,\n"
              "  'f' = any(stxkind) AS deps_enabled,\n"
              "  'm' = any(stxkind) AS mcv_enabled,\n"
              'stxstattarget\n'
              'FROM pg_catalog.pg_statistic_ext\n'
              "WHERE stxrelid = '$oid'\n"
              'ORDER BY nsp, stxname;'
        : 'SELECT oid, '
              'stxrelid::pg_catalog.regclass, '
              'stxnamespace::pg_catalog.regnamespace AS nsp, '
              'stxname,\n'
              '  (SELECT pg_catalog.string_agg(pg_catalog.quote_ident(attname)'
              ",', ')\n"
              '   FROM pg_catalog.unnest(stxkeys) s(attnum)\n'
              '   JOIN pg_catalog.pg_attribute a '
              'ON (stxrelid = a.attrelid AND\n'
              '        a.attnum = s.attnum AND NOT attisdropped)) AS columns,\n'
              "  'd' = any(stxkind) AS ndist_enabled,\n"
              "  'f' = any(stxkind) AS deps_enabled,\n"
              "  'm' = any(stxkind) AS mcv_enabled,\n"
              '  stxstattarget\n'
              'FROM pg_catalog.pg_statistic_ext\n'
              "WHERE stxrelid = '$oid'\n"
              'ORDER BY 1;',
  );
  if (r.rows.isNotEmpty) footers.add('Statistics objects:');
  for (var i = 0; i < r.rows.length; i++) {
    final kinds = [
      if (r.value(i, 5) == 't') 'ndistinct',
      if (r.value(i, 6) == 't') 'dependencies',
      if (r.value(i, 7) == 't') 'mcv',
    ];
    final b = StringBuffer('    "${r.value(i, 2)}.${r.value(i, 3)}"');
    if (v >= 140000) {
      // Kinds are shown unless none (an expression) or all were set.
      if (kinds.isNotEmpty && kinds.length < 3) {
        b.write(' (${kinds.join(', ')})');
      }
      b.write(' ON ${r.value(i, 4)} FROM ${r.value(i, 1)}');
      if (!r.isNull(i, 8) && r.value(i, 8) != '-1') {
        b.write('; STATISTICS ${r.value(i, 8)}');
      }
    } else {
      b.write(
        ' (${kinds.join(', ')}) ON ${r.value(i, 4)} FROM ${r.value(i, 1)}',
      );
      if (r.value(i, 8) != '-1') b.write('; STATISTICS ${r.value(i, 8)}');
    }
    footers.add(b.toString());
  }
}

Future<void> _publicationFooters(
  DescribeContext context,
  List<String> footers,
  String oid,
) async {
  final r = await context.query(
    context.version >= 150000
        ? 'SELECT pubname\n'
              '     , NULL\n'
              '     , NULL\n'
              'FROM pg_catalog.pg_publication p\n'
              '     JOIN pg_catalog.pg_publication_namespace pn '
              'ON p.oid = pn.pnpubid\n'
              '     JOIN pg_catalog.pg_class pc '
              'ON pc.relnamespace = pn.pnnspid\n'
              "WHERE pc.oid ='$oid' and "
              "pg_catalog.pg_relation_is_publishable('$oid')\n"
              'UNION\n'
              'SELECT pubname\n'
              '     , pg_get_expr(pr.prqual, c.oid)\n'
              '     , (CASE WHEN pr.prattrs IS NOT NULL THEN\n'
              "         (SELECT string_agg(attname, ', ')\n"
              '           FROM pg_catalog.generate_series(0, '
              'pg_catalog.array_upper(pr.prattrs::pg_catalog.int2[], 1)) s,\n'
              '                pg_catalog.pg_attribute\n'
              '          WHERE attrelid = pr.prrelid AND attnum = prattrs[s])\n'
              '        ELSE NULL END) '
              'FROM pg_catalog.pg_publication p\n'
              '     JOIN pg_catalog.pg_publication_rel pr '
              'ON p.oid = pr.prpubid\n'
              '     JOIN pg_catalog.pg_class c ON c.oid = pr.prrelid\n'
              "WHERE pr.prrelid = '$oid'\n"
              'UNION\n'
              'SELECT pubname\n'
              '     , NULL\n'
              '     , NULL\n'
              'FROM pg_catalog.pg_publication p\n'
              'WHERE p.puballtables AND '
              "pg_catalog.pg_relation_is_publishable('$oid')\n"
              'ORDER BY 1;'
        : 'SELECT pubname\n'
              '     , NULL\n'
              '     , NULL\n'
              'FROM pg_catalog.pg_publication p\n'
              'JOIN pg_catalog.pg_publication_rel pr ON p.oid = pr.prpubid\n'
              "WHERE pr.prrelid = '$oid'\n"
              'UNION ALL\n'
              'SELECT pubname\n'
              '     , NULL\n'
              '     , NULL\n'
              'FROM pg_catalog.pg_publication p\n'
              'WHERE p.puballtables AND '
              "pg_catalog.pg_relation_is_publishable('$oid')\n"
              'ORDER BY 1;',
  );
  if (r.rows.isNotEmpty) footers.add('Publications:');
  for (var i = 0; i < r.rows.length; i++) {
    final b = StringBuffer('    "${r.value(i, 0)}"');
    if (!r.isNull(i, 2)) b.write(' (${r.value(i, 2)})');
    if (!r.isNull(i, 1)) b.write(' WHERE ${r.value(i, 1)}');
    footers.add(b.toString());
  }
}

/// The trigger lists, by category (enabled, disabled user, disabled
/// internal, always, replica only).
Future<void> addTriggerFooters(
  DescribeContext context,
  List<String> footers,
  String oid,
) async {
  final v = context.version;
  final visible = v < 150000
      ? "(NOT t.tgisinternal OR (t.tgisinternal AND t.tgenabled = 'D') \n"
            '    OR EXISTS (SELECT 1 FROM pg_catalog.pg_depend WHERE '
            'objid = t.oid \n'
            "        AND refclassid = 'pg_catalog.pg_trigger'::"
            'pg_catalog.regclass))'
      : "(NOT t.tgisinternal OR (t.tgisinternal AND t.tgenabled = 'D'))";
  final r = await context.query(
    'SELECT t.tgname, pg_catalog.pg_get_triggerdef(t.oid, true), '
    't.tgenabled, t.tgisinternal,\n'
    '  CASE WHEN t.tgparentid != 0 THEN\n'
    '    (SELECT u.tgrelid::pg_catalog.regclass\n'
    '     FROM pg_catalog.pg_trigger AS u,\n'
    '          pg_catalog.pg_partition_ancestors(t.tgrelid) WITH ORDINALITY '
    'AS a(relid, depth)\n'
    '     WHERE u.tgname = t.tgname AND u.tgrelid = a.relid\n'
    '           AND u.tgparentid = 0\n'
    '     ORDER BY a.depth LIMIT 1)\n'
    '  END AS parent\n'
    'FROM pg_catalog.pg_trigger t\n'
    "WHERE t.tgrelid = '$oid' AND $visible"
    '\nORDER BY 1;',
  );
  bool inCategory(int category, int i) {
    final enabled = r.value(i, 2);
    final internal = r.value(i, 3) == 't';
    final disabled = enabled == 'D' || enabled == 'f';
    return switch (category) {
      0 => enabled == 'O' || enabled == 't',
      1 => disabled && !internal,
      2 => disabled && internal,
      3 => enabled == 'A',
      _ => enabled == 'R',
    };
  }

  const headings = [
    'Triggers:',
    'Disabled user triggers:',
    'Disabled internal triggers:',
    'Triggers firing always:',
    'Triggers firing on replica only:',
  ];
  for (var category = 0; category < headings.length; category++) {
    var printed = false;
    for (var i = 0; i < r.rows.length; i++) {
      if (!inCategory(category, i)) continue;
      if (!printed) footers.add(headings[category]);
      printed = true;
      var def = r.value(i, 1);
      final at = def.indexOf(' TRIGGER ');
      if (at >= 0) def = def.substring(at + 9);
      final b = StringBuffer('    $def');
      if (!r.isNull(i, 4)) b.write(', ON TABLE ${r.value(i, 4)}');
      footers.add(b.toString());
    }
  }
}
