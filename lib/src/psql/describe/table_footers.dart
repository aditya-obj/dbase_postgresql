// File: table_footers.dart
// Purpose: The footer lines of psql's `\d name`: partition info, index
// details, then for tables the indexes, check and foreign-key
// constraints, incoming references, policies, statistics objects, rules,
// publications, not-null constraints (+), view definition (+), triggers,
// inheritance and partitions, and the trailing table properties.
//
// Ported from src/bin/psql/describe.c (describeOneTableDetails,
// add_tablespace_footer) - PostgreSQL License, (c) 1996-2026 PostgreSQL
// Global Development Group. See THIRD_PARTY_NOTICES.

import 'package:dbase_postgresql/src/psql/describe/describe_context.dart';
import 'package:dbase_postgresql/src/psql/describe/relation_footers.dart';
import 'package:dbase_postgresql/src/psql/describe/table_info.dart';
import 'package:dbase_postgresql/src/psql/print/display_width.dart';

/// Every footer of `\d` for relation [oid], in psql's order.
Future<List<String>> tableFooters(
  DescribeContext context,
  TableInfo info, {
  required String schema,
  required String oid,
  required bool verbose,
}) async {
  final q = context.query;
  final v = context.version;
  final footers = <String>[];
  final k = info.relkind;

  if (info.isPartition) {
    final r = await q(
      'SELECT inhparent::pg_catalog.regclass,\n'
      '  pg_catalog.pg_get_expr(c.relpartbound, c.oid),\n  '
      '${v >= 140000 ? 'inhdetachpending' : 'false as inhdetachpending'}'
      '${verbose //
          ? ',\n  pg_catalog.pg_get_partition_constraintdef(c.oid)' : ''}'
      '\nFROM pg_catalog.pg_class c JOIN pg_catalog.pg_inherits i'
      ' ON c.oid = inhrelid'
      "\nWHERE c.oid = '$oid';",
    );
    if (r.rows.isNotEmpty) {
      final detached = r.value(0, 2) == 't' ? ' DETACH PENDING' : '';
      footers.add('Partition of: ${r.value(0, 0)} ${r.value(0, 1)}$detached');
      if (verbose) {
        final constraint = r.isNull(0, 3) ? '' : r.value(0, 3);
        footers.add(
          constraint.isEmpty
              ? 'No partition constraint'
              : 'Partition constraint: $constraint',
        );
      }
    }
  }

  if (k == 'p') {
    final r = await q(
      "SELECT pg_catalog.pg_get_partkeydef('$oid'::pg_catalog.oid);",
    );
    if (r.rows.length == 1) footers.add('Partition key: ${r.value(0, 0)}');
  }

  if (k == 't') {
    final r = await q(
      'SELECT n.nspname, c.relname\n'
      'FROM pg_catalog.pg_class c JOIN pg_catalog.pg_namespace n'
      ' ON n.oid = c.relnamespace\n'
      "WHERE reltoastrelid = '$oid';",
    );
    if (r.rows.length == 1) {
      footers.add('Owning table: "${r.value(0, 0)}.${r.value(0, 1)}"');
    }
  }

  if (k == 'i' || k == 'I') {
    final line = await indexFooter(context, schema, oid);
    if (line == null) return footers;
    footers.add(line);
    if (k == 'i') {
      await addTablespaceFooter(context, footers, k, info.tablespace);
    }
  } else if (info.isTableLike) {
    await addConstraintFooters(context, footers, info, oid, verbose: verbose);
  }

  if ((k == 'v' || k == 'm') && verbose) {
    final r = await q(
      "SELECT pg_catalog.pg_get_viewdef('$oid'::pg_catalog.oid, true);",
    );
    if (r.rows.isNotEmpty) {
      footers
        ..add('View definition:')
        ..add(r.value(0, 0));
      if (info.hasRules) {
        final rules = await q(
          "SELECT r.rulename, trim(trailing ';' from "
          'pg_catalog.pg_get_ruledef(r.oid, true))\n'
          'FROM pg_catalog.pg_rewrite r\n'
          "WHERE r.ev_class = '$oid' AND r.rulename != '_RETURN' "
          'ORDER BY 1;',
        );
        if (rules.rows.isNotEmpty) {
          footers.add('Rules:');
          for (var i = 0; i < rules.rows.length; i++) {
            footers.add(' ${_afterCreateRule(rules.value(i, 1))}');
          }
        }
      }
    }
  }

  if (info.hasTriggers) await addTriggerFooters(context, footers, oid);

  if (info.isTableLike) {
    await _finishTableFooters(context, footers, info, schema, oid, verbose);
  }

  if (verbose && info.reloptions.isNotEmpty) {
    footers.add('Options: ${info.reloptions}');
  }
  return footers;
}

/// "Everything after CREATE RULE is echoed verbatim" (12 characters).
String _afterCreateRule(String ruledef) =>
    ruledef.length > 12 ? ruledef.substring(12) : ruledef;

