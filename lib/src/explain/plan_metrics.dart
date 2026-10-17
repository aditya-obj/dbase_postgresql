// File: plan_metrics.dart
// Purpose: Per-node derived numbers for an ExplainPlan: inclusive and
// self (exclusive) time, self cost, row totals and estimate factors.
//
// The time algorithm is ported from PEV2's PlanService (`processNode`,
// `calculateExclusives`, `childrenDuration`, `fixCteScansDuration`,
// `fixInitPlanUsageDuration`, `calculatePlannerEstimate` in
// src/services/plan-service.ts, https://github.com/dalibo/pev2 at commit
// 3cca315) - Copyright (c) 2019, Dalibo, PostgreSQL-style license. See
// THIRD_PARTY_NOTICES.

import 'dart:math' as math;

import 'package:dbase_postgresql/src/explain/explain_plan.dart';

/// Which way the planner's row estimate was wrong.
enum EstimateDirection {
  /// Fewer rows were estimated than came out (actual > estimated).
  under,

  /// More rows were estimated than came out (actual < estimated).
  over,

  /// The estimate matched (after rounding both sides up to at least 1).
  exact,

  /// Not known: no `ANALYZE`, no `Plan Rows`, or the node never ran.
  unknown,
}

/// Derived numbers for one node. See [PlanMetrics].
final class NodeMetrics {
  /// Creates node metrics.
  const NodeMetrics({
    required this.participants,
    this.inclusiveMs,
    this.selfMs,
    this.selfPercent,
    this.selfCost,
    this.selfCostPercent,
    this.totalRows,
    this.rowsRemoved,
    this.estimateFactor,
    this.direction = EstimateDirection.unknown,
    this.selfBuffers,
  });

  /// Processes that ran the node: workers launched by the enclosing
  /// `Gather`/`Gather Merge` plus the leader, else 1. InitPlans, SubPlans
  /// and CTEs keep their parent's value.
  final int participants;

  /// Time spent in the node and its children, in ms:
  /// `Actual Total Time × loops ÷ participants` (0 if never executed).
  /// `null` without timing.
  final double? inclusiveMs;

  /// Time spent in the node alone, in ms, never negative. `null` without
  /// timing.
  final double? selfMs;

  /// [selfMs] as a percentage (0..100) of `Execution Time`, or of the
  /// root's inclusive time when the plan has no `Execution Time`.
  final double? selfPercent;

  /// Estimated cost of the node alone: `Total Cost` minus the children's,
  /// never negative, with PostgreSQL 17's `disable_cost` (1e10) removed.
  /// A per-execution estimate: a `Nested Loop`'s value is overstated
  /// because its inner child's cost covers one execution only. Use it for
  /// plan-only bars. `null` with `COSTS OFF`.
  final double? selfCost;

  /// [selfCost] as a percentage (0..100) of the sum of every node's
  /// [selfCost], so plan-only bars add up to 100.
  final double? selfCostPercent;

  /// `Actual Rows × loops`. `null` without `ANALYZE`.
  final double? totalRows;

  /// Rows removed by `Filter`, `Join Filter` and `Index Recheck`, times
  /// loops. `null` when the node has none of these counters.
  final double? rowsRemoved;

  /// How far the row estimate was off, at least 1: the larger of
  /// estimated and actual rows per loop divided by the smaller, each
  /// raised to at least 1 so 0 rows doesn't give infinity. `null` when
  /// [direction] is [EstimateDirection.unknown].
  final double? estimateFactor;

  /// Which way the estimate was off.
  final EstimateDirection direction;

  /// Buffers of the node alone: its counters minus those of the same
  /// children whose time is subtracted for [selfMs]. CTE and InitPlan
  /// buffers are not moved the way their time is. `null` without
  /// `BUFFERS`.
  final BufferCounts? selfBuffers;
}

/// Derived numbers for every node of an [ExplainPlan].
///
/// Self time follows PEV2: inclusive time minus the children's inclusive
/// time (InitPlans are not subtracted except under `Result`; CTEs never
/// are), then a CTE's time is taken from the `CTE Scan`s that read it in
/// proportion to their inclusive time, and an InitPlan's time is taken
/// from each node whose expressions use its result (`$n` before
/// PostgreSQL 17, `InitPlan n` from 17). Results are clamped at 0.
final class PlanMetrics {
  PlanMetrics._(this.nodes, this.triggerMs, this.otherMs);

