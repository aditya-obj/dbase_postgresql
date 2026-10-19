// File: catalog_reader.dart
// Purpose: Reads the catalog in bulk (one statement per kind of object,
// not per object) into a SchemaModel, the way pg_dump's getTables,
// getIndexes, ... do: a 2,000-table database takes about 25 round trips
// instead of 20,000. The per-object DDL recipes and their row parsers are
// reused with an OID-array filter, so Browse and a dump print the same DDL.
// Notes: Run it inside the caller's transaction (a dump uses REPEATABLE
// READ, READ ONLY) with an empty search_path so names come back
// schema-qualified.

import 'package:dabase_postgresql/src/catalog/catalog_query.dart';
import 'package:dabase_postgresql/src/catalog/catalog_sql.dart';
import 'package:dabase_postgresql/src/catalog/schema_model.dart';
import 'package:dabase_postgresql/src/ddl/aggregate_ddl.dart';
import 'package:dabase_postgresql/src/ddl/ddl_rows.dart';
import 'package:dabase_postgresql/src/ddl/namespace_ddl.dart';
import 'package:dabase_postgresql/src/ddl/object_ddl_queries.dart';
import 'package:dabase_postgresql/src/ddl/object_ddl_rows.dart';
import 'package:dabase_postgresql/src/ddl/table_ddl_assembler.dart';
import 'package:dabase_postgresql/src/ddl/table_ddl_queries.dart';
import 'package:dabase_postgresql/src/ddl/table_ddl_rows.dart';
import 'package:dabase_postgresql/src/ddl/type_ddl.dart';
import 'package:dabase_postgresql/src/ddl/view_ddl_assembler.dart';

/// What a catalog read covers.
final class CatalogScope {
  /// Every object in the schemas [schemaOids]. With [wholeDatabase],
  /// extensions installed in `pg_catalog` and database-wide default
  /// privileges are included too.
  const CatalogScope.schemas(this.schemaOids, {this.wholeDatabase = false})
    : tableOids = null;

  /// Only the tables [tableOids] (with their partitions and the sequences
  /// they own), like `pg_dump -t`: no types, routines or extensions.
  const CatalogScope.tables(List<int> this.tableOids)
    : schemaOids = const [],
      wholeDatabase = false;

  /// The schemas whose objects are read (empty for a table scope).
  final List<int> schemaOids;

  /// The tables picked, or `null` for a schema scope.
  final List<int>? tableOids;

  /// A whole-database read.
  final bool wholeDatabase;

  /// Whether only picked tables are read.
  bool get isTables => tableOids != null;
}

/// One relation found by [CatalogReader.listRelations].
final class ListedRelation {
  /// Creates a listed relation.
  const ListedRelation({
    required this.oid,
    required this.schemaOid,
    required this.schema,
    required this.name,
    required this.relkind,
    this.isPartition = false,
    this.totalBytes,
  });

  /// Reads the `relationListingSql` columns.
  factory ListedRelation.fromRow(CatalogRow row) => ListedRelation(
    oid: rowRelid(row),
    schemaOid: pgInt(row['schema_oid']) ?? 0,
    schema: requireText(row, 'schema'),
    name: requireText(row, 'name'),
    relkind: requireText(row, 'relkind'),
    isPartition: pgBool(row['relispartition']) ?? false,
    totalBytes: pgInt(row['total_bytes']),
  );

  /// `pg_class.oid`.
  final int oid;

  /// `relnamespace`.
  final int schemaOid;

  /// Schema name.
  final String schema;

  /// Relation name.
  final String name;

  /// `r`, `p`, `f`, `v`, `m` or `S`.
  final String relkind;

  /// A partition.
  final bool isPartition;

  /// `pg_total_relation_size` of tables and materialized views.
  final int? totalBytes;
}

/// The relations a read covers, listed before the rest is read so the
/// caller can lock the tables first (as pg_dump does).
final class RelationListing {
  /// Creates a listing.
  const RelationListing(this.relations);

  /// Every listed relation, by schema and name.
  final List<ListedRelation> relations;

