// File: explain_plan.dart
// Purpose: Typed model of `EXPLAIN (FORMAT JSON)` output: plans, nodes,
// actuals, buffers, triggers and JIT.
//
// Node naming (PlanNode.displayName) is ported from PEV2's `nodeName`
// (src/node.ts, https://github.com/dalibo/pev2 at commit 3cca315) -
// Copyright (c) 2019, Dalibo, PostgreSQL-style license. See
// THIRD_PARTY_NOTICES.

import 'package:dabase_postgresql/src/explain/plan_parser.dart';

/// One query's plan from `EXPLAIN (FORMAT JSON)`.
///
/// The server prints a JSON array with one element per query (rule
/// rewrites can produce more than one). Use [parseAll] for every element
/// or [ExplainPlan.parse] for the first.
final class ExplainPlan {
  /// Creates a plan around [root]. [nodes] is built from [root] in
  /// pre-order; each node's [PlanNode.id] must equal its pre-order index.
  ExplainPlan({
    required this.root,
    required this.analyzed,
    required this.timed,
    required this.hasBuffers,
    this.planningMs,
    this.executionMs,
    List<TriggerTiming> triggers = const [],
    this.jit,
    Map<String, String> settings = const {},
    this.queryIdentifier,
    Map<String, Object?> properties = const {},
  }) : triggers = List.unmodifiable(triggers),
       settings = Map.unmodifiable(settings),
       properties = Map.unmodifiable(properties),
       nodes = _preOrder(root);

  /// The first plan of [json]. Throws [FormatException] like [parseAll].
  factory ExplainPlan.parse(String json) => parseAll(json).first;

  /// Parses the JSON text (array of plans); throws FormatException on bad
  /// input.
  ///
  /// A single plan object (not wrapped in an array) is accepted too. Bad
  /// input is anything that is not valid JSON, an empty array, an element
  /// without a `Plan` object, a node without a string `Node Type`, or a
  /// known numeric, boolean or text key holding a value of another type.
  /// The exception never repeats the input.
  static List<ExplainPlan> parseAll(String json) => parseExplainJson(json);

  /// The root node (`Plan`).
  final PlanNode root;

  /// `Planning Time` in milliseconds (with `SUMMARY`, on by default with
  /// `ANALYZE`).
  final double? planningMs;

  /// `Execution Time` in milliseconds (`ANALYZE` with `SUMMARY`). It
  /// includes trigger and JIT time but not the transfer to the client.
  final double? executionMs;

  /// Triggers that fired (`ANALYZE`). Their time is not inside any node.
  /// Unmodifiable.
  final List<TriggerTiming> triggers;

  /// The `JIT` summary, when the query was JIT-compiled.
  final JitSummary? jit;

  /// `Settings` (`SETTINGS` option): non-default planner settings, as the
  /// server prints them. Unmodifiable.
  final Map<String, String> settings;

  /// `Query Identifier` (`VERBOSE` with `compute_query_id`), as text so the
  /// 64-bit value survives on the web. On the web the JSON decoder has
  /// already rounded it to a double, so it can be off in the last digits.
  final String? queryIdentifier;

  /// Whether `ANALYZE` ran: `Actual Loops` is present on some node.
  final bool analyzed;

  /// Whether timing was measured: `Actual Total Time` is present on some
  /// node (absent with `TIMING OFF` or without `ANALYZE`).
  final bool timed;

  /// Whether `BUFFERS` output is present on some node or under `Planning`.
  final bool hasBuffers;

  /// Every top-level key except `Plan` (`Planning`, `Serialization`, `JIT`,
  /// `Triggers`, ...), as decoded. Unmodifiable.
  final Map<String, Object?> properties;

  /// Every node in pre-order; `nodes[i].id == i`. Unmodifiable.
  final List<PlanNode> nodes;

  static List<PlanNode> _preOrder(PlanNode root) {
    final out = <PlanNode>[];
    final stack = <PlanNode>[root];
    while (stack.isNotEmpty) {
      final node = stack.removeLast();
      if (node.id != out.length) {
        throw ArgumentError.value(
          node.id,
          'root',
          'node ids must be pre-order indexes (expected ${out.length})',
        );
      }
      out.add(node);
      for (var i = node.children.length - 1; i >= 0; i--) {
        stack.add(node.children[i]);
      }
    }
    return List.unmodifiable(out);
  }
}

