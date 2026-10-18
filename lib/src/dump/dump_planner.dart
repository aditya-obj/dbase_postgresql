// File: dump_planner.dart
// Purpose: Turns a SchemaModel into the ordered items of a plain-SQL dump,
// in pg_dump's three sections:
//  * pre-data: schemas, extensions, types, routines, sequences, tables,
//    views, in pg_depend order (DependencyOrder) with object-type priority
//    as the tie-breaker. A column DEFAULT that calls a function caught in a
//    cycle with its table is moved to an ALTER TABLE after both; any other
//    cycle is written in priority order and reported.
//  * data: table data (in foreign-key order, which only matters for a
//    data-only restore) and sequence values.
//  * post-data: indexes, keys, other constraints, foreign keys, triggers,
//    rules, statistics, row-level security, materialized view refreshes,
//    comments and (optionally) grants. Foreign keys always come after the
//    data, so circular foreign keys need no special handling.
// No ownership is written (like `pg_dump --no-owner`).

import 'package:dbase_postgresql/src/catalog/schema_model.dart';
import 'package:dbase_postgresql/src/ddl/aggregate_ddl.dart';
import 'package:dbase_postgresql/src/ddl/ddl_statements.dart';
import 'package:dbase_postgresql/src/ddl/namespace_ddl.dart';
import 'package:dbase_postgresql/src/ddl/object_ddl_assembler.dart';
import 'package:dbase_postgresql/src/ddl/table_ddl_assembler.dart';
import 'package:dbase_postgresql/src/ddl/type_ddl.dart';
import 'package:dbase_postgresql/src/ddl/view_ddl_assembler.dart';
import 'package:dbase_postgresql/src/dump/dependency_order.dart';
import 'package:dbase_postgresql/src/dump/dump_options.dart';
import 'package:dbase_postgresql/src/sql/sql_quoting.dart';

/// pg_dump's archive sections.
enum DumpSection {
  /// Everything needed before data can load.
  preData,

  /// Table data and sequence values.
  data,

  /// Indexes, constraints, triggers and everything else.
  postData,
}

/// One entry of the dump: statements under a pg_dump-style TOC comment
/// (`-- Name: t; Type: TABLE; Schema: s`).
final class DumpItem {
  /// Creates an item.
  const DumpItem({
    required this.section,
    required this.type,
    required this.name,
    required this.statements,
    this.schema,
    this.inCycle = false,
  });

  /// Its section.
  final DumpSection section;

  /// pg_dump's TOC type, e.g. `TABLE`, `FK CONSTRAINT`, `COMMENT`.
  final String type;

  /// Object name (unquoted; routines with their arguments).
  final String name;

  /// Schema name, or `null` for schema-less objects.
  final String? schema;

  /// The SQL statements, each terminated.
  final List<String> statements;

  /// Written before something it needs, to cut a dependency cycle.
  final bool inCycle;
}

/// The ordered dump.
final class DumpPlan {
  /// Creates a plan.
  const DumpPlan({
    this.preData = const [],
    this.dataTables = const [],
    this.sequenceValues = const [],
    this.postData = const [],
    this.warnings = const [],
    this.skipped = const SkippedObjects(),
  });

  /// Pre-data items, in order.
  final List<DumpItem> preData;

  /// Tables whose rows are written, in order.
  final List<TableInfo> dataTables;

  /// `SELECT pg_catalog.setval(...)` items (data section).
  final List<DumpItem> sequenceValues;

  /// Post-data items, in order.
  final List<DumpItem> postData;

  /// What the planner found worth telling the user.
  final List<DumpWarning> warnings;

  /// What the dump does not cover.
  final SkippedObjects skipped;
}

/// Plans a dump of a [SchemaModel].
final class DumpPlanner {
  /// Creates a planner.
  const DumpPlanner();

  /// The dump of [model] for [options].
  DumpPlan plan(SchemaModel model, DumpOptions options) {
    final b = _Builder(model, options);
    return b.build();
  }
}

final class _Node {
  _Node(
    this.id,
    this.priority,
    this.schema,
    this.name,
    this.type,
    this.statements,
  );

  final String id;
  final int priority;
  final String schema;
  final String name;
  final String type;
  final List<String> Function() statements;

