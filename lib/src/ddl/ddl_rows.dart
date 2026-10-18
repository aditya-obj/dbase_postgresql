// File: ddl_rows.dart
// Purpose: Parsed rows shared by several object kinds: grants, indexes,
// triggers, rules and column comments. Each `fromRow` reads the server
// text of one CatalogQuery row (see the *_queries.dart files for the
// column names). Moved from the dbase app in 0.6.0.

import 'package:dbase_postgresql/src/catalog/catalog_query.dart';

/// The `relid` column bulk queries add: the OID of the object a row
/// belongs to.
int rowRelid(CatalogRow row) =>
    pgInt(row['relid']) ??
    (throw const FormatException('Catalog column "relid" is missing.'));

/// One `aclexplode` row (Q-T8 shape).
final class GrantRow {
  /// Creates a grant row.
  const GrantRow({
    required this.grantee,
    required this.privilege,
    required this.isGrantable,
    required this.isOwner,
  });

  /// Reads `grantee`, `privilege_type`, `is_grantable` and `is_owner`.
  factory GrantRow.fromRow(CatalogRow row) => GrantRow(
    grantee: requireText(row, 'grantee'),
    privilege: requireText(row, 'privilege_type'),
    isGrantable: pgBool(row['is_grantable']) ?? false,
    isOwner: pgBool(row['is_owner']) ?? false,
  );

  /// Already quoted by the server (`quote_ident`), or `PUBLIC`.
  final String grantee;

  /// The privilege keyword, e.g. `SELECT`.
  final String privilege;

  /// Held WITH GRANT OPTION.
  final bool isGrantable;

  /// The owner's own privileges; never emitted (they are implicit).
  final bool isOwner;
}

/// One index of a table or materialized view (Q-T6 shape, plus whether a
/// PK/UNIQUE/EXCLUDE constraint owns it).
final class IndexRow {
  /// Creates an index row.
  const IndexRow({
    required this.name,
    required this.def,
    this.isClustered = false,
    this.isValid = true,
    this.isReplicaIdentity = false,
    this.isConstraintIndex = false,
    this.comment,
  });

  /// Reads `name`, `def`, `indisclustered`, `indisvalid`,
  /// `indisreplident`, `is_constraint` and `comment`.
  factory IndexRow.fromRow(CatalogRow row) => IndexRow(
    name: requireText(row, 'name'),
    def: requireText(row, 'def'),
    isClustered: pgBool(row['indisclustered']) ?? false,
    isValid: pgBool(row['indisvalid']) ?? true,
    isReplicaIdentity: pgBool(row['indisreplident']) ?? false,
    isConstraintIndex: pgBool(row['is_constraint']) ?? false,
    comment: row['comment'],
  );

  /// The index name (unqualified; indexes live in their table's schema).
  final String name;

  /// `pg_get_indexdef` text, no trailing `;`.
  final String def;

  /// The table is clustered on this index.
  final bool isClustered;

  /// `false` after a failed `CREATE INDEX CONCURRENTLY`.
  final bool isValid;

  /// The table's REPLICA IDENTITY uses this index.
  final bool isReplicaIdentity;

  /// Created by a constraint; its DDL is the constraint itself.
  final bool isConstraintIndex;

  /// `COMMENT ON INDEX` text, if any.
  final String? comment;
}

/// One user trigger (Q-T7).
final class TriggerRow {
  /// Creates a trigger row.
  const TriggerRow({required this.name, required this.def, this.enabled = 'O'});

  /// Reads `tgname`, `def` and `tgenabled`.
  factory TriggerRow.fromRow(CatalogRow row) => TriggerRow(
    name: requireText(row, 'tgname'),
    def: requireText(row, 'def'),
    enabled: row['tgenabled'] ?? 'O',
  );

  /// The trigger name.
  final String name;

  /// `pg_get_triggerdef(oid, true)` text.
  final String def;

  /// `O` on, `D` disabled, `R` replica only, `A` always.
  final String enabled;
}

/// One rewrite rule other than a view's `_RETURN` (Q-T7).
final class RuleRow {
  /// Creates a rule row.
  const RuleRow({required this.name, required this.def});

  /// Reads `rulename` and `def`.
  factory RuleRow.fromRow(CatalogRow row) =>
      RuleRow(name: requireText(row, 'rulename'), def: requireText(row, 'def'));

  /// The rule name.
  final String name;

  /// `pg_get_ruledef` text; usually already ends with `;`.
  final String def;
}

/// A column name with its comment (views and materialized views).
final class ColumnCommentRow {
  /// Creates a column comment row.
  const ColumnCommentRow({required this.name, required this.comment});

  /// Reads `attname` and `comment`.
  factory ColumnCommentRow.fromRow(CatalogRow row) => ColumnCommentRow(
    name: requireText(row, 'attname'),
    comment: requireText(row, 'comment'),
  );

  /// The column name.
  final String name;

  /// The comment text.
  final String comment;
}