/// One plan node.
final class PlanNode {
  /// Creates a node. Prefer [ExplainPlan.parse]; this constructor exists for
  /// tests and tools that build plans by hand.
  PlanNode({
    required this.id,
    required this.depth,
    required this.nodeType,
    this.parentId,
    String? displayName,
    this.relationship,
    this.subplanName,
    this.relation,
    this.schema,
    this.alias,
    this.index,
    this.cte,
    this.function,
    this.joinType,
    this.strategy,
    this.operation,
    this.partialMode,
    this.scanDirection,
    this.parallelAware = false,
    this.asyncCapable = false,
    this.disabled = false,
    this.startupCost,
    this.totalCost,
    this.planRows,
    this.planWidth,
    this.actual,
    this.workersPlanned,
    this.workersLaunched,
    this.buffers,
    Map<String, Object?> properties = const {},
    List<PlanNode> children = const [],
  }) : displayName =
           displayName ??
           composeDisplayName(
             nodeType: nodeType,
             operation: operation,
             strategy: strategy,
             partialMode: partialMode,
             scanDirection: scanDirection,
             joinType: joinType,
             parallelAware: parallelAware,
             asyncCapable: asyncCapable,
           ),
       properties = Map.unmodifiable(properties),
       children = List.unmodifiable(children);

  /// Pre-order index in [ExplainPlan.nodes], starting at 0 for the root.
  final int id;

  /// Nesting depth; 0 for the root.
  final int depth;

  /// The parent's [id]; `null` for the root.
  final int? parentId;

  /// The raw `Node Type`, e.g. `Seq Scan`, `Aggregate`, `ModifyTable`.
  final String nodeType;

  /// The name as `EXPLAIN` text format (and PEV2) shows it: `Parallel` and
  /// `Async` prefixes, `HashAggregate`/`GroupAggregate`/`MixedAggregate`
  /// and `HashSetOp` from `Strategy`, `Partial`/`Finalize`, `Backward`, the
  /// join type (`Hash Left Join`, `Nested Loop Anti Join`) and the
  /// `ModifyTable` operation (`Update`).
  final String displayName;

  /// `Parent Relationship`: `Outer`, `Inner`, `Member`, `Subquery`,
  /// `InitPlan`, `SubPlan`, ... `null` for the root.
  final String? relationship;

  /// `Subplan Name`: `CTE x`, `InitPlan 1` (`InitPlan 1 (returns $0)`
  /// before PostgreSQL 17), `SubPlan 2`.
  final String? subplanName;

  /// `Relation Name`.
  final String? relation;

  /// `Schema` (with `VERBOSE`).
  final String? schema;

  /// `Alias`.
  final String? alias;

  /// `Index Name`.
  final String? index;

  /// `CTE Name`.
  final String? cte;

  /// `Function Name`.
  final String? function;

  /// `Join Type`: `Inner`, `Left`, `Full`, `Right`, `Semi`, `Anti`,
  /// `Right Semi`, `Right Anti`.
  final String? joinType;

  /// `Strategy` of `Aggregate`/`SetOp`: `Plain`, `Sorted`, `Hashed`,
  /// `Mixed`.
  final String? strategy;

  /// `Operation` of `ModifyTable`: `Insert`, `Update`, `Delete`, `Merge`.
  final String? operation;

  /// `Partial Mode` of `Aggregate`: `Simple`, `Partial`, `Finalize`.
  final String? partialMode;

  /// `Scan Direction`: `Forward`, `Backward`, `NoMovement`.
  final String? scanDirection;

  /// `Parallel Aware`.
  final bool parallelAware;

  /// `Async Capable` (PostgreSQL 14+).
  final bool asyncCapable;

  /// Whether the planner used this node although a setting disabled it:
  /// `"Disabled": true` (PostgreSQL 18+), or, when that key is absent, a
  /// `Total Cost` of at least [disabledCost] that none of the children
  /// reach (PostgreSQL 17 and older add `disable_cost` = 1e10, and parents
  /// inherit it, so only the lowest such node is marked).
  final bool disabled;

