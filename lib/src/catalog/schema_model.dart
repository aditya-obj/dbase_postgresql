// File: schema_model.dart
// Purpose: The immutable result of one bulk catalog read: every object a
// dump (and later a schema diff or psql-style describe) needs, keyed by
// OID, with the dependency edges between them and counts of what is not
// covered. Built by CatalogReader.

import 'package:dbase_postgresql/src/ddl/aggregate_ddl.dart';
import 'package:dbase_postgresql/src/ddl/ddl_rows.dart';
import 'package:dbase_postgresql/src/ddl/namespace_ddl.dart';
import 'package:dbase_postgresql/src/ddl/object_ddl_rows.dart';
import 'package:dbase_postgresql/src/ddl/table_ddl_assembler.dart';
import 'package:dbase_postgresql/src/ddl/type_ddl.dart';
import 'package:dbase_postgresql/src/ddl/view_ddl_assembler.dart';

/// Which catalog an [ObjectKey] OID belongs to.
enum ObjectKind {
  /// `pg_namespace`.
  schema,

  /// `pg_extension`.
  extension,

  /// `pg_type` (enums, composites, ranges, domains).
  type,

  /// `pg_proc` (functions, procedures, aggregates).
  routine,

  /// `pg_class` (tables, views, materialized views, sequences).
  relation,
}

/// One catalog object: its kind and OID.
final class ObjectKey implements Comparable<ObjectKey> {
  /// Creates a key.
  const ObjectKey(this.kind, this.oid);

  /// The catalog.
  final ObjectKind kind;

  /// The OID in that catalog.
  final int oid;

  @override
  bool operator ==(Object other) =>
      other is ObjectKey && other.kind == kind && other.oid == oid;

  @override
  int get hashCode => Object.hash(kind, oid);

  @override
  int compareTo(ObjectKey other) => kind == other.kind
      ? oid.compareTo(other.oid)
      : kind.index.compareTo(other.kind.index);

  @override
  String toString() => '${kind.name}:$oid';
}

/// `from` needs `to` to exist first (a normalized `pg_depend` edge).
final class DependencyEdge {
  /// Creates an edge.
  const DependencyEdge(this.from, this.to, {this.defaultOfColumn});

  /// The dependent object.
  final ObjectKey from;

  /// The object it needs.
  final ObjectKey to;

  /// Set when the edge comes from the DEFAULT of this column (attnum) of
  /// the table [from]: the default can be written separately to break a
  /// cycle.
  final int? defaultOfColumn;

  @override
  bool operator ==(Object other) =>
      other is DependencyEdge &&
      other.from == from &&
      other.to == to &&
      other.defaultOfColumn == defaultOfColumn;

  @override
  int get hashCode => Object.hash(from, to, defaultOfColumn);

  @override
  String toString() => '$from -> $to';
}

/// A schema.
final class SchemaInfo {
  /// Creates a schema.
  const SchemaInfo({
    required this.oid,
    required this.name,
    this.comment,
    this.grants = const [],
  });

  /// `pg_namespace.oid`.
  final int oid;

  /// Schema name.
  final String name;

  /// `COMMENT ON SCHEMA` text.
  final String? comment;

  /// Grants (read only when grants are dumped).
  final List<GrantRow> grants;
}

/// An installed extension.
final class ExtensionInfo {
  /// Creates an extension.
  const ExtensionInfo({
    required this.oid,
    required this.name,
    required this.schema,
    this.comment,
    this.hasConfigTables = false,
  });

  /// `pg_extension.oid`.
  final int oid;

  /// Extension name.
  final String name;

  /// The schema it is installed in.
  final String schema;

  /// `COMMENT ON EXTENSION` text.
  final String? comment;

  /// Has configuration tables whose data is not dumped in v1.
  final bool hasConfigTables;
}

/// An enum, composite, range or domain type.
final class TypeInfo {
  /// Creates a type.
  const TypeInfo({
    required this.oid,
    required this.row,
    this.attributes = const [],
    this.constraints = const [],
  });

  /// `pg_type.oid`.
  final int oid;

  /// The type itself.
  final TypeRow row;

  /// A composite type's attributes.
  final List<TypeAttributeRow> attributes;

  /// A domain's CHECK constraints.
  final List<DomainConstraintRow> constraints;
}

/// A function, procedure or aggregate.
final class RoutineInfo {
  /// Creates a routine.
  const RoutineInfo({
    required this.oid,
    required this.header,
    this.aggregate,
    this.grants = const [],
  });

  /// `pg_proc.oid`.
  final int oid;

  /// Name, arguments and `pg_get_functiondef` text.
  final RoutineHeader header;

  /// The `pg_aggregate` row of an aggregate.
  final AggregateDefinition? aggregate;