  static int compare(_Node a, _Node b) {
    final byPriority = a.priority.compareTo(b.priority);
    if (byPriority != 0) return byPriority;
    final bySchema = a.schema.compareTo(b.schema);
    if (bySchema != 0) return bySchema;
    final byName = a.name.compareTo(b.name);
    return byName != 0 ? byName : a.id.compareTo(b.id);
  }
}

// Pre-data priorities (tie-breakers only; pg_depend decides first).
const _pType = 3;
const _pRoutine = 4;
const _pAggregate = 5;
const _pSequence = 6;
const _pTable = 7;
const _pDefault = 8;
const _pView = 9;
const _pOwnedBy = 10;

final class _Builder {
  _Builder(this.model, this.options)
    : _tables = TableDdlAssembler(serverVersionNum: model.serverVersionNum);

  final SchemaModel model;
  final DumpOptions options;
  final TableDdlAssembler _tables;
  final _warnings = <DumpWarning>[];
  final _deferred = <int, Set<int>>{};

  late final Map<int, TableInfo> _tableByOid = {
    for (final t in model.tables) t.oid: t,
  };

  DumpPlan build() {
    final content = options.content;
    final order = content.hasSchema
        ? _preDataOrder()
        : const DependencyOrder<_Node>(order: []);
    final preData = [
      if (content.hasSchema) ..._schemaItems(),
      for (final node in order.order)
        DumpItem(
          section: DumpSection.preData,
          type: node.type,
          name: node.name,
          schema: node.schema.isEmpty ? null : node.schema,
          statements: node.statements(),
          inCycle: order.forced.contains(node),
        ),
    ];
    final dataTables = content.hasData ? _dataOrder() : const <TableInfo>[];
    final sequenceValues = content.hasData
        ? _sequenceValues()
        : const <DumpItem>[];
    final postData = [
      if (content.hasSchema) ..._postData(),
      if (content.hasData) ..._refreshes(),
      if (content.hasSchema) ..._comments(),
      if (content.hasSchema && options.includeGrants) ..._grants(),
    ];
    _scanData();
    return DumpPlan(
      preData: preData,
      dataTables: dataTables,
      sequenceValues: sequenceValues,
      postData: postData,
      warnings: List.unmodifiable(_warnings),
      skipped: model.skipped,
    );
  }

  // ---------------------------------------------------------------- pre-data

  List<DumpItem> _schemaItems() => [
    for (final s in model.schemas)
      if (s.name != 'public')
        DumpItem(
          section: DumpSection.preData,
          type: 'SCHEMA',
          name: s.name,
          statements: [createSchemaStatement(s.name)],
        ),
    for (final e in model.extensions)
      DumpItem(
        section: DumpSection.preData,
        type: 'EXTENSION',
        name: e.name,
        statements: [createExtensionStatement(e.name, e.schema)],
      ),
  ];