  /// `Startup Cost` (absent with `COSTS OFF`).
  final double? startupCost;

  /// `Total Cost` (absent with `COSTS OFF`).
  final double? totalCost;

  /// `Plan Rows`: estimated rows per loop (per process under `Gather`).
  final double? planRows;

  /// `Plan Width` in bytes.
  final int? planWidth;

  /// The measured values; `null` without `ANALYZE`.
  final NodeActuals? actual;

  /// `Workers Planned` (`Gather`/`Gather Merge`).
  final int? workersPlanned;

  /// `Workers Launched` (`Gather`/`Gather Merge` with `ANALYZE`).
  final int? workersLaunched;

  /// Buffer counters (`BUFFERS`): totals over all loops, including the
  /// children's.
  final BufferCounts? buffers;

  /// Every raw key of the node except `Plans`, as decoded, for a detail
  /// view. Unmodifiable.
  final Map<String, Object?> properties;

  /// The child nodes (`Plans`), in server order: InitPlans, outer, inner,
  /// members, SubPlans. Unmodifiable.
  final List<PlanNode> children;

  /// `disable_cost` of PostgreSQL 17 and older.
  static const double disabledCost = 10000000000;

  /// What the node works on, for a second label: `orders_pkey on orders`
  /// (index on table), `public.orders o` (schema with `VERBOSE`, alias when
  /// it differs), `CTE x`, the function name, an index alone (`Bitmap Index
  /// Scan`), or the alias alone (`Subquery Scan`). `null` when there is
  /// nothing.
  String? get target {
    final rel = relation;
    final qualified = rel == null
        ? null
        : schema == null
        ? rel
        : '$schema.$rel';
    final aliasSuffix = alias != null && alias != rel && alias != function
        ? ' $alias'
        : '';
    if (index != null) {
      return qualified == null ? index : '$index on $qualified$aliasSuffix';
    }
    if (qualified != null) return '$qualified$aliasSuffix';
    if (function != null) return '$function$aliasSuffix';
    if (cte != null) return 'CTE $cte';
    return alias;
  }

  @override
  String toString() => 'PlanNode($id, $displayName)';
}

/// Composes [PlanNode.displayName] from the raw fields, like `EXPLAIN` text
/// format and PEV2's `nodeName`.
///
/// Differences from PEV2: `Async` is added once (PEV2 adds it twice), and a
/// sorted `SetOp` stays `SetOp` (PEV2 prints `GroupSetOp`; the server
/// prints `SetOp`).
String composeDisplayName({
  required String nodeType,
  String? operation,
  String? strategy,
  String? partialMode,
  String? scanDirection,
  String? joinType,
  bool parallelAware = false,
  bool asyncCapable = false,
}) {
  var name = nodeType == 'ModifyTable' && operation != null
      ? operation
      : nodeType;
  final strategyPrefix = switch ((nodeType, strategy)) {
    ('Aggregate', 'Sorted') => 'Group',
    ('Aggregate', 'Hashed') => 'Hash',
    ('Aggregate', 'Mixed') => 'Mixed',
    ('SetOp', 'Hashed') => 'Hash',
    _ => '',
  };
  name = '$strategyPrefix$name';
  if (partialMode != null && partialMode != 'Simple') {
    name = '$partialMode $name';
  }
  if (scanDirection == 'Backward') name = '$name Backward';
  if (joinType != null && joinType != 'Inner') {
    // `Nested Loop` has no `Join` suffix; `Hash Join` becomes `Hash Left
    // Join`.
    name = name.endsWith(' Join')
        ? '${name.substring(0, name.length - 5)} $joinType Join'
        : '$name $joinType Join';
  }
  if (asyncCapable) name = 'Async $name';
  if (parallelAware) name = 'Parallel $name';
  return name;
}

/// What `ANALYZE` measured for a node. Times and rows are per loop
/// (averages); multiply by [loops] for totals.
final class NodeActuals {
  /// Creates measured values.
  const NodeActuals({
    required this.rows,
    required this.loops,
    this.startupMs,
    this.totalMs,
  });