  /// Computes the metrics of [plan].
  // A static method (not a factory) is the agreed API shape.
  // ignore: prefer_constructors_over_static_methods
  static PlanMetrics compute(ExplainPlan plan) {
    final nodes = plan.nodes;
    final n = nodes.length;

    // Participants, top-down (pre-order: parents come first).
    final participants = List<int>.filled(n, 1);
    for (final node in nodes) {
      for (final child in node.children) {
        participants[child.id] = _keepsParentWorkers(child)
            ? participants[node.id]
            : node.workersLaunched != null
            ? node.workersLaunched! + 1
            : participants[node.id];
      }
    }

    // Inclusive and self time.
    final inclusive = List<double?>.filled(n, null);
    for (final node in nodes) {
      final actual = node.actual;
      if (actual == null || actual.totalMs == null) continue;
      inclusive[node.id] = actual.loops == 0
          ? 0
          : actual.totalMs! * actual.loops / participants[node.id];
    }
    final self = List<double?>.filled(n, null);
    for (final node in nodes) {
      final total = inclusive[node.id];
      if (total == null) continue;
      var value = total;
      for (final child in node.children) {
        if (_subtractedFromParent(node, child)) {
          value -= inclusive[child.id] ?? 0;
        }
      }
      self[node.id] = value;
    }
    if (plan.timed) {
      _fixCteScans(nodes, inclusive, self);
      _fixInitPlanUsers(nodes, inclusive, self);
    }

    final basis = plan.executionMs ?? inclusive[0];
    final selfCost = List<double?>.filled(n, null);
    var selfCostSum = 0.0;
    for (final node in nodes) {
      final total = node.totalCost;
      if (total == null) continue;
      var value = _realCost(total);
      for (final child in node.children) {
        final c = child.totalCost;
        if (c != null) value -= _realCost(c);
      }
      selfCost[node.id] = math.max(0, value);
      selfCostSum += selfCost[node.id]!;
    }

    var selfSum = 0.0;
    final metrics = <NodeMetrics>[];
    for (final node in nodes) {
      final raw = self[node.id];
      final s = raw == null ? null : (raw < 0 ? 0.0 : raw);
      if (s != null) selfSum += s;
      final cost = selfCost[node.id];
      final actual = node.actual;
      final (factor, direction) = _estimate(node);
      metrics.add(
        NodeMetrics(
          participants: participants[node.id],
          inclusiveMs: inclusive[node.id],
          selfMs: s,
          selfPercent: s == null || basis == null || basis <= 0
              ? null
              : _percent(s / basis),
          selfCost: cost,
          selfCostPercent: cost == null
              ? null
              : selfCostSum <= 0
              ? 0
              : _percent(cost / selfCostSum),
          totalRows: actual == null ? null : actual.rows * actual.loops,
          rowsRemoved: _rowsRemoved(node),
          estimateFactor: factor,
          direction: direction,
          selfBuffers: _selfBuffers(node),
        ),
      );
    }

    var triggerMs = 0.0;
    for (final t in plan.triggers) {
      triggerMs += t.timeMs ?? 0;
    }
    double? otherMs;
    final execution = plan.executionMs;
    if (plan.timed && execution != null && execution > 0) {
      final other = execution - selfSum - triggerMs;
      if (other > execution * otherThreshold) otherMs = other;
    }
    return PlanMetrics._(List.unmodifiable(metrics), triggerMs, otherMs);
  }

  /// [otherMs] is reported only above this share of `Execution Time`.
  static const double otherThreshold = 0.05;

  /// Metrics of every node, indexed by [PlanNode.id]. Unmodifiable.
  final List<NodeMetrics> nodes;

  /// The metrics of the node with [PlanNode.id] == [nodeId].
  NodeMetrics operator [](int nodeId) => nodes[nodeId];

  /// Total `Triggers` time in ms (0 when none fired). Triggers run outside
  /// the plan tree but count toward `Execution Time`.
  final double triggerMs;

  /// `Execution Time` minus every node's self time and [triggerMs], when
  /// that is more than 5 % of `Execution Time` (an "Other" row), else
  /// `null`.
  final double? otherMs;

  /// Whether [child] runs with its parent's processes: InitPlans,
  /// SubPlans and CTEs are run by the process that needs them.
  static bool _keepsParentWorkers(PlanNode child) =>
      child.relationship == 'InitPlan' ||
      child.relationship == 'SubPlan' ||
      _isCte(child);

  static bool _isCte(PlanNode node) =>
      node.subplanName?.startsWith('CTE ') ?? false;

  /// PEV2 `childrenDuration`: every child except InitPlans, unless the
  /// parent is a `Result`. CTEs are never subtracted here; the CTE fix
  /// takes their time from the scans that read them.
  static bool _subtractedFromParent(PlanNode parent, PlanNode child) =>
      !_isCte(child) &&
      (child.relationship != 'InitPlan' || parent.nodeType == 'Result');