  /// Tables and partitions (foreign tables are not dumped in v1).
  List<ListedRelation> get tables => [
    for (final r in relations)
      if (r.relkind == 'r' || r.relkind == 'p') r,
  ];

  /// Views and materialized views.
  List<ListedRelation> get views => [
    for (final r in relations)
      if (r.relkind == 'v' || r.relkind == 'm') r,
  ];

  /// Sequences.
  List<ListedRelation> get sequences => [
    for (final r in relations)
      if (r.relkind == 'S') r,
  ];

  /// What `LOCK TABLE ... IN ACCESS SHARE MODE` should cover: tables and
  /// partitioned tables, as pg_dump does. The server refuses LOCK on a
  /// materialized view (42809), and the REPEATABLE READ snapshot already
  /// gives its contents a consistent view.
  List<ListedRelation> get lockable => [
    for (final r in relations)
      if (r.relkind == 'r' || r.relkind == 'p') r,
  ];

  /// The sum of `pg_total_relation_size` over tables and materialized
  /// views: roughly the size of a data dump (indexes included, so an
  /// overestimate).
  int get totalBytes =>
      relations.fold(0, (sum, r) => sum + (r.totalBytes ?? 0));
}

/// Facts about the server (`serverFactsSql`).
final class ServerFacts {
  /// Creates server facts.
  const ServerFacts({
    required this.versionNum,
    required this.version,
    this.inRecovery = false,
  });

  /// `server_version_num`.
  final int versionNum;

  /// `server_version`.
  final String version;

  /// A hot standby (`pg_is_in_recovery()`).
  final bool inRecovery;
}

/// Reads catalog objects in bulk through a [CatalogQuery].
final class CatalogReader {
  /// Creates a reader for a server of [serverVersionNum].
  CatalogReader(this._query, {required this.serverVersionNum});

  final CatalogQuery _query;

  /// The server's `server_version_num`, which gates columns.
  final int serverVersionNum;

  /// Reads `server_version_num`, `server_version` and the recovery state.
  static Future<ServerFacts> serverFacts(CatalogQuery query) async {
    final row = (await query(serverFactsSql)).single;
    return ServerFacts(
      versionNum: pgInt(row['version_num']) ?? 0,
      version: row['version'] ?? '',
      inRecovery: pgBool(row['in_recovery']) ?? false,
    );
  }

  /// Lists the relations in [scope].
  Future<RelationListing> listRelations(CatalogScope scope) async {
    final rows = await _query(relationListingSql, [
      oidArrayLiteral(scope.schemaOids),
      switch (scope.tableOids) {
        final oids? => oidArrayLiteral(oids),
        null => null,
      },
    ]);
    return RelationListing([for (final r in rows) ListedRelation.fromRow(r)]);
  }

