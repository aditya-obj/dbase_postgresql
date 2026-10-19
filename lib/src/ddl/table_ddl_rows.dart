// File: table_ddl_rows.dart
// Purpose: Parsed rows of the table recipe queries Q-T1..Q-T7, the input
// of TableDdlAssembler. Moved from the dabase app in 0.6.0.

import 'package:dabase_postgresql/src/catalog/catalog_query.dart';

/// Q-T1: the relation itself.
final class TableHeader {
  /// Creates a table header.
  const TableHeader({
    required this.schema,
    required this.name,
    this.relkind = 'r',
    this.persistence = 'p',
    this.isPartition = false,
    this.ofType,
    this.partitionKey,
    this.partitionBound,
    this.accessMethod,
    this.options = const [],
    this.toastOptions = const [],
    this.tablespace,
    this.rowSecurity = false,
    this.forceRowSecurity = false,
    this.replicaIdentity = 'd',
    this.owner,
    this.hasAcl = false,
    this.comment,
    this.foreignServer,
    this.foreignOptions = const [],
  });

  /// Reads the `tableHeaderSql` columns.
  factory TableHeader.fromRow(CatalogRow row) => TableHeader(
    schema: requireText(row, 'schema'),
    name: requireText(row, 'name'),
    relkind: row['relkind'] ?? 'r',
    persistence: row['relpersistence'] ?? 'p',
    isPartition: pgBool(row['relispartition']) ?? false,
    ofType: row['of_type'],
    partitionKey: row['partition_key'],
    partitionBound: row['partition_bound'],
    accessMethod: row['access_method'],
    options: pgTextArray(row['reloptions']).nonNulls.toList(),
    toastOptions: pgTextArray(row['toast_reloptions']).nonNulls.toList(),
    tablespace: row['tablespace'],
    rowSecurity: pgBool(row['relrowsecurity']) ?? false,
    forceRowSecurity: pgBool(row['relforcerowsecurity']) ?? false,
    replicaIdentity: row['relreplident'] ?? 'd',
    owner: row['owner'],
    hasAcl: row['relacl'] != null,
    comment: row['comment'],
    foreignServer: row['foreign_server'],
    foreignOptions: pgTextArray(row['foreign_options']).nonNulls.toList(),
  );

  /// Schema name.
  final String schema;

  /// Table name.
  final String name;

  /// `r` table, `p` partitioned, `f` foreign.
  final String relkind;

  /// `p` permanent, `u` unlogged, `t` temporary.
  final String persistence;

  /// A partition (`PARTITION OF` its parent).
  final bool isPartition;

  /// `format_type(reloftype)` for typed tables (`OF type`).
  final String? ofType;

  /// `pg_get_partkeydef`, e.g. `RANGE (created_at)`.
  final String? partitionKey;

  /// `FOR VALUES ...` or `DEFAULT`.
  final String? partitionBound;

  /// Table access method (`heap` is the default and not written).
  final String? accessMethod;

  /// `reloptions` entries (`name=value`).
  final List<String> options;

  /// The TOAST table's `reloptions`.
  final List<String> toastOptions;

  /// Tablespace, when not the default.
  final String? tablespace;

  /// ROW LEVEL SECURITY is enabled.
  final bool rowSecurity;

  /// ROW LEVEL SECURITY is forced (applies to the owner too).
  final bool forceRowSecurity;

  /// `d` default, `n` nothing, `f` full, `i` index.
  final String replicaIdentity;

  /// Owner role name.
  final String? owner;

  /// `relacl IS NOT NULL`: grants differ from the defaults (Q-T8 needed).
  final bool hasAcl;

  /// `COMMENT ON` text.
  final String? comment;

  /// Foreign server of a foreign table.
  final String? foreignServer;

  /// Foreign table options (`name=value`).
  final List<String> foreignOptions;
}

/// Q-T2: one parent (`INHERITS` entry or the `PARTITION OF` parent).
final class ParentRow {
  /// Creates a parent row.
  const ParentRow({required this.schema, required this.name});

  /// Reads `schema` and `name`.
  factory ParentRow.fromRow(CatalogRow row) => ParentRow(
    schema: requireText(row, 'schema'),
    name: requireText(row, 'name'),
  );

  /// The parent's schema.
  final String schema;

  /// The parent's name.
  final String name;
}

/// Q-T3: one live column.
final class ColumnRow {
  /// Creates a column row.
  const ColumnRow({
    required this.attnum,
    required this.name,
    required this.type,
    this.notNull = false,
    this.identity = '',
    this.generated = '',
    this.defaultExpr,
    this.collation,
    this.isLocal = true,
    this.compression = '',
    this.fdwOptions = const [],
    this.comment,
  });