  /// `Actual Startup Time` per loop; `null` with `TIMING OFF`.
  final double? startupMs;

  /// `Actual Total Time` per loop; `null` with `TIMING OFF`.
  final double? totalMs;

  /// `Actual Rows` per loop. Fractional on PostgreSQL 18+; rounded to an
  /// integer before.
  final double rows;

  /// `Actual Loops`; 0 when the node never ran.
  final int loops;

  /// Whether the node never ran (`Actual Loops` = 0).
  bool get neverExecuted => loops == 0;
}

/// Buffer counters from `BUFFERS`, in 8 kB blocks. Totals over all loops.
final class BufferCounts {
  /// Creates counters; missing ones are 0.
  const BufferCounts({
    this.sharedHit = 0,
    this.sharedRead = 0,
    this.sharedDirtied = 0,
    this.sharedWritten = 0,
    this.localHit = 0,
    this.localRead = 0,
    this.tempRead = 0,
    this.tempWritten = 0,
    this.localDirtied = 0,
    this.localWritten = 0,
  });

  /// `Shared Hit Blocks`.
  final int sharedHit;

  /// `Shared Read Blocks`.
  final int sharedRead;

  /// `Shared Dirtied Blocks`.
  final int sharedDirtied;

  /// `Shared Written Blocks`.
  final int sharedWritten;

  /// `Local Hit Blocks`.
  final int localHit;

  /// `Local Read Blocks`.
  final int localRead;

  /// `Temp Read Blocks`.
  final int tempRead;

  /// `Temp Written Blocks`.
  final int tempWritten;

  /// `Local Dirtied Blocks`.
  final int localDirtied;

  /// `Local Written Blocks`.
  final int localWritten;

  /// `this` minus [other], field by field, never below 0.
  BufferCounts minus(BufferCounts other) {
    int d(int a, int b) => a > b ? a - b : 0;
    return BufferCounts(
      sharedHit: d(sharedHit, other.sharedHit),
      sharedRead: d(sharedRead, other.sharedRead),
      sharedDirtied: d(sharedDirtied, other.sharedDirtied),
      sharedWritten: d(sharedWritten, other.sharedWritten),
      localHit: d(localHit, other.localHit),
      localRead: d(localRead, other.localRead),
      tempRead: d(tempRead, other.tempRead),
      tempWritten: d(tempWritten, other.tempWritten),
      localDirtied: d(localDirtied, other.localDirtied),
      localWritten: d(localWritten, other.localWritten),
    );
  }

  /// `this` plus [other], field by field.
  BufferCounts plus(BufferCounts other) => BufferCounts(
    sharedHit: sharedHit + other.sharedHit,
    sharedRead: sharedRead + other.sharedRead,
    sharedDirtied: sharedDirtied + other.sharedDirtied,
    sharedWritten: sharedWritten + other.sharedWritten,
    localHit: localHit + other.localHit,
    localRead: localRead + other.localRead,
    tempRead: tempRead + other.tempRead,
    tempWritten: tempWritten + other.tempWritten,
    localDirtied: localDirtied + other.localDirtied,
    localWritten: localWritten + other.localWritten,
  );
}

/// One entry of `Triggers` (`ANALYZE`).
final class TriggerTiming {
  /// Creates a trigger timing.
  const TriggerTiming({
    required this.name,
    required this.calls,
    this.constraintName,
    this.relation,
    this.timeMs,
  });

  /// `Trigger Name`, e.g. `RI_ConstraintTrigger_a_16410` for a foreign key.
  final String name;

  /// `Constraint Name`, for constraint triggers (foreign keys).
  final String? constraintName;

  /// `Relation`: the table the trigger is on.
  final String? relation;

  /// `Time` in milliseconds, all calls together; `null` with `TIMING OFF`.
  final double? timeMs;

  /// `Calls`.
  final int calls;
}

/// The `JIT` summary.
final class JitSummary {
  /// Creates a JIT summary.
  const JitSummary({required this.functions, this.totalMs});

  /// `Functions`: how many functions were compiled.
  final int functions;

  /// `Timing.Total` in milliseconds; `null` without timing. It is already
  /// included in the node times and in [ExplainPlan.executionMs].
  final double? totalMs;
}