Future<void> _finishTableFooters(
  DescribeContext context,
  List<String> footers,
  TableInfo info,
  String schema,
  String oid,
  bool verbose,
) async {
  final q = context.query;
  final k = info.relkind;
  final partitioned = k == 'p' || k == 'I';

  if (k == 'f') {
    final r = await q(
      'SELECT s.srvname,\n'
      '  pg_catalog.array_to_string(ARRAY(\n'
      '    SELECT pg_catalog.quote_ident(option_name)'
      " || ' ' || pg_catalog.quote_literal(option_value)\n"
      "    FROM pg_catalog.pg_options_to_table(ftoptions)),  ', ')\n"
      'FROM pg_catalog.pg_foreign_table f,\n'
      '     pg_catalog.pg_foreign_server s\n'
      "WHERE f.ftrelid = '$oid' AND s.oid = f.ftserver;",
    );
    if (r.rows.length != 1) return;
    footers.add('Server: ${r.value(0, 0)}');
    final options = r.value(0, 1);
    if (options.isNotEmpty) footers.add('FDW options: ($options)');
  }

  final parents = await q(
    'SELECT c.oid::pg_catalog.regclass\n'
    'FROM pg_catalog.pg_class c, pg_catalog.pg_inherits i\n'
    "WHERE c.oid = i.inhparent AND i.inhrelid = '$oid'\n"
    "  AND c.relkind != 'p' AND c.relkind != 'I'\n"
    'ORDER BY inhseqno;',
  );
  const inherits = 'Inherits';
  for (var i = 0; i < parents.rows.length; i++) {
    final lead = i == 0 ? '$inherits:' : ' ' * (displayWidth(inherits) + 1);
    final comma = i < parents.rows.length - 1 ? ',' : '';
    footers.add('$lead ${parents.value(i, 0)}$comma');
  }

  final children = await q(
    context.version >= 140000
        ? 'SELECT c.oid::pg_catalog.regclass, c.relkind,'
              ' inhdetachpending,'
              ' pg_catalog.pg_get_expr(c.relpartbound, c.oid)\n'
              'FROM pg_catalog.pg_class c, pg_catalog.pg_inherits i\n'
              "WHERE c.oid = i.inhrelid AND i.inhparent = '$oid'\n"
              'ORDER BY pg_catalog.pg_get_expr(c.relpartbound, c.oid) = '
              "'DEFAULT', c.oid::pg_catalog.regclass::pg_catalog.text;"
        : 'SELECT c.oid::pg_catalog.regclass, c.relkind,'
              ' false AS inhdetachpending,'
              ' pg_catalog.pg_get_expr(c.relpartbound, c.oid)\n'
              'FROM pg_catalog.pg_class c, pg_catalog.pg_inherits i\n'
              "WHERE c.oid = i.inhrelid AND i.inhparent = '$oid'\n"
              'ORDER BY pg_catalog.pg_get_expr(c.relpartbound, c.oid) = '
              "'DEFAULT', c.oid::pg_catalog.regclass::pg_catalog.text;",
  );
  final count = children.rows.length;
  if (partitioned && count == 0) {
    footers.add('Number of partitions: 0');
  } else if (!verbose) {
    if (count > 0) {
      footers.add(
        partitioned
            ? 'Number of partitions: $count (Use ${r'\d+'} to list them.)'
            : 'Number of child tables: $count (Use ${r'\d+'} to list them.)',
      );
    }
  } else {
    final label = partitioned ? 'Partitions' : 'Child tables';
    for (var i = 0; i < count; i++) {
      final b = StringBuffer(
        i == 0 ? '$label: ' : '${' ' * displayWidth(label)}  ',
      )..write(children.value(i, 0));
      if (!children.isNull(i, 3)) b.write(' ${children.value(i, 3)}');
      final childKind = children.value(i, 1);
      if (childKind == 'p' || childKind == 'I') {
        b.write(', PARTITIONED');
      } else if (childKind == 'f') {
        b.write(', FOREIGN');
      }
      if (children.value(i, 2) == 't') b.write(' (DETACH PENDING)');
      if (i < count - 1) b.write(',');
      footers.add(b.toString());
    }
  }

  if (info.ofType case final type?) footers.add('Typed table of type: $type');

  final replident = info.replident;
  final isCatalog = schema == 'pg_catalog';
  if (verbose &&
      (k == 'r' || k == 'm') &&
      replident != 'i' &&
      ((!isCatalog && replident != 'd') || (isCatalog && replident != 'n'))) {
    final value = switch (replident) {
      'f' => 'FULL',
      'n' => 'NOTHING',
      _ => '???',
    };
    footers.add('Replica Identity: $value');
  }

  if (verbose && k != 'm' && info.hasOids) footers.add('Has OIDs: yes');

  await addTablespaceFooter(context, footers, k, info.tablespace);

  if (verbose && info.accessMethod != null) {
    footers.add('Access method: ${info.accessMethod}');
  }
}

/// add_tablespace_footer: a non-default tablespace as a new footer, or
/// appended to the last one (index lines) when [newLine] is false.
Future<void> addTablespaceFooter(
  DescribeContext context,
  List<String> footers,
  String relkind,
  int tablespace, {
  bool newLine = true,
}) async {
  const kinds = {'r', 'm', 'i', 'p', 'I', 't'};
  if (!kinds.contains(relkind) || tablespace == 0) return;
  final r = await context.query(
    'SELECT spcname FROM pg_catalog.pg_tablespace\n'
    "WHERE oid = '$tablespace';",
  );
  if (r.rows.isEmpty) return;
  final name = r.value(0, 0);
  if (newLine) {
    footers.add('Tablespace: "$name"');
  } else if (footers.isNotEmpty) {
    footers.last = '${footers.last}, tablespace "$name"';
  }
}