  DependencyOrder<_Node> _preDataOrder() {
    final nodes = <ObjectKey, _Node>{};
    for (final t in model.types) {
      nodes[ObjectKey(ObjectKind.type, t.oid)] = _Node(
        'type:${t.oid}',
        _pType,
        t.row.schema,
        t.row.name,
        t.row.objectKeyword,
        () => const TypeDdlAssembler().create(
          t.row,
          attributes: t.attributes,
          constraints: t.constraints,
        ),
      );
    }
    for (final r in model.routines) {
      final h = r.header;
      final aggregate = r.aggregate;
      final isAggregate = h.kind == 'a';
      if (isAggregate && aggregate == null) continue;
      if (!isAggregate && h.def == null) continue;
      nodes[ObjectKey(ObjectKind.routine, r.oid)] = _Node(
        'routine:${r.oid}',
        isAggregate ? _pAggregate : _pRoutine,
        h.schema,
        '${h.name}(${h.identityArgs})',
        switch (h.kind) {
          'p' => 'PROCEDURE',
          'a' => 'AGGREGATE',
          _ => 'FUNCTION',
        },
        () => [
          if (aggregate != null)
            createAggregateStatement(
              h.schema,
              h.name,
              h.identityArgs,
              aggregate,
            )
          else
            terminate(h.def!), // Checked above: non-aggregates have a def.
        ],
      );
    }
    for (final s in model.sequences) {
      if (s.isIdentity) continue;
      nodes[ObjectKey(ObjectKind.relation, s.oid)] = _Node(
        'sequence:${s.oid}',
        _pSequence,
        s.row.schema,
        s.row.name,
        'SEQUENCE',
        () => [const SequenceDdlAssembler().createStatement(s.row)],
      );
    }
    for (final t in model.tables) {
      nodes[ObjectKey(ObjectKind.relation, t.oid)] = _Node(
        'table:${t.oid}',
        _pTable,
        t.schema,
        t.name,
        'TABLE',
        () => [
          _tables
              .parts(
                t.source,
                keysInline: false,
                deferredDefaults: _deferred[t.oid] ?? const {},
              )
              .create,
        ],
      );
    }
    for (final v in model.views) {
      final h = v.source.header;
      nodes[ObjectKey(ObjectKind.relation, v.oid)] = _Node(
        'view:${v.oid}',
        _pView,
        h.schema,
        h.name,
        h.isMaterialized ? 'MATERIALIZED VIEW' : 'VIEW',
        () => [
          const ViewDdlAssembler().parts(v.source, withNoData: true).create,
        ],
      );
    }

    final needs = <_Node, Set<_Node>>{};
    final defaultEdges = <DependencyEdge>[];
    for (final edge in model.dependencies) {
      final from = nodes[edge.from];
      final to = nodes[edge.to];
      if (from == null || to == null) continue;
      (needs[from] ??= {}).add(to);
      if (edge.defaultOfColumn != null && edge.to.kind == ObjectKind.routine) {
        defaultEdges.add(edge);
      }
    }
    // A partition or inheritance child needs its parents.
    final tableByName = {
      for (final t in model.tables) (t.schema, t.name): t.oid,
    };
    for (final t in model.tables) {
      final child = nodes[ObjectKey(ObjectKind.relation, t.oid)]!;
      for (final p in t.source.parents) {
        final parentOid = tableByName[(p.schema, p.name)];
        if (parentOid == null) continue;
        (needs[child] ??= {}).add(
          nodes[ObjectKey(ObjectKind.relation, parentOid)]!,
        );
      }
    }

    // Break table <-> function cycles made by column defaults.
    var list = nodes.values.toList();
    final first = dependencyOrder(list, needs, _Node.compare);
    final cycleOf = <_Node, int>{
      for (final (i, cycle) in first.cycles.indexed)
        for (final n in cycle) n: i,
    };
    final extra = <_Node>[];
    final defaultNeeds = <int, Set<_Node>>{};
    for (final edge in defaultEdges) {
      final table = nodes[edge.from]!;
      final routine = nodes[edge.to]!;
      final cycle = cycleOf[table];
      if (cycle == null || cycleOf[routine] != cycle) continue;
      needs[table]!.remove(routine);
      (_deferred[edge.from.oid] ??= {}).add(edge.defaultOfColumn!);
      (defaultNeeds[edge.from.oid] ??= {}).add(routine);
    }
    for (final MapEntry(key: oid, value: routines) in defaultNeeds.entries) {
      final t = _tableByOid[oid]!;
      final tableNode = nodes[ObjectKey(ObjectKind.relation, oid)]!;
      final node = _Node(
        'default:$oid',
        _pDefault,
        t.schema,
        t.name,
        'DEFAULT',
        () => _tables
            .parts(
              t.source,
              keysInline: false,
              deferredDefaults: _deferred[oid]!,
            )
            .deferredDefaults,
      );
      extra.add(node);
      needs[node] = {tableNode, ...routines};
    }
    // OWNED BY after both the sequence and its table.
    for (final s in model.sequences) {
      if (s.isIdentity || s.row.ownedKind != 'a') continue;
      final sequence = nodes[ObjectKey(ObjectKind.relation, s.oid)];
      final owner = switch (s.ownedByRelation) {
        final oid? => nodes[ObjectKey(ObjectKind.relation, oid)],
        null => null,
      };
      if (sequence == null || owner == null) continue;
      final node = _Node(
        'owned:${s.oid}',
        _pOwnedBy,
        s.row.schema,
        s.row.name,
        'SEQUENCE OWNED BY',
        () => const SequenceDdlAssembler().ownedByStatement(s.row),
      );
      extra.add(node);
      needs[node] = {sequence, owner};
    }
    list = [...list, ...extra];
    final result = dependencyOrder(list, needs, _Node.compare);
    for (final cycle in result.cycles) {
      _warnings.add(
        DumpWarning(DumpWarningCode.dependencyCycle, [
          for (final n in cycle) _display(n.schema, n.name),
        ]),
      );
    }
    return result;
  }