  /// Reads the `tableColumnsSql` columns.
  factory ColumnRow.fromRow(CatalogRow row) => ColumnRow(
    attnum: pgInt(row['attnum']) ?? 0,
    name: requireText(row, 'attname'),
    type: requireText(row, 'type'),
    notNull: pgBool(row['attnotnull']) ?? false,
    identity: row['attidentity'] ?? '',
    generated: row['attgenerated'] ?? '',
    defaultExpr: row['default_or_generation_expr'],
    collation: row['collation'],
    isLocal: pgBool(row['attislocal']) ?? true,
    compression: row['attcompression'] ?? '',
    fdwOptions: pgTextArray(row['attfdwoptions']).nonNulls.toList(),
    comment: row['comment'],
  );

  /// `pg_attribute.attnum`.
  final int attnum;

  /// Column name.
  final String name;

  /// `format_type(atttypid, atttypmod)`.
  final String type;

  /// `attnotnull`.
  final bool notNull;

  /// `''`, `a` ALWAYS, `d` BY DEFAULT.
  final String identity;

  /// `''`, `s` STORED, `v` VIRTUAL [PG18+].
  final String generated;

  /// The DEFAULT or generation expression.
  final String? defaultExpr;

  /// Already quoted (`pg_catalog."C"`); only when not the type's default.
  final String? collation;

  /// Defined locally (not only inherited).
  final bool isLocal;

  /// `''`, `p` pglz, `l` lz4 [PG14+].
  final String compression;

  /// Foreign table column options (`name=value`).
  final List<String> fdwOptions;

  /// `COMMENT ON COLUMN` text.
  final String? comment;
}

/// Q-T4: identity sequence options of one column.
final class IdentityRow {
  /// Creates an identity row.
  const IdentityRow({
    required this.attnum,
    this.start = '1',
    this.increment = '1',
  });

  /// Reads `attnum`, `seqstart` and `seqincrement`.
  factory IdentityRow.fromRow(CatalogRow row) => IdentityRow(
    attnum: pgInt(row['attnum']) ?? 0,
    start: row['seqstart'] ?? '1',
    increment: row['seqincrement'] ?? '1',
  );

  /// The identity column.
  final int attnum;

  /// START WITH.
  final String start;

  /// INCREMENT BY.
  final String increment;
}

/// Q-T5: one constraint.
final class ConstraintRow {
  /// Creates a constraint row.
  const ConstraintRow({
    required this.name,
    required this.type,
    required this.def,
    this.isLocal = true,
    this.isValidated = true,
    this.noInherit = false,
    this.attnum,
    this.comment,
    this.referencedTable,
  });

  /// Reads the `tableConstraintsSql` columns.
  factory ConstraintRow.fromRow(CatalogRow row) => ConstraintRow(
    name: requireText(row, 'conname'),
    type: requireText(row, 'contype'),
    def: requireText(row, 'def'),
    isLocal: pgBool(row['conislocal']) ?? true,
    isValidated: pgBool(row['convalidated']) ?? true,
    noInherit: pgBool(row['connoinherit']) ?? false,
    attnum: pgInt(row['attnum']),
    comment: row['comment'],
    referencedTable: switch (pgInt(row['confrelid'])) {
      final oid? when oid != 0 => oid,
      _ => null,
    },
  );

  /// Constraint name.
  final String name;

  /// `p`, `u`, `x`, `c`, `f`, or `n` (NOT NULL, PG18+ only).
  final String type;

  /// `pg_get_constraintdef(oid, true)`, including `NOT VALID`.
  final String def;

  /// Defined locally (not only inherited).
  final bool isLocal;

  /// `false` for `NOT VALID` constraints.
  final bool isValidated;

  /// `NO INHERIT`.
  final bool noInherit;

  /// `conkey[1]`: the column of a NOT NULL constraint.
  final int? attnum;

  /// `COMMENT ON CONSTRAINT` text.
  final String? comment;

  /// The table a foreign key references (`confrelid`), when known.
  final int? referencedTable;
}

/// Q-T7: one row-level security policy.
final class PolicyRow {
  /// Creates a policy row.
  const PolicyRow({
    required this.name,
    this.isPermissive = true,
    this.command = '*',
    this.roles = const ['PUBLIC'],
    this.usingExpr,
    this.checkExpr,
  });

  /// Reads the `tablePoliciesSql` columns.
  factory PolicyRow.fromRow(CatalogRow row) => PolicyRow(
    name: requireText(row, 'polname'),
    isPermissive: pgBool(row['polpermissive']) ?? true,
    command: row['polcmd'] ?? '*',
    roles: pgTextArray(row['roles']).nonNulls.toList(),
    usingExpr: row['using_expr'],
    checkExpr: row['check_expr'],
  );

  /// Policy name.
  final String name;

  /// PERMISSIVE (`true`) or RESTRICTIVE.
  final bool isPermissive;

  /// `*` ALL, `r` SELECT, `a` INSERT, `w` UPDATE, `d` DELETE.
  final String command;

  /// Already quoted by the server, or `PUBLIC`.
  final List<String> roles;

  /// The USING expression.
  final String? usingExpr;

  /// The WITH CHECK expression.
  final String? checkExpr;
}
