// File: describer.dart
// Purpose: Runs psql's informational commands: \d[S+] [pattern], \dt \di
// \dv \dm \ds \dE, \df, \dn, \du / \dg, \dx, \dT, \dD, \dp / \z and \l,
// with the `S`, `+` and `x` modifiers.
//
// Ported from src/bin/psql/command.c (exec_command_d, exec_command_list,
// exec_command_z) - PostgreSQL License, (c) 1996-2026 PostgreSQL Global
// Development Group. See THIRD_PARTY_NOTICES.

import 'package:dabase_postgresql/src/psql/describe/describe_context.dart';
import 'package:dabase_postgresql/src/psql/describe/function_role_sql.dart';
import 'package:dabase_postgresql/src/psql/describe/list_sql.dart';
import 'package:dabase_postgresql/src/psql/describe/psql_query.dart';
import 'package:dabase_postgresql/src/psql/describe/table_details.dart';
import 'package:dabase_postgresql/src/psql/describe/type_privilege_sql.dart';
import 'package:dabase_postgresql/src/psql/meta_command.dart';
import 'package:dabase_postgresql/src/psql/name_pattern.dart';
import 'package:dabase_postgresql/src/psql/print/print_table.dart';
import 'package:dabase_postgresql/src/psql/sql_literal.dart';

/// Whether [name] (without the backslash) is a describe command this
/// library runs.
bool isDescribeCommand(String name) => _parse(name) != null;

/// Whether `\name` prints expanded once (the `x` modifier, as in `\dtx`).
bool describeForcesExpanded(String name) {
  final parsed = _parse(name);
  return parsed != null && parsed.expanded;
}

/// How many arguments the command reads (the rest are ignored with a
/// warning); `null` means all of them (`\df` argument types).
int? describeArgumentCount(String name) =>
    _parse(name)?.kind == _Kind.functions ? null : 1;

enum _Kind {
  relationOrList,
  relations,
  functions,
  schemas,
  roles,
  extensions,
  types,
  domains,
  privileges,
  databases,
}

final class _Parsed {
  const _Parsed(
    this.kind, {
    this.letters = '',
    this.verbose = false,
    this.system = false,
    this.expanded = false,
  });
  final _Kind kind;
  final String letters;
  final bool verbose;
  final bool system;
  final bool expanded;
}

_Parsed? _parse(String name) {
  if (name == 'list' || RegExp(r'^l[+x]*$').hasMatch(name)) {
    return _Parsed(
      _Kind.databases,
      verbose: name.contains('+'),
      expanded: name.startsWith('l') && name.substring(1).contains('x'),
    );
  }
  if (RegExp(r'^z[Sx]*$').hasMatch(name)) {
    return _Parsed(
      _Kind.privileges,
      system: name.contains('S'),
      expanded: name.substring(1).contains('x'),
    );
  }
  if (!name.startsWith('d')) return null;
  if (name.length == 1) return const _Parsed(_Kind.relationOrList);
  final rest = name.substring(1);
  final kind = switch (rest[0]) {
    '+' ||
    'S' when RegExp(r'^[+S][+Sx]*$').hasMatch(rest) => _Kind.relationOrList,
    't' ||
    'v' ||
    'm' ||
    'i' ||
    's' ||
    'E' when RegExp(r'^[tvmisE+Sx]+$').hasMatch(rest) => _Kind.relations,
    'f' when RegExp(r'^f[anptwSx+]*$').hasMatch(rest) => _Kind.functions,
    'n' => _Kind.schemas,
    'u' || 'g' => _Kind.roles,
    'x' => _Kind.extensions,
    'T' => _Kind.types,
    'D' => _Kind.domains,
    'p' => _Kind.privileges,
    _ => null,
  };
  if (kind == null) return null;
  return _Parsed(
    kind,
    letters: rest,
    verbose: name.contains('+'),
    system: name.contains('S'),
    // `x` after the first letter means expanded (`\dx` is extensions).
    expanded: name.length > 2 && name.substring(2).contains('x'),
  );
}