  static void _fixCteScans(
    List<PlanNode> nodes,
    List<double?> inclusive,
    List<double?> self,
  ) {
    for (final cte in nodes.where(_isCte)) {
      final cteMs = inclusive[cte.id] ?? 0;
      if (cteMs == 0) continue;
      final name = cte.subplanName!.substring(4);
      final scans = [
        for (final node in nodes)
          if (node.nodeType == 'CTE Scan' && node.cte == name) node,
      ];
      var sum = 0.0;
      for (final scan in scans) {
        sum += inclusive[scan.id] ?? 0;
      }
      if (sum <= 0) continue;
      for (final scan in scans) {
        final s = self[scan.id];
        if (s == null) continue;
        self[scan.id] = s - cteMs * (inclusive[scan.id] ?? 0) / sum;
      }
    }
  }

  static final _initPlanName = RegExp(r'^InitPlan (\d+)(?: \(returns (.*)\))?');
  static final _param = RegExp(r'\$\d+');

  /// Keys that name the node rather than hold its expressions.
  static const _identityKeys = {
    'Node Type',
    'Parent Relationship',
    'Subplan Name',
    'Relation Name',
    'Schema',
    'Alias',
    'Index Name',
    'CTE Name',
    'Function Name',
  };

  static void _fixInitPlanUsers(
    List<PlanNode> nodes,
    List<double?> inclusive,
    List<double?> self,
  ) {
    for (final init in nodes) {
      if (init.relationship != 'InitPlan' || _isCte(init)) continue;
      final match = _initPlanName.firstMatch(init.subplanName ?? '');
      if (match == null) continue;
      final initMs = inclusive[init.id] ?? 0;
      if (initMs == 0) continue;
      // PostgreSQL 16 and older reference the result as `$n`; 17+ as
      // `(InitPlan n).colN`. A trailing digit must not follow, so `$1`
      // doesn't match `$10`.
      final returns = match.group(2);
      final names = returns == null
          ? ['InitPlan ${match.group(1)}']
          : [for (final m in _param.allMatches(returns)) m.group(0)!];
      if (names.isEmpty) continue;
      final pattern = RegExp(
        '(?:${names.map(RegExp.escape).join('|')})(?![0-9])',
      );
      final subtreeEnd = _subtreeEnd(nodes, init);
      for (final user in nodes) {
        if (user.id >= init.id && user.id < subtreeEnd) continue;
        if (user.relationship == 'InitPlan') continue;
        // A Result parent already subtracted the InitPlan as a child.
        if (init.parentId == user.id && user.nodeType == 'Result') continue;
        final s = self[user.id];
        if (s == null || s == 0) continue;
        if (_mentions(user, pattern)) self[user.id] = s - initMs;
      }
    }
  }

  /// One past the last pre-order id inside [node]'s subtree.
  static int _subtreeEnd(List<PlanNode> nodes, PlanNode node) {
    var end = node.id + 1;
    while (end < nodes.length && nodes[end].depth > node.depth) {
      end++;
    }
    return end;
  }

  static bool _mentions(PlanNode node, RegExp pattern) {
    for (final e in node.properties.entries) {
      if (_identityKeys.contains(e.key)) continue;
      final value = e.value;
      if (value is String && pattern.hasMatch(value)) return true;
      if (value is List<Object?>) {
        for (final item in value) {
          if (item is String && pattern.hasMatch(item)) return true;
        }
      }
    }
    return false;
  }

  /// [cost] without PostgreSQL 17's `disable_cost` multiples.
  static double _realCost(double cost) =>
      cost >= PlanNode.disabledCost ? cost % PlanNode.disabledCost : cost;

  static double _percent(double ratio) =>
      math.min(100, math.max(0, ratio * 100));

  static (double?, EstimateDirection) _estimate(PlanNode node) {
    final actual = node.actual;
    final planned = node.planRows;
    if (actual == null || actual.neverExecuted || planned == null) {
      return (null, EstimateDirection.unknown);
    }
    final estimated = planned < 1 ? 1.0 : planned;
    final real = actual.rows < 1 ? 1.0 : actual.rows;
    if (real > estimated) return (real / estimated, EstimateDirection.under);
    if (real < estimated) return (estimated / real, EstimateDirection.over);
    return (1, EstimateDirection.exact);
  }

  static const _removedKeys = [
    'Rows Removed by Filter',
    'Rows Removed by Join Filter',
    'Rows Removed by Index Recheck',
  ];

  static double? _rowsRemoved(PlanNode node) {
    double? sum;
    for (final key in _removedKeys) {
      final v = node.properties[key];
      if (v is num) sum = (sum ?? 0) + v.toDouble();
    }
    if (sum == null) return null;
    final loops = node.actual?.loops ?? 1;
    return sum * loops;
  }

  static BufferCounts? _selfBuffers(PlanNode node) {
    final own = node.buffers;
    if (own == null) return null;
    var children = const BufferCounts();
    for (final child in node.children) {
      final b = child.buffers;
      if (b != null && _subtractedFromParent(node, child)) {
        children = children.plus(b);
      }
    }
    return own.minus(children);
  }
}
