// File: object_ddl_rows.dart
// Purpose: Parsed header rows for views, materialized views, routines,
// sequences and standalone indexes. Moved from the dabase app in 0.6.0.

import 'package:dabase_postgresql/src/catalog/catalog_query.dart';

/// A view (`v`) or materialized view (`m`).
final class ViewHeader {
  /// Creates a view header.
  const ViewHeader({
    required this.schema,
    required this.name,
    required this.def,
    this.relkind = 'v',
    this.options = const [],
    this.accessMethod,
    this.tablespace,
    this.isPopulated = true,
    this.owner,
    this.hasAcl = false,
    this.comment,
  });

  /// Reads the `viewHeaderSql` columns.
  factory ViewHeader.fromRow(CatalogRow row) => ViewHeader(
    schema: requireText(row, 'schema'),
    name: requireText(row, 'name'),
    def: requireText(row, 'def'),
    relkind: row['relkind'] ?? 'v',
    options: pgTextArray(row['reloptions']).nonNulls.toList(),
    accessMethod: row['access_method'],
    tablespace: row['tablespace'],
    isPopulated: pgBool(row['relispopulated']) ?? true,
    owner: row['owner'],
    hasAcl: row['relacl'] != null,
    comment: row['comment'],
  );

  /// Schema name.
  final String schema;

  /// View name.
  final String name;

  /// `pg_get_viewdef(oid, true)`, ending with `;`.
  final String def;

  /// `v` view, `m` materialized view.
  final String relkind;

  /// `reloptions` entries (`name=value`).
  final List<String> options;

  /// Table access method of a materialized view.
  final String? accessMethod;

  /// Tablespace of a materialized view, when not the default.
  final String? tablespace;

  /// A materialized view holds data (`relispopulated`).
  final bool isPopulated;

  /// Owner role name.
  final String? owner;

  /// `relacl IS NOT NULL`: grants differ from the defaults.
  final bool hasAcl;

  /// `COMMENT ON` text.
  final String? comment;

  /// Whether this is a materialized view.
  bool get isMaterialized => relkind == 'm';
}

/// A function, procedure, aggregate or window function.
final class RoutineHeader {
  /// Creates a routine header.
  const RoutineHeader({
    required this.schema,
    required this.name,
    required this.identityArgs,
    this.kind = 'f',
    this.def,
    this.owner,
    this.hasAcl = false,
    this.comment,
  });

  /// Reads the `routineHeaderSql` columns.
  factory RoutineHeader.fromRow(CatalogRow row) => RoutineHeader(
    schema: requireText(row, 'schema'),
    name: requireText(row, 'name'),
    identityArgs: row['identity_args'] ?? '',
    kind: row['prokind'] ?? 'f',
    def: row['def'],
    owner: row['owner'],
    hasAcl: row['proacl'] != null,
    comment: row['comment'],
  );

  /// Schema name.
  final String schema;

  /// Routine name.
  final String name;

  /// `pg_get_function_identity_arguments`, e.g. `a integer, b text`.
  final String identityArgs;

  /// `f` function, `p` procedure, `a` aggregate, `w` window.
  final String kind;

  /// `pg_get_functiondef`; always `null` for aggregates (it would error).
  final String? def;

  /// Owner role name.
  final String? owner;

  /// `proacl IS NOT NULL`: grants differ from the defaults.
  final bool hasAcl;

  /// `COMMENT ON` text.
  final String? comment;
}

/// `pg_aggregate` fields shown as properties in Browse.
final class AggregateRow {
  /// Creates an aggregate row.
  const AggregateRow({
    required this.transitionFunction,
    required this.stateType,
    this.kind = 'n',
    this.finalFunction,
    this.combineFunction,
    this.initialValue,
  });

  /// Reads the `aggregateSql` columns.
  factory AggregateRow.fromRow(CatalogRow row) => AggregateRow(
    transitionFunction: requireText(row, 'sfunc'),
    stateType: requireText(row, 'stype'),
    kind: row['aggkind'] ?? 'n',
    finalFunction: row['finalfunc'],
    combineFunction: row['combinefunc'],
    initialValue: row['initcond'],
  );