  // -------------------------------------------------------------------- data

  List<TableInfo> _dataOrder() {
    final tables = [
      for (final t in model.tables)
        if (t.hasData) t,
    ];
    final needs = <TableInfo, Set<TableInfo>>{
      for (final t in tables)
        t: {
          for (final c in t.source.constraints)
            if (c.type == 'f' && c.referencedTable != t.oid)
              ?_tableByOid[c.referencedTable],
        },
    };
    final order = dependencyOrder(
      tables,
      needs,
      (a, b) => _compareNames(a.schema, a.name, a.oid, b.schema, b.name, b.oid),
    );
    if (options.content == DumpContent.dataOnly) {
      for (final cycle in order.cycles) {
        _warnings.add(
          DumpWarning(DumpWarningCode.dataOnlyForeignKeyCycle, [
            for (final t in cycle) _display(t.schema, t.name),
          ]),
        );
      }
    }
    return order.order;
  }

  List<DumpItem> _sequenceValues() {
    final unreadable = <String>[];
    final items = <DumpItem>[];
    final sequences = [...model.sequences]
      ..sort(
        (a, b) => _compareNames(
          a.row.schema,
          a.row.name,
          a.oid,
          b.row.schema,
          b.row.name,
          b.oid,
        ),
      );
    for (final s in sequences) {
      if (!s.isReadable) {
        unreadable.add(_display(s.row.schema, s.row.name));
        continue;
      }
      final value = s.lastValue ?? s.row.start;
      final isCalled = s.lastValue != null;
      final String target;
      if (s.isIdentity) {
        final table = s.row.ownedByTable;
        final column = s.row.ownedByColumn;
        if (table == null || column == null) continue;
        final qualified = qualifiedName(
          s.row.ownedBySchema ?? s.row.schema,
          table,
        );
        target =
            'pg_catalog.pg_get_serial_sequence(${quoteLiteral(qualified)}, '
            '${quoteLiteral(column)})';
      } else {
        target = quoteLiteral(qualifiedName(s.row.schema, s.row.name));
      }
      items.add(
        DumpItem(
          section: DumpSection.data,
          type: 'SEQUENCE SET',
          name: s.row.name,
          schema: s.row.schema,
          statements: ['SELECT pg_catalog.setval($target, $value, $isCalled);'],
        ),
      );
    }
    if (unreadable.isNotEmpty) {
      _warnings.add(
        DumpWarning(DumpWarningCode.unreadableSequence, unreadable),
      );
    }
    return items;
  }

  /// Warnings about the data itself.
  void _scanData() {
    final tableNames = {for (final t in model.tables) (t.schema, t.name)};
    final outside = <String>[];
    final money = <String>[];
    for (final t in model.tables) {
      for (final c in t.source.constraints) {
        if (c.type != 'f' || !c.isLocal) continue;
        final referenced = c.referencedTable;
        if (referenced != null && _tableByOid.containsKey(referenced)) continue;
        final target = _referencedName(c.def);
        if (target != null && tableNames.contains(target)) continue;
        outside.add(
          '${_display(t.schema, t.name)} -> '
          '${target == null ? '?' : _display(target.$1, target.$2)}',
        );
      }
      if (options.content.hasData &&
          t.source.columns.any((c) => c.type.startsWith('money'))) {
        money.add(_display(t.schema, t.name));
      }
    }
    if (outside.isNotEmpty) {
      _warnings.add(DumpWarning(DumpWarningCode.outsideReference, outside));
    }
    if (money.isNotEmpty) {
      _warnings.add(DumpWarning(DumpWarningCode.moneyColumns, money));
    }
  }

  // --------------------------------------------------------------- post-data