  /// Reads every object of [scope]; [listing] is what [listRelations]
  /// returned for it. Grants and default privileges are read only with
  /// [includeGrants].
  Future<SchemaModel> read(
    CatalogScope scope,
    RelationListing listing, {
    bool includeGrants = false,
    String serverVersion = '',
  }) async {
    final schemaOids = scope.isTables
        ? {for (final r in listing.relations) r.schemaOid}.toList()
        : scope.schemaOids;
    final schemaArray = oidArrayLiteral(schemaOids);
    final tableOids = [for (final r in listing.tables) r.oid];
    final viewOids = [for (final r in listing.views) r.oid];
    final matviewOids = [
      for (final r in listing.views)
        if (r.relkind == 'm') r.oid,
    ];
    final sequenceOids = [for (final r in listing.sequences) r.oid];
    final sizes = {for (final r in listing.relations) r.oid: r.totalBytes};

    final schemas = await _schemas(schemaArray, includeGrants: includeGrants);
    final tables = await _tables(
      tableOids,
      matviewOids,
      viewOids,
      sizes,
      includeGrants: includeGrants,
    );
    final views = await _views(viewOids, includeGrants: includeGrants);
    final sequences = await _sequences(
      sequenceOids,
      includeGrants: includeGrants,
    );
    final types = scope.isTables
        ? const <TypeInfo>[]
        : await _types(schemaArray);
    final routines = scope.isTables
        ? const <RoutineInfo>[]
        : await _routines(schemaArray, includeGrants: includeGrants);
    final whole = scope.wholeDatabase ? 't' : 'f';
    final extensionRows = scope.isTables
        ? const <CatalogRow>[]
        : await _query(extensionsSql, [schemaArray, whole]);
    final extensions = [
      for (final row in extensionRows)
        ExtensionInfo(
          oid: rowRelid(row),
          name: requireText(row, 'name'),
          schema: requireText(row, 'schema'),
          comment: row['comment'],
          hasConfigTables: pgBool(row['has_config']) ?? false,
        ),
    ];
    final privilegeRows = includeGrants && !scope.isTables
        ? await _query(defaultPrivilegesSql, [schemaArray, whole])
        : const <CatalogRow>[];
    final defaultPrivileges = [
      for (final row in privilegeRows) DefaultPrivilegeRow.fromRow(row),
    ];
    final dependencies = await _dependencies();
    final skippedRow = (await _query(skippedCountsSql, [schemaArray])).single;
    final configTables = extensions.where((e) => e.hasConfigTables).length;
    final skipped = SkippedObjects.fromRow({
      ...skippedRow,
      if (configTables > 0) 'extension_config_tables': '$configTables',
    });
    return SchemaModel(
      serverVersionNum: serverVersionNum,
      serverVersion: serverVersion,
      schemas: schemas,
      extensions: extensions,
      types: types,
      routines: routines,
      sequences: sequences,
      tables: tables,
      views: views,
      dependencies: dependencies,
      defaultPrivileges: defaultPrivileges,
      skipped: skipped,
    );
  }

  Future<List<SchemaInfo>> _schemas(
    String schemaArray, {
    required bool includeGrants,
  }) async {
    final rows = await _query(schemasSql, [schemaArray]);
    final grants = includeGrants
        ? await _grouped(schemaGrantsSql, schemaArray, GrantRow.fromRow)
        : const <int, List<GrantRow>>{};
    return [
      for (final row in rows)
        SchemaInfo(
          oid: rowRelid(row),
          name: requireText(row, 'name'),
          comment: row['comment'],
          grants: grants[rowRelid(row)] ?? const [],
        ),
    ];
  }

  Future<List<TableInfo>> _tables(
    List<int> tableOids,
    List<int> matviewOids,
    List<int> viewOids,
    Map<int, int?> sizes, {
    required bool includeGrants,
  }) async {
    if (tableOids.isEmpty && viewOids.isEmpty) return const [];
    final tables = oidArrayLiteral(tableOids);
    final withIndexes = oidArrayLiteral([...tableOids, ...matviewOids]);
    final withRules = oidArrayLiteral([...tableOids, ...viewOids]);
    const many = OidFilter.many;
    final headers = tableOids.isEmpty
        ? const <CatalogRow>[]
        : await _query(tableHeaderQuery(many), [tables]);
    final parents = await _grouped(
      tableParentsQuery(many),
      tables,
      ParentRow.fromRow,
    );
    final columns = await _grouped(
      tableColumnsSql(serverVersionNum, filter: many),
      tables,
      ColumnRow.fromRow,
    );
    final identities = await _grouped(
      tableIdentitiesQuery(many),
      tables,
      IdentityRow.fromRow,
    );
    final constraints = await _grouped(
      tableConstraintsSql(serverVersionNum, filter: many),
      tables,
      ConstraintRow.fromRow,
    );
    _indexes = await _grouped(
      relationIndexesQuery(many),
      withIndexes,
      IndexRow.fromRow,
    );
    _triggers = await _grouped(
      relationTriggersQuery(many),
      withRules,
      TriggerRow.fromRow,
    );
    _rules = await _grouped(
      relationRulesQuery(many),
      withRules,
      RuleRow.fromRow,
    );
    final statistics = await _grouped(
      tableStatisticsQuery(many),
      tables,
      (row) => requireText(row, 'def'),
    );
    final policies = await _grouped(
      tablePoliciesQuery(many),
      tables,
      PolicyRow.fromRow,
    );
    final grants = includeGrants
        ? await _grouped(relationGrantsQuery(many), tables, GrantRow.fromRow)
        : const <int, List<GrantRow>>{};
    return [
      for (final row in headers)
        _table(
          rowRelid(row),
          row,
          parents: parents,
          columns: columns,
          identities: identities,
          constraints: constraints,
          statistics: statistics,
          policies: policies,
          grants: grants,
          totalBytes: sizes[rowRelid(row)],
        ),
    ];
  }