  /// SFUNC.
  final String transitionFunction;

  /// STYPE.
  final String stateType;

  /// `n` normal, `o` ordered-set, `h` hypothetical-set.
  final String kind;

  /// FINALFUNC.
  final String? finalFunction;

  /// COMBINEFUNC.
  final String? combineFunction;

  /// INITCOND.
  final String? initialValue;
}

/// A sequence and what owns it.
final class SequenceRow {
  /// Creates a sequence row.
  const SequenceRow({
    required this.schema,
    required this.name,
    required this.dataType,
    required this.start,
    required this.increment,
    required this.minValue,
    required this.maxValue,
    required this.cache,
    this.cycle = false,
    this.isUnlogged = false,
    this.ownedKind,
    this.ownedBySchema,
    this.ownedByTable,
    this.ownedByColumn,
    this.owner,
    this.hasAcl = false,
    this.comment,
  });

  /// Reads the `sequenceSql` columns.
  factory SequenceRow.fromRow(CatalogRow row) => SequenceRow(
    schema: requireText(row, 'schema'),
    name: requireText(row, 'name'),
    dataType: requireText(row, 'data_type'),
    start: requireText(row, 'seqstart'),
    increment: requireText(row, 'seqincrement'),
    minValue: requireText(row, 'seqmin'),
    maxValue: requireText(row, 'seqmax'),
    cache: requireText(row, 'seqcache'),
    cycle: pgBool(row['seqcycle']) ?? false,
    isUnlogged: row['relpersistence'] == 'u',
    ownedKind: row['owned_kind'],
    ownedBySchema: row['owned_by_schema'],
    ownedByTable: row['owned_by_table'],
    ownedByColumn: row['owned_by_column'],
    owner: row['owner'],
    hasAcl: row['relacl'] != null,
    comment: row['comment'],
  );

  /// Schema name.
  final String schema;

  /// Sequence name.
  final String name;

  /// `smallint`, `integer` or `bigint`.
  final String dataType;

  // Kept as server text: int8 values print exactly as the server sent them.

  /// START WITH.
  final String start;

  /// INCREMENT BY.
  final String increment;

  /// MINVALUE.
  final String minValue;

  /// MAXVALUE.
  final String maxValue;

  /// CACHE.
  final String cache;

  /// CYCLE.
  final bool cycle;

  /// An UNLOGGED sequence.
  final bool isUnlogged;

  /// `a` OWNED BY a column (serial), `i` identity column, `null` free.
  final String? ownedKind;

  /// Schema of the owning table.
  final String? ownedBySchema;

  /// The owning table.
  final String? ownedByTable;

  /// The owning column.
  final String? ownedByColumn;

  /// Owner role name.
  final String? owner;

  /// `relacl IS NOT NULL`: grants differ from the defaults.
  final bool hasAcl;

  /// `COMMENT ON` text.
  final String? comment;
}

/// A standalone index (opened from a table screen).
final class IndexHeader {
  /// Creates an index header.
  const IndexHeader({
    required this.schema,
    required this.name,
    required this.def,
    this.isValid = true,
    this.comment,
  });

  /// Reads the `indexSql` columns.
  factory IndexHeader.fromRow(CatalogRow row) => IndexHeader(
    schema: requireText(row, 'schema'),
    name: requireText(row, 'name'),
    def: requireText(row, 'def'),
    isValid: pgBool(row['indisvalid']) ?? true,
    comment: row['comment'],
  );

  /// Schema name.
  final String schema;

  /// Index name.
  final String name;

  /// `pg_get_indexdef` text.
  final String def;

  /// `false` after a failed `CREATE INDEX CONCURRENTLY`.
  final bool isValid;

  /// `COMMENT ON` text.
  final String? comment;
}