  List<DumpItem> _postData() {
    final tables = _orderedTables();
    final views = _orderedViews();
    final tableParts = {
      for (final t in tables)
        t: _tables.parts(
          t.source,
          keysInline: false,
          deferredDefaults: _deferred[t.oid] ?? const {},
        ),
    };
    final viewParts = {
      for (final v in views)
        v: const ViewDdlAssembler().parts(v.source, withNoData: true),
    };
    DumpItem item(String type, String? schema, String name, List<String> s) =>
        DumpItem(
          section: DumpSection.postData,
          type: type,
          name: name,
          schema: schema,
          statements: s,
        );
    List<DumpItem> each(
      String type,
      List<String> Function(TableInfo t, TableDdlParts p) pick,
    ) => [
      for (final t in tables)
        if (pick(t, tableParts[t]!) case final s when s.isNotEmpty)
          item(type, t.schema, t.name, s),
    ];
    return [
      ...each(
        'INDEX',
        (t, p) => t.relkind == 'p'
            ? [for (final s in p.indexes) _recursiveIndex(s)]
            : p.indexes,
      ),
      for (final v in views)
        if (viewParts[v]!.indexes case final s when s.isNotEmpty)
          item('INDEX', v.schema, v.name, s),
      ...each('CONSTRAINT', (t, p) => p.keyConstraints),
      ...each('CONSTRAINT', (t, p) => p.trailingConstraints),
      ...each('FK CONSTRAINT', (t, p) => p.foreignKeys),
      ...each('TABLE PROPERTIES', (t, p) => p.clusterAndReplicaIdentity),
      for (final v in views)
        if (viewParts[v]!.cluster case final s when s.isNotEmpty)
          item('TABLE PROPERTIES', v.schema, v.name, s),
      ...each('TRIGGER', (t, p) => p.triggers),
      ...each('RULE', (t, p) => p.rules),
      for (final v in views)
        if (viewParts[v]!.triggersAndRules case final s when s.isNotEmpty)
          item('TRIGGER', v.schema, v.name, s),
      ...each('STATISTICS', (t, p) => p.statistics),
      ...each('ROW SECURITY', (t, p) => p.rowSecurity),
    ];
  }

  List<DumpItem> _refreshes() => [
    for (final v in _orderedViews())
      if (v.source.header case final h when h.isMaterialized && h.isPopulated)
        DumpItem(
          section: DumpSection.postData,
          type: 'MATERIALIZED VIEW DATA',
          name: h.name,
          schema: h.schema,
          statements: [
            'REFRESH MATERIALIZED VIEW ${qualifiedName(h.schema, h.name)};',
          ],
        ),
  ];

  List<DumpItem> _comments() {
    DumpItem item(String? schema, String name, List<String> s) => DumpItem(
      section: DumpSection.postData,
      type: 'COMMENT',
      name: name,
      schema: schema,
      statements: s,
    );
    return [
      for (final s in model.schemas)
        if (s.comment != null)
          item(
            null,
            s.name,
            commentStatement('SCHEMA', quoteIdent(s.name), s.comment),
          ),
      for (final e in model.extensions)
        if (e.comment != null)
          item(
            null,
            e.name,
            commentStatement('EXTENSION', quoteIdent(e.name), e.comment),
          ),
      for (final t in model.types)
        if (t.row.comment != null)
          item(
            t.row.schema,
            t.row.name,
            const TypeDdlAssembler().comment(t.row),
          ),
      for (final r in model.routines)
        if (r.header.comment case final comment?)
          item(r.header.schema, '${r.header.name}(${r.header.identityArgs})', [
            ...commentStatement(
              switch (r.header.kind) {
                'p' => 'PROCEDURE',
                'a' => 'AGGREGATE',
                _ => 'FUNCTION',
              },
              '${qualifiedName(r.header.schema, r.header.name)}'
              '(${r.header.identityArgs})',
              comment,
            ),
          ]),
      for (final s in model.sequences)
        if (!s.isIdentity && s.row.comment != null)
          item(
            s.row.schema,
            s.row.name,
            commentStatement(
              'SEQUENCE',
              qualifiedName(s.row.schema, s.row.name),
              s.row.comment,
            ),
          ),
      for (final t in _orderedTables())
        if (_tables.parts(t.source).comments case final c when c.isNotEmpty)
          item(t.schema, t.name, c),
      for (final v in _orderedViews())
        if (const ViewDdlAssembler().parts(v.source).comments case final c
            when c.isNotEmpty)
          item(v.schema, v.name, c),
    ];
  }