  // Shared by tables and views; set by _tables before _views runs.
  Map<int, List<IndexRow>> _indexes = const {};
  Map<int, List<TriggerRow>> _triggers = const {};
  Map<int, List<RuleRow>> _rules = const {};

  TableInfo _table(
    int oid,
    CatalogRow header, {
    required Map<int, List<ParentRow>> parents,
    required Map<int, List<ColumnRow>> columns,
    required Map<int, List<IdentityRow>> identities,
    required Map<int, List<ConstraintRow>> constraints,
    required Map<int, List<String>> statistics,
    required Map<int, List<PolicyRow>> policies,
    required Map<int, List<GrantRow>> grants,
    required int? totalBytes,
  }) => TableInfo(
    oid: oid,
    rowSecurityActive: pgBool(header['rls_active']) ?? false,
    totalBytes: totalBytes,
    source: TableDdlSource(
      header: TableHeader.fromRow(header),
      parents: parents[oid] ?? const [],
      columns: columns[oid] ?? const [],
      identities: identities[oid] ?? const [],
      constraints: constraints[oid] ?? const [],
      indexes: _indexes[oid] ?? const [],
      triggers: _triggers[oid] ?? const [],
      rules: _rules[oid] ?? const [],
      statistics: statistics[oid] ?? const [],
      policies: policies[oid] ?? const [],
      grants: grants[oid] ?? const [],
    ),
  );

  Future<List<ViewInfo>> _views(
    List<int> viewOids, {
    required bool includeGrants,
  }) async {
    if (viewOids.isEmpty) return const [];
    final views = oidArrayLiteral(viewOids);
    const many = OidFilter.many;
    final headers = await _query(viewHeaderQuery(many), [views]);
    final comments = await _grouped(
      relationColumnCommentsQuery(many),
      views,
      ColumnCommentRow.fromRow,
    );
    final grants = includeGrants
        ? await _grouped(relationGrantsQuery(many), views, GrantRow.fromRow)
        : const <int, List<GrantRow>>{};
    return [
      for (final row in headers)
        // A view dropped since the listing has no definition left.
        if (row['def'] != null)
          _view(rowRelid(row), ViewHeader.fromRow(row), comments, grants),
    ];
  }

  ViewInfo _view(
    int oid,
    ViewHeader header,
    Map<int, List<ColumnCommentRow>> comments,
    Map<int, List<GrantRow>> grants,
  ) => ViewInfo(
    oid: oid,
    source: ViewDdlSource(
      header: header,
      columnComments: comments[oid] ?? const [],
      triggers: header.isMaterialized ? const [] : _triggers[oid] ?? const [],
      rules: _rules[oid] ?? const [],
      indexes: header.isMaterialized ? _indexes[oid] ?? const [] : const [],
      grants: grants[oid] ?? const [],
    ),
  );

  Future<List<SequenceInfo>> _sequences(
    List<int> sequenceOids, {
    required bool includeGrants,
  }) async {
    if (sequenceOids.isEmpty) return const [];
    final sequences = oidArrayLiteral(sequenceOids);
    final rows = await _query(sequenceQuery(OidFilter.many), [sequences]);
    final grants = includeGrants
        ? await _grouped(
            relationGrantsQuery(OidFilter.many),
            sequences,
            GrantRow.fromRow,
          )
        : const <int, List<GrantRow>>{};
    return [
      for (final row in rows)
        SequenceInfo(
          oid: rowRelid(row),
          row: SequenceRow.fromRow(row),
          ownedByRelation: pgInt(row['owned_by_relid']),
          isReadable: pgBool(row['readable']) ?? true,
          lastValue: row['last_value'],
          grants: grants[rowRelid(row)] ?? const [],
        ),
    ];
  }