/// Runs the describe command [command] and returns what psql would print.
/// Throws [ArgumentError] when it isn't one ([isDescribeCommand]).
/// Server errors from the catalog queries are thrown as they come.
Future<List<PsqlOutput>> runDescribe(
  DescribeContext context,
  MetaCommand command,
) async {
  final parsed = _parse(command.name);
  if (parsed == null) {
    throw ArgumentError.value(
      command.name,
      'command',
      'not a describe command',
    );
  }
  final pattern = command.arg(0, semicolon: true);
  final verbose = parsed.verbose;
  final system = parsed.system;
  final list = context.list;
  PsqlOutput table(String title, PsqlResult r) => PsqlTableOutput(
    queryTable(r, title: title, nullDisplay: context.nullDisplay),
  );

  try {
    switch (parsed.kind) {
      case _Kind.relationOrList:
        if (pattern != null) {
          return await describeTableDetails(
            context,
            pattern,
            verbose: verbose,
            showSystem: system,
          );
        }
        return await _relations(context, 'tvmsE', null, verbose, system);
      case _Kind.relations:
        return await _relations(
          context,
          parsed.letters,
          pattern,
          verbose,
          system,
        );
      case _Kind.functions:
        final kinds = parsed.letters.substring(1);
        final argPatterns = pattern == null
            ? const <String>[]
            : [
                for (final arg in command.args.skip(1))
                  arg.value(semicolon: true),
              ];
        final sql = listFunctionsSql(
          list,
          kinds,
          pattern,
          argPatterns,
          verbose: verbose,
          showSystem: system,
        );
        return [table('List of functions', await context.query(sql))];
      case _Kind.schemas:
        final sql = listSchemasSql(
          list,
          pattern,
          verbose: verbose,
          showSystem: system,
        );
        final r = await context.query(sql);
        List<String>? footers;
        if (pattern != null && context.version >= 150000) {
          final pubs = await context.query(
            'SELECT pubname \n'
            'FROM pg_catalog.pg_publication p\n'
            '     JOIN pg_catalog.pg_publication_namespace pn '
            'ON p.oid = pn.pnpubid\n'
            '     JOIN pg_catalog.pg_namespace n ON n.oid = pn.pnnspid \n'
            'WHERE n.nspname = ${sqlStringLiteral(pattern)}\n'
            'ORDER BY 1',
          );
          if (pubs.rows.isNotEmpty) {
            footers = [
              'Publications:',
              for (var i = 0; i < pubs.rows.length; i++)
                '    "${pubs.value(i, 0)}"',
            ];
          }
        }
        return [
          PsqlTableOutput(
            queryTable(
              r,
              title: 'List of schemas',
              nullDisplay: context.nullDisplay,
              footers: footers,
            ),
          ),
        ];
      case _Kind.roles:
        final sql = listRolesSql(
          list,
          pattern,
          verbose: verbose,
          showSystem: system,
        );
        return [
          PsqlTableOutput(
            rolesTable(await context.query(sql), verbose: verbose),
          ),
        ];
      case _Kind.extensions:
        if (verbose) {
          return const [
            PsqlMessageOutput(
              r'\dx+ (extension contents) is not supported in this console',
              isError: true,
            ),
          ];
        }
        final sql = listExtensionsSql(list, pattern);
        return [
          table('List of installed extensions', await context.query(sql)),
        ];
      case _Kind.types:
        final sql = listTypesSql(
          list,
          pattern,
          verbose: verbose,
          showSystem: system,
        );
        return [table('List of data types', await context.query(sql))];
      case _Kind.domains:
        final sql = listDomainsSql(
          list,
          pattern,
          verbose: verbose,
          showSystem: system,
        );
        return [table('List of domains', await context.query(sql))];
      case _Kind.privileges:
        final sql = permissionsSql(list, pattern, showSystem: system);
        return [table('Access privileges', await context.query(sql))];
      case _Kind.databases:
        final sql = listDatabasesSql(list, pattern, verbose: verbose);
        return [table('List of databases', await context.query(sql))];
    }
  } on NamePatternException catch (e) {
    return [PsqlMessageOutput(e.message, isError: true)];
  }
}

Future<List<PsqlOutput>> _relations(
  DescribeContext context,
  String letters,
  String? pattern,
  bool verbose,
  bool system,
) async {
  final kinds = RelationKinds.parse(letters);
  final sql = listTablesSql(
    context.list,
    kinds,
    pattern,
    verbose: verbose,
    showSystem: system,
  );
  final r = await context.query(sql);
  if (r.rows.isEmpty) {
    // An error message, but the command itself succeeded.
    return [
      PsqlMessageOutput(kinds.notFound(pattern), isError: true, fails: false),
    ];
  }
  return [
    PsqlTableOutput(
      queryTable(r, title: kinds.title, nullDisplay: context.nullDisplay),
    ),
  ];
}

/// The table [output] holds, or `null` (for callers that print).
PrintTable? tableOf(PsqlOutput output) =>
    output is PsqlTableOutput ? output.table : null;