  List<DumpItem> _grants() {
    DumpItem item(String? schema, String name, List<String> s) => DumpItem(
      section: DumpSection.postData,
      type: 'ACL',
      name: name,
      schema: schema,
      statements: s,
    );
    return [
      for (final s in model.schemas)
        if (schemaGrantStatements(s.name, s.grants) case final g
            when g.isNotEmpty)
          item(null, s.name, g),
      for (final r in model.routines)
        if (grantStatements(
              r.grants,
              '${r.header.kind == 'p' ? 'PROCEDURE' : 'FUNCTION'} '
              '${qualifiedName(r.header.schema, r.header.name)}'
              '(${r.header.identityArgs})',
            )
            case final g when g.isNotEmpty)
          item(
            r.header.schema,
            '${r.header.name}(${r.header.identityArgs})',
            g,
          ),
      for (final s in model.sequences)
        if (grantStatements(
              s.grants,
              'SEQUENCE ${qualifiedName(s.row.schema, s.row.name)}',
            )
            case final g when g.isNotEmpty)
          item(s.row.schema, s.row.name, g),
      for (final t in _orderedTables())
        if (_tables.parts(t.source).grants case final g when g.isNotEmpty)
          item(t.schema, t.name, g),
      for (final v in _orderedViews())
        if (const ViewDdlAssembler().parts(v.source).grants case final g
            when g.isNotEmpty)
          item(v.schema, v.name, g),
      if (defaultPrivilegeStatements(model.defaultPrivileges) case final g
          when g.isNotEmpty)
        item(null, 'DEFAULT PRIVILEGES', g),
    ];
  }

  // ----------------------------------------------------------------- helpers

  List<TableInfo> _orderedTables() => [...model.tables]
    ..sort(
      (a, b) => _compareNames(a.schema, a.name, a.oid, b.schema, b.name, b.oid),
    );

  List<ViewInfo> _orderedViews() => [...model.views]
    ..sort(
      (a, b) => _compareNames(a.schema, a.name, a.oid, b.schema, b.name, b.oid),
    );

  static int _compareNames(
    String schemaA,
    String nameA,
    int oidA,
    String schemaB,
    String nameB,
    int oidB,
  ) {
    final bySchema = schemaA.compareTo(schemaB);
    if (bySchema != 0) return bySchema;
    final byName = nameA.compareTo(nameB);
    return byName != 0 ? byName : oidA.compareTo(oidB);
  }

  static String _display(String schema, String name) =>
      schema.isEmpty ? name : '$schema.$name';

  /// `pg_get_indexdef` prints `ON ONLY` for an index of a partitioned
  /// table; without ONLY the CREATE INDEX recurses and builds the
  /// partitions' indexes too, which the dump does not list separately.
  static String _recursiveIndex(String statement) =>
      statement.replaceFirst(' ON ONLY ', ' ON ');

  static final _references = RegExp(
    r'REFERENCES\s+((?:"(?:[^"]|"")+"|[^\s."(]+)(?:\.(?:"(?:[^"]|"")+"|[^\s."(]+))?)\s*\(',
  );

  /// The `(schema, table)` a foreign key definition references, unquoted.
  static (String, String)? _referencedName(String def) {
    final match = _references.firstMatch(def);
    if (match == null) return null;
    final parts = _splitQualified(match.group(1)!);
    return parts.length == 2 ? (parts[0], parts[1]) : ('', parts.last);
  }

  static List<String> _splitQualified(String text) {
    final out = <String>[];
    final current = StringBuffer();
    var quoted = false;
    for (var i = 0; i < text.length; i++) {
      final ch = text[i];
      if (quoted) {
        if (ch == '"' && i + 1 < text.length && text[i + 1] == '"') {
          current.write('"');
          i++;
        } else if (ch == '"') {
          quoted = false;
        } else {
          current.write(ch);
        }
      } else if (ch == '"') {
        quoted = true;
      } else if (ch == '.') {
        out.add(current.toString());
        current.clear();
      } else {
        current.write(ch);
      }
    }
    out.add(current.toString());
    return out;
  }
}