  Future<List<TypeInfo>> _types(String schemaArray) async {
    final rows = await _query(typesSql(serverVersionNum), [schemaArray]);
    if (rows.isEmpty) return const [];
    final composites = [
      for (final row in rows)
        if (row['typtype'] == 'c') rowRelid(row),
    ];
    final domains = [
      for (final row in rows)
        if (row['typtype'] == 'd') rowRelid(row),
    ];
    final attributes = composites.isEmpty
        ? const <int, List<TypeAttributeRow>>{}
        : await _grouped(
            typeAttributesSql,
            oidArrayLiteral(composites),
            TypeAttributeRow.fromRow,
          );
    final constraints = domains.isEmpty
        ? const <int, List<DomainConstraintRow>>{}
        : await _grouped(
            domainConstraintsSql,
            oidArrayLiteral(domains),
            DomainConstraintRow.fromRow,
          );
    return [
      for (final row in rows)
        TypeInfo(
          oid: rowRelid(row),
          row: TypeRow.fromRow(row),
          attributes: attributes[rowRelid(row)] ?? const [],
          constraints: constraints[rowRelid(row)] ?? const [],
        ),
    ];
  }

  Future<List<RoutineInfo>> _routines(
    String schemaArray, {
    required bool includeGrants,
  }) async {
    final oids = [
      for (final row in await _query(routineListingSql, [schemaArray]))
        rowRelid(row),
    ];
    if (oids.isEmpty) return const [];
    final routines = oidArrayLiteral(oids);
    final headers = await _query(routineHeaderQuery(OidFilter.many), [
      routines,
    ]);
    final aggregateOids = [
      for (final row in headers)
        if (row['prokind'] == 'a') rowRelid(row),
    ];
    final aggregates = aggregateOids.isEmpty
        ? const <int, CatalogRow>{}
        : {
            for (final row in await _query(aggregatesSql, [
              oidArrayLiteral(aggregateOids),
            ]))
              rowRelid(row): row,
          };
    final grants = includeGrants
        ? await _grouped(
            routineGrantsQuery(OidFilter.many),
            routines,
            GrantRow.fromRow,
          )
        : const <int, List<GrantRow>>{};
    return [
      for (final row in headers)
        RoutineInfo(
          oid: rowRelid(row),
          header: RoutineHeader.fromRow(row),
          aggregate: switch (aggregates[rowRelid(row)]) {
            final a? => AggregateDefinition.fromRow(a),
            null => null,
          },
          grants: grants[rowRelid(row)] ?? const [],
        ),
    ];
  }

  Future<List<DependencyEdge>> _dependencies() async {
    final rows = await _query(dependenciesSql(serverVersionNum));
    ObjectKey key(String? kind, String? oid) => ObjectKey(switch (kind) {
      'rel' => ObjectKind.relation,
      'type' => ObjectKind.type,
      'proc' => ObjectKind.routine,
      _ => throw FormatException('Unknown dependency kind "$kind".'),
    }, pgInt(oid) ?? 0);
    return [
      for (final row in rows)
        DependencyEdge(
          key(row['kind'], row['key']),
          key(row['ref_kind'], row['ref_key']),
          defaultOfColumn: row['via'] == 'default'
              ? pgInt(row['attnum'])
              : null,
        ),
    ];
  }

  /// Runs [sql] with `$1` = [array] and groups the parsed rows by `relid`.
  Future<Map<int, List<T>>> _grouped<T>(
    String sql,
    String array,
    T Function(CatalogRow row) parse,
  ) async {
    if (array == '{}') return const {};
    final out = <int, List<T>>{};
    for (final row in await _query(sql, [array])) {
      (out[rowRelid(row)] ??= []).add(parse(row));
    }
    return out;
  }
}
