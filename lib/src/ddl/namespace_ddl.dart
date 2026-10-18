// File: namespace_ddl.dart
// Purpose: Rows and DDL for schemas, extensions and default privileges in
// a dump.

import 'package:dbase_postgresql/src/catalog/catalog_query.dart';
import 'package:dbase_postgresql/src/ddl/ddl_rows.dart';
import 'package:dbase_postgresql/src/ddl/ddl_statements.dart';
import 'package:dbase_postgresql/src/sql/sql_quoting.dart';

/// `CREATE SCHEMA IF NOT EXISTS name;` (`public` already exists in a new
/// database, and IF NOT EXISTS keeps a restore into it working).
String createSchemaStatement(String name) =>
    'CREATE SCHEMA IF NOT EXISTS ${quoteIdent(name)};';

/// `CREATE EXTENSION IF NOT EXISTS name WITH SCHEMA schema;` (no VERSION:
/// the target installs its default version, as pg_dump does).
String createExtensionStatement(String name, String schema) =>
    'CREATE EXTENSION IF NOT EXISTS ${quoteIdent(name)} '
    'WITH SCHEMA ${quoteIdent(schema)};';

/// One `pg_default_acl` privilege, already expanded by `aclexplode`.
final class DefaultPrivilegeRow {
  /// Creates a default privilege row.
  const DefaultPrivilegeRow({
    required this.role,
    required this.objectType,
    required this.grantee,
    required this.privilege,
    this.schema,
    this.isGrantable = false,
  });

  /// Reads `role`, `schema`, `objtype`, `grantee`, `privilege_type` and
  /// `is_grantable`.
  factory DefaultPrivilegeRow.fromRow(CatalogRow row) => DefaultPrivilegeRow(
    role: requireText(row, 'role'),
    schema: row['schema'],
    objectType: requireText(row, 'objtype'),
    grantee: requireText(row, 'grantee'),
    privilege: requireText(row, 'privilege_type'),
    isGrantable: pgBool(row['is_grantable']) ?? false,
  );

  /// The role whose new objects get these privileges (unquoted).
  final String role;

  /// The schema it is limited to, or `null` for every schema.
  final String? schema;

  /// `defaclobjtype`: `r` tables, `S` sequences, `f` functions, `T`
  /// types, `n` schemas.
  final String objectType;

  /// Already quoted by the server, or `PUBLIC`.
  final String grantee;

  /// The privilege keyword.
  final String privilege;

  /// WITH GRANT OPTION.
  final bool isGrantable;
}

/// `ALTER DEFAULT PRIVILEGES ... GRANT ...;` per role, schema, object type
/// and grantee. Like the object grants, only GRANTs are rebuilt: revoked
/// built-in defaults are not (a v2 item).
List<String> defaultPrivilegeStatements(List<DefaultPrivilegeRow> rows) {
  final groups = <(String, String?, String, String, bool), List<String>>{};
  for (final r in rows) {
    // The role's own privileges are implicit.
    if (r.grantee == quoteIdent(r.role)) continue;
    final key = (r.role, r.schema, r.objectType, r.grantee, r.isGrantable);
    (groups[key] ??= []).add(r.privilege);
  }
  return [
    for (final MapEntry(
          key: (role, schema, type, grantee, grantable),
          value: privileges,
        )
        in groups.entries)
      if (_objectsKeyword(type) case final objects?)
        [
          'ALTER DEFAULT PRIVILEGES FOR ROLE ${quoteIdent(role)}',
          if (schema != null) ' IN SCHEMA ${quoteIdent(schema)}',
          ' GRANT ${privileges.join(', ')} ON $objects TO $grantee',
          if (grantable) ' WITH GRANT OPTION',
          ';',
        ].join(),
  ];
}

String? _objectsKeyword(String code) => switch (code) {
  'r' => 'TABLES',
  'S' => 'SEQUENCES',
  'f' => 'FUNCTIONS',
  'T' => 'TYPES',
  'n' => 'SCHEMAS',
  _ => null,
};

/// GRANT statements on a schema.
List<String> schemaGrantStatements(String schema, List<GrantRow> rows) =>
    grantStatements(rows, 'SCHEMA ${quoteIdent(schema)}');