  /// Grants (read only when grants are dumped).
  final List<GrantRow> grants;
}

/// A sequence, with its current value.
final class SequenceInfo {
  /// Creates a sequence.
  const SequenceInfo({
    required this.oid,
    required this.row,
    this.ownedByRelation,
    this.isReadable = true,
    this.lastValue,
    this.grants = const [],
  });

  /// `pg_class.oid`.
  final int oid;

  /// Definition and owning column.
  final SequenceRow row;

  /// The table owning it (serial or identity), if any.
  final int? ownedByRelation;

  /// The current user may read its value.
  final bool isReadable;

  /// `pg_sequence_last_value`: `null` when never used (or not readable).
  final String? lastValue;

  /// Grants (read only when grants are dumped).
  final List<GrantRow> grants;

  /// An identity column's sequence (created by its table).
  bool get isIdentity => row.ownedKind == 'i';
}

/// A table, partition or foreign table.
final class TableInfo {
  /// Creates a table.
  const TableInfo({
    required this.oid,
    required this.source,
    this.rowSecurityActive = false,
    this.totalBytes,
  });

  /// `pg_class.oid`.
  final int oid;

  /// Everything the table DDL needs.
  final TableDdlSource source;

  /// Row-level security applies to the current user's reads
  /// (`row_security_active`).
  final bool rowSecurityActive;

  /// `pg_total_relation_size`, for a size estimate.
  final int? totalBytes;

  /// Schema name.
  String get schema => source.header.schema;

  /// Table name.
  String get name => source.header.name;

  /// `r`, `p` or `f`.
  String get relkind => source.header.relkind;

  /// Holds rows of its own (a plain table or a leaf partition; not a
  /// partitioned parent or a foreign table).
  bool get hasData => relkind == 'r';

  /// The columns a COPY of its data lists: every column except generated
  /// ones (stored and virtual), in attnum order.
  List<String> get dataColumns => [
    for (final c in source.columns)
      if (c.generated.isEmpty) c.name,
  ];
}

/// A view or materialized view.
final class ViewInfo {
  /// Creates a view.
  const ViewInfo({required this.oid, required this.source});

  /// `pg_class.oid`.
  final int oid;

  /// Everything the view DDL needs.
  final ViewDdlSource source;

  /// Schema name.
  String get schema => source.header.schema;

  /// View name.
  String get name => source.header.name;
}

/// Kinds of objects a v1 dump does not write, with how many there are.
final class SkippedObjects {
  /// Creates the counts.
  const SkippedObjects({this.counts = const {}});

  /// Reads the `skippedCountsSql` row (zero counts are dropped).
  factory SkippedObjects.fromRow(Map<String, String?> row) => SkippedObjects(
    counts: {
      for (final MapEntry(:key, :value) in row.entries)
        if ((int.tryParse(value ?? '') ?? 0) > 0) key: int.parse(value!),
    },
  );

  /// Kind (`large_objects`, `publications`, `subscriptions`,
  /// `event_triggers`, `foreign_servers`, `foreign_tables`, `base_types`,
  /// `collations`, `operators`, `text_search_configs`,
  /// `extension_config_tables`) to a count above zero.
  final Map<String, int> counts;

  /// Whether nothing was skipped.
  bool get isEmpty => counts.isEmpty;
}

/// Everything one bulk catalog read found.
final class SchemaModel {
  /// Creates a model.
  const SchemaModel({
    required this.serverVersionNum,
    this.serverVersion = '',
    this.schemas = const [],
    this.extensions = const [],
    this.types = const [],
    this.routines = const [],
    this.sequences = const [],
    this.tables = const [],
    this.views = const [],
    this.dependencies = const [],
    this.defaultPrivileges = const [],
    this.skipped = const SkippedObjects(),
  });

  /// `server_version_num`, e.g. `170004`.
  final int serverVersionNum;

  /// `server_version`, e.g. `17.4`.
  final String serverVersion;

  /// Schemas to create (by name).
  final List<SchemaInfo> schemas;

  /// Extensions to create.
  final List<ExtensionInfo> extensions;

  /// User-defined types.
  final List<TypeInfo> types;

  /// Functions, procedures and aggregates.
  final List<RoutineInfo> routines;

  /// Sequences (identity ones included, for their values).
  final List<SequenceInfo> sequences;

  /// Tables, partitions and foreign tables.
  final List<TableInfo> tables;

  /// Views and materialized views.
  final List<ViewInfo> views;

  /// Normalized `pg_depend` edges between user objects.
  final List<DependencyEdge> dependencies;

  /// Default privileges (read only when grants are dumped).
  final List<DefaultPrivilegeRow> defaultPrivileges;

  /// What a v1 dump does not write.
  final SkippedObjects skipped;
}
