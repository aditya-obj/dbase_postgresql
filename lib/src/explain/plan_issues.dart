// File: plan_issues.dart
// Purpose: Heuristics that find the few plan problems worth fixing, ranked
// by the share of execution time a fix could save.
//
// Thresholds marked "PEV2" come from PEV2's severity bands (src/node.ts,
// https://github.com/dalibo/pev2 at commit 3cca315, Copyright (c) 2019,
// Dalibo, PostgreSQL-style license; see THIRD_PARTY_NOTICES). The ranking
// idea (score by time saved, show the best three above a minimum) follows
// pgMustard's public documentation, and the sequential-scan rule follows
// the published idea of depesz's Pg::Explain hinter; no code or wording
// is taken from either. Thresholds marked "ours" are tunable.

import 'dart:math' as math;

import 'package:dabase_postgresql/src/explain/explain_plan.dart';
import 'package:dabase_postgresql/src/explain/plan_metrics.dart';

/// Stable identifiers for [PlanIssue]s. The library has no wording: the
/// app words each issue from its code and [PlanIssue.facts].
///
/// Unless stated otherwise, `percent` is the node's share (0..100) of
/// execution time, `ms` its time in milliseconds, and `relation` the table
/// the node reads or writes (`Relation Name`), when it has one.
enum PlanIssueCode {
  /// One node's self time is at least [PlanIssues.dominantPercent] % of
  /// the execution time. Facts: `percent`, `ms`, `relation`. Not reported
  /// for a node that already has a more specific issue.
  dominantNode,

  /// Rows estimated and actual differ by at least
  /// [PlanIssues.badEstimateFactor] × at a node whose parent (a join,
  /// sort or aggregate, looking through `Hash`, `Materialize`, `Memoize`
  /// and `Gather`) took at least [PlanIssues.estimateParentPercent] % of
  /// the time. Only the node where the error starts is reported, not the
  /// ancestors that inherit it. Facts: `estimated` and `actual` (rows ×
  /// loops), `factor`, `percent`/`ms` (the parent's inclusive time),
  /// `relation`.
  badRowEstimate,

  /// A `Seq Scan` whose filter removed more than
  /// [PlanIssues.seqScanRemovedRatio] × the rows it kept, read more than
  /// [PlanIssues.seqScanMinPages] pages' worth of rows, and took at least
  /// [PlanIssues.minImpact] of the time: an index may help. Facts:
  /// `removed`, `kept` (totals), `percent`, `ms`, `relation`, and `column`
  /// when the filter is a single `column op constant`.
  indexPotential,

  /// An index or bitmap heap scan whose filter removed at least
  /// [PlanIssues.indexRemovedPercent] % of the rows the index found.
  /// Facts: `percent` (removed share of rows), `removed`, `kept`, `ms`,
  /// `relation`, `column` (simple filters only).
  poorIndexEfficiency,

  /// A sort that spilled to disk (`external sort`/`external merge`, in the
  /// node or a worker). Facts: `percent`, `ms`, `diskKb` (when known),
  /// `setting` (`work_mem`).
  sortOnDisk,

  /// A hash table or hash aggregate that did not fit in memory (`Hash
  /// Batches` > 1, `HashAgg Batches` > 1, `Disk Usage` > 0), or another
  /// non-sort node that wrote temporary files. Raising `work_mem` (or
  /// `hash_mem_multiplier` for hash nodes) helps; lowering does not.
  /// Facts: `percent`, `ms`, `batches` (when known), `diskKb` (when
  /// known), `setting` (`work_mem`).
  hashOnDisk,

  /// A `Nested Loop` whose inner side ran at least
  /// [PlanIssues.manyLoopsMin] times and took at least
  /// [PlanIssues.manyLoopsPercent] % of the time. Facts: `loops`,
  /// `percent`/`ms` (the inner side's inclusive time), and `estimated`,
  /// `actual`, `factor` when the outer side's row estimate was off by at
  /// least [PlanIssues.badEstimateFactor] ×.
  manyLoops,

  /// A bitmap heap scan that went lossy (`Lossy Heap Blocks` > 0) and
  /// rechecked rows. Facts: `removed` (rows removed by the recheck),
  /// `percent`, `ms`, `relation`, `setting` (`work_mem`).
  lossyBitmap,

  /// An `Index Only Scan` that still visited the table for more than
  /// [PlanIssues.heapFetchPercent] % of rows (the table needs `VACUUM`).
  /// Facts: `percent` (heap fetches per row), `ms`, `relation`.
  excessiveHeapFetches,

  /// A node that read many blocks itself: at least
  /// [PlanIssues.cacheMinBlocks] shared blocks with more than
  /// [PlanIssues.cacheReadPercent] % read from disk, or more than
  /// [PlanIssues.cacheBlocksPerRow] blocks per row returned. Needs
  /// `BUFFERS`. Facts: `readMb`, `percent` (read share of blocks), `ms`,
  /// `relation`.
  poorCachePerformance,

  /// JIT compilation took at least [PlanIssues.jitPercent] % of the
  /// execution time and at least [PlanIssues.jitMinMs] ms. Facts: `jitMs`,
  /// `executionMs`, `percent`, `setting` (`jit`).
  jitOverhead,

  /// A `Gather` launched fewer workers than planned. Facts: `planned`,
  /// `launched`, `percent`/`ms` (the Gather's inclusive time), `setting`
  /// (`max_parallel_workers`).
  workersMissing,

  /// Planning took at least [PlanIssues.planningPercent] % of planning
  /// plus execution and at least [PlanIssues.planningMinMs] ms. Facts:
  /// `planningMs`, `executionMs`, `percent` (planning share).
  slowPlanning,

  /// Triggers (foreign-key checks included) took at least
  /// [PlanIssues.triggerPercent] % of the execution time. Facts: `ms` and
  /// `percent` (all triggers), `triggerName` (its constraint name when the
  /// plan gives none) and `relation` of the slowest trigger.
  triggerTime,

  /// The planner used a node a setting disabled (`enable_* = off`). Runs
  /// without `ANALYZE` too, ranked by the node's share of the estimated
  /// cost. Facts: `percent` (time or cost share), `ms` (with timing),
  /// `relation`, `setting` (the matching `enable_*` setting when the plan
  /// lists it as off).
  disabledNode,
}

/// One finding of [PlanIssues.find].
final class PlanIssue {
  /// Creates an issue.
  PlanIssue({
    required this.code,
    required this.impact,
    required this.score,
    this.nodeId,
    Map<String, Object> facts = const {},
  }) : facts = Map.unmodifiable(facts);

  /// What was found.
  final PlanIssueCode code;

  /// The node to highlight; `null` for plan-wide issues (JIT, planning,
  /// triggers).
  final int? nodeId;

  /// 0..1 share of execution time the fix could save.
  final double impact;

  /// 0..5: `5 × impact × confidence`, where confidence (0.5..1) grows with
  /// how far past its threshold the finding is.
  final double score;

  /// Numbers/names the app needs to word the issue: use these keys where
  /// they apply — 'percent'(num 0..100), 'ms'(num), 'estimated'(num),
  /// 'actual'(num), 'factor'(num), 'removed'(num), 'kept'(num),
  /// 'column'(String, only when a simple `col op const` filter),
  /// 'loops'(num), 'diskKb'(num), 'batches'(num), 'planned'(int),
  /// 'launched'(int), 'readMb'(num), 'planningMs'(num), 'executionMs'(num),
  /// 'jitMs'(num), 'triggerName'(String), 'relation'(String),
  /// 'setting'(String). Each [PlanIssueCode] lists the keys it fills.
  /// Unmodifiable.
  final Map<String, Object> facts;

  @override
  String toString() =>
      'PlanIssue(${code.name}, node: $nodeId, '
      'impact: ${impact.toStringAsFixed(3)}, score: '
      '${score.toStringAsFixed(2)})';
}

/// Finds and ranks plan issues.
abstract final class PlanIssues {
  /// Queries whose planning plus execution time is below this get no
  /// issues; node checks also need this much execution time.
  static const double fastQueryMs = 10;

  /// Issues must be able to save at least this share of execution time.
  static const double minImpact = 0.10;

  /// [PlanIssueCode.dominantNode] threshold, % of time (PEV2 band).
  static const double dominantPercent = 40;

  /// Self time at which a dominant node gets full confidence (PEV2 band).
  static const double dominantStrongPercent = 90;

  /// [PlanIssueCode.badRowEstimate] factor (PEV2/pgAdmin band).
  static const double badEstimateFactor = 10;

  /// Estimate factor with full confidence (PEV2/pgAdmin band).
  static const double strongEstimateFactor = 1000;

  /// Minimum inclusive time of the parent that relied on an estimate, %.
  static const double estimateParentPercent = 10;

  /// `Seq Scan`: removed rows must exceed this multiple of kept rows
  /// (2/3 of rows removed, depesz's rule).
  static const double seqScanRemovedRatio = 2;

  /// `Seq Scan`: rows × width must exceed this many 8 kB pages (depesz).
  static const int seqScanMinPages = 3;

  /// Index scans: share of rows removed by the filter, % (PEV2 band).
  static const double indexRemovedPercent = 50;

  /// Index scans: removed share with full confidence, % (PEV2 band).
  static const double indexRemovedStrongPercent = 90;

  /// Inner-side loops for [PlanIssueCode.manyLoops] (ours).
  static const int manyLoopsMin = 1000;

  /// Inner-side loops with full confidence (ours).
  static const int manyLoopsStrong = 100000;

  /// Inner-side inclusive time for [PlanIssueCode.manyLoops], % (ours).
  static const double manyLoopsPercent = 20;

  /// Heap fetches per row for [PlanIssueCode.excessiveHeapFetches], %
  /// (PEV2 band).
  static const double heapFetchPercent = 40;

  /// Heap fetch share with full confidence, % (PEV2 band).
  static const double heapFetchStrongPercent = 90;

  /// Minimum self shared blocks for [PlanIssueCode.poorCachePerformance]
  /// (ours; 10,000 blocks = 80 MB).
  static const int cacheMinBlocks = 10000;

  /// Read share of shared blocks, % (ours).
  static const double cacheReadPercent = 50;

  /// Blocks per returned row (ours).
  static const double cacheBlocksPerRow = 100;

  /// JIT share of execution time, % (ours).
  static const double jitPercent = 10;

  /// Minimum JIT time, ms (ours).
  static const double jitMinMs = 50;

  /// Planning share of planning + execution, % (PEV2 band).
  static const double planningPercent = 10;

  /// Minimum planning time, ms (ours).
  static const double planningMinMs = 10;

  /// Trigger share of execution time, % (ours).
  static const double triggerPercent = 10;

  /// Ranked issues (≤ [max]); empty for queries under [fastQueryMs].
  /// Without ANALYZE only plan-only checks (disabledNode, …).
  ///
  /// Issues below [minImpact] are dropped; the rest are ordered by score,
  /// then impact, then node id.
  static List<PlanIssue> find(
    ExplainPlan plan,
    PlanMetrics metrics, {
    int max = 3,
  }) {
    if (max <= 0) return const [];
    final found = _Finder(plan, metrics).run();
    final kept = found.where((i) => i.impact >= minImpact).toList();
    // A specific issue on a node replaces the generic "slow step".
    final specific = {
      for (final i in kept)
        if (i.code != PlanIssueCode.dominantNode && i.nodeId != null) i.nodeId,
    };
    kept
      ..removeWhere(
        (i) =>
            i.code == PlanIssueCode.dominantNode && specific.contains(i.nodeId),
      )
      ..sort((a, b) {
        final byScore = b.score.compareTo(a.score);
        if (byScore != 0) return byScore;
        final byImpact = b.impact.compareTo(a.impact);
        if (byImpact != 0) return byImpact;
        return (a.nodeId ?? -1).compareTo(b.nodeId ?? -1);
      });
    return List.unmodifiable(kept.take(max));
  }
}

/// One run of the checks over a plan.
final class _Finder {
  _Finder(this.plan, this.metrics);

  final ExplainPlan plan;
  final PlanMetrics metrics;
  final List<PlanIssue> issues = [];

  /// Execution time the shares are taken of.
  late final double? basis = plan.executionMs ?? metrics[0].inclusiveMs;

  List<PlanIssue> run() {
    if (!plan.analyzed) {
      _disabledNodes();
      return issues;
    }
    final execution = basis;
    final total = execution == null ? null : execution + (plan.planningMs ?? 0);
    if (total != null && total < PlanIssues.fastQueryMs) return issues;
    _slowPlanning();
    if (execution != null && execution < PlanIssues.fastQueryMs) {
      return issues;
    }
    _disabledNodes();
    _jit();
    _triggers();
    if (!plan.timed || execution == null || execution <= 0) return issues;
    for (final node in plan.nodes) {
      final m = metrics[node.id];
      if (m.selfMs == null) continue;
      _dominant(node, m);
      _estimate(node, m);
      _seqScan(node, m);
      _indexFilter(node, m);
      _sortOnDisk(node, m);
      _hashOnDisk(node, m);
      _manyLoops(node);
      _lossyBitmap(node, m);
      _heapFetches(node, m);
      _cache(node, m);
      _workers(node, m);
    }
    return issues;
  }

  void _add(
    PlanIssueCode code,
    int? nodeId,
    double impact,
    double confidence,
    Map<String, Object> facts,
  ) {
    final i = _clamp01(impact);
    issues.add(
      PlanIssue(
        code: code,
        nodeId: nodeId,
        impact: i,
        score: math.min(5, 5 * i * confidence),
        facts: facts,
      ),
    );
  }

  /// Share (0..1) of [basis] that [ms] is.
  double _share(double? ms) {
    final b = basis;
    if (ms == null || b == null || b <= 0) return 0;
    return _clamp01(ms / b);
  }

  Map<String, Object> _time(PlanNode node, double? ms) => {
    'percent': _share(ms) * 100,
    'ms': ?ms,
    'relation': ?_label(node),
  };

  void _dominant(PlanNode node, NodeMetrics m) {
    final pct = m.selfPercent;
    if (pct == null || pct < PlanIssues.dominantPercent) return;
    _add(
      PlanIssueCode.dominantNode,
      node.id,
      pct / 100,
      _confidence(
        pct,
        PlanIssues.dominantPercent,
        PlanIssues.dominantStrongPercent,
      ),
      _time(node, m.selfMs),
    );
  }

  static const _estimateDeciders = {
    'Nested Loop',
    'Hash Join',
    'Merge Join',
    'Sort',
    'Incremental Sort',
    'Aggregate',
    'Group',
  };
  static const _passThrough = {
    'Hash',
    'Materialize',
    'Memoize',
    'Gather',
    'Gather Merge',
  };

  void _estimate(PlanNode node, NodeMetrics m) {
    final factor = m.estimateFactor;
    if (factor == null || factor < PlanIssues.badEstimateFactor) return;
    // Report where the error starts: skip nodes whose child was already
    // off by nearly as much in the same direction.
    for (final child in node.children) {
      final c = metrics[child.id];
      if (c.direction == m.direction &&
          (c.estimateFactor ?? 0) * PlanIssues.badEstimateFactor > factor) {
        return;
      }
    }
    var parentId = node.parentId;
    while (parentId != null &&
        _passThrough.contains(plan.nodes[parentId].nodeType)) {
      parentId = plan.nodes[parentId].parentId;
    }
    if (parentId == null) return;
    final parent = plan.nodes[parentId];
    if (!_estimateDeciders.contains(parent.nodeType)) return;
    final parentMs = metrics[parentId].inclusiveMs;
    final share = _share(parentMs);
    if (share * 100 < PlanIssues.estimateParentPercent) return;
    final actual = node.actual!;
    _add(
      PlanIssueCode.badRowEstimate,
      node.id,
      share,
      _logConfidence(
        factor,
        PlanIssues.badEstimateFactor,
        PlanIssues.strongEstimateFactor,
      ),
      {
        ..._time(node, parentMs),
        'estimated': (node.planRows ?? 0) * actual.loops,
        'actual': actual.rows * actual.loops,
        'factor': factor,
      },
    );
  }

  void _seqScan(PlanNode node, NodeMetrics m) {
    if (node.nodeType != 'Seq Scan') return;
    final removed = _perLoopTotal(node, 'Rows Removed by Filter');
    final kept = m.totalRows ?? 0;
    if (removed == null || removed <= PlanIssues.seqScanRemovedRatio * kept) {
      return;
    }
    final width = node.planWidth;
    if (width != null &&
        (kept + removed) * width <= PlanIssues.seqScanMinPages * 8192) {
      return;
    }
    final fraction = removed / (removed + kept);
    _add(
      PlanIssueCode.indexPotential,
      node.id,
      _share(m.selfMs) * fraction,
      _confidence(fraction, 2 / 3, 0.99),
      {
        ..._time(node, m.selfMs),
        'removed': removed,
        'kept': kept,
        'column': ?simpleFilterColumn(node.properties['Filter']),
      },
    );
  }

  static const _indexScans = {
    'Index Scan',
    'Index Only Scan',
    'Bitmap Heap Scan',
  };

  void _indexFilter(PlanNode node, NodeMetrics m) {
    if (!_indexScans.contains(node.nodeType)) return;
    final removed = _perLoopTotal(node, 'Rows Removed by Filter');
    if (removed == null || removed <= 0) return;
    final kept = m.totalRows ?? 0;
    final pct = removed / (removed + kept) * 100;
    if (pct < PlanIssues.indexRemovedPercent) return;
    _add(
      PlanIssueCode.poorIndexEfficiency,
      node.id,
      _share(m.selfMs) * pct / 100,
      _confidence(
        pct,
        PlanIssues.indexRemovedPercent,
        PlanIssues.indexRemovedStrongPercent,
      ),
      {
        ..._time(node, m.selfMs),
        'percent': pct,
        'removed': removed,
        'kept': kept,
        'column': ?simpleFilterColumn(node.properties['Filter']),
      },
    );
  }

  void _sortOnDisk(PlanNode node, NodeMetrics m) {
    final p = node.properties;
    var disk = _isDiskSort(p);
    var diskKb = _diskSortKb(p);
    final workers = p['Workers'];
    if (workers is List<Object?>) {
      for (final w in workers) {
        if (w is Map<String, Object?> && _isDiskSort(w)) {
          disk = true;
          diskKb += _diskSortKb(w);
        }
      }
    }
    for (final key in const ['Full-sort Groups', 'Pre-sorted Groups']) {
      final group = p[key];
      if (group is! Map<String, Object?>) continue;
      final space = group['Sort Space Disk'];
      final methods = group['Sort Methods Used'];
      if (space != null ||
          (methods is List<Object?> &&
              methods.any((x) => x is String && x.startsWith('external')))) {
        disk = true;
        if (space is Map<String, Object?>) {
          final peak = space['Peak Sort Space Used'];
          if (peak is num) diskKb += peak.toDouble();
        }
      }
    }
    if (!disk) return;
    if (diskKb == 0) diskKb = (m.selfBuffers?.tempWritten ?? 0) * 8.0;
    _add(PlanIssueCode.sortOnDisk, node.id, _share(m.selfMs), 1, {
      ..._time(node, m.selfMs),
      if (diskKb > 0) 'diskKb': diskKb,
      'setting': 'work_mem',
    });
  }

  static bool _isDiskSort(Map<String, Object?> p) {
    final method = p['Sort Method'];
    return p['Sort Space Type'] == 'Disk' ||
        (method is String && method.startsWith('external'));
  }

  static double _diskSortKb(Map<String, Object?> p) {
    final used = p['Sort Space Used'];
    return p['Sort Space Type'] == 'Disk' && used is num ? used.toDouble() : 0;
  }

  static const _sorts = {'Sort', 'Incremental Sort'};

  void _hashOnDisk(PlanNode node, NodeMetrics m) {
    final p = node.properties;
    final temp = (m.selfBuffers?.tempWritten ?? 0) * 8.0;
    if (node.nodeType == 'Hash') {
      final batches = _num(p['Hash Batches']);
      if (batches == null || batches <= 1) return;
      var ms = m.selfMs ?? 0;
      var diskKb = temp;
      final parentId = node.parentId;
      if (parentId != null) {
        final parent = plan.nodes[parentId];
        if (parent.nodeType.endsWith('Join')) {
          ms += metrics[parentId].selfMs ?? 0;
          diskKb += (metrics[parentId].selfBuffers?.tempWritten ?? 0) * 8.0;
        }
      }
      _addHash(node, ms, batches, diskKb);
      return;
    }
    if (_sorts.contains(node.nodeType)) return;
    final aggBatches = _num(p['HashAgg Batches']);
    final diskUsage = _num(p['Disk Usage']);
    if ((aggBatches != null && aggBatches > 1) ||
        (diskUsage != null && diskUsage > 0)) {
      _addHash(node, m.selfMs ?? 0, aggBatches, diskUsage ?? temp);
      return;
    }
    // Pre-order: a Hash Join comes before its Hash child, so skip joins
    // whose Hash child will be reported with them.
    if (node.nodeType.endsWith('Join') &&
        node.children.any(
          (c) =>
              c.nodeType == 'Hash' &&
              (_num(c.properties['Hash Batches']) ?? 0) > 1,
        )) {
      return;
    }
    if (temp > 0) _addHash(node, m.selfMs ?? 0, null, temp);
  }

  void _addHash(PlanNode node, double ms, double? batches, double diskKb) {
    _add(PlanIssueCode.hashOnDisk, node.id, _share(ms), 1, {
      ..._time(node, ms),
      'batches': ?batches,
      if (diskKb > 0) 'diskKb': diskKb,
      'setting': 'work_mem',
    });
  }

  void _manyLoops(PlanNode node) {
    if (node.nodeType != 'Nested Loop') return;
    final sides = [
      for (final c in node.children)
        if (c.relationship != 'InitPlan' && c.relationship != 'SubPlan') c,
    ];
    if (sides.length < 2) return;
    final inner = sides.firstWhere(
      (c) => c.relationship == 'Inner',
      orElse: () => sides[1],
    );
    final outer = sides.firstWhere((c) => c != inner);
    final loops = inner.actual?.loops ?? 0;
    if (loops < PlanIssues.manyLoopsMin) return;
    final innerMs = metrics[inner.id].inclusiveMs;
    final share = _share(innerMs);
    if (share * 100 < PlanIssues.manyLoopsPercent) return;
    final o = metrics[outer.id];
    final outerActual = outer.actual;
    _add(
      PlanIssueCode.manyLoops,
      node.id,
      share,
      _logConfidence(
        loops.toDouble(),
        PlanIssues.manyLoopsMin.toDouble(),
        PlanIssues.manyLoopsStrong.toDouble(),
      ),
      {
        'percent': share * 100,
        'ms': ?innerMs,
        'loops': loops,
        'relation': ?_label(inner),
        if ((o.estimateFactor ?? 0) >= PlanIssues.badEstimateFactor &&
            outerActual != null) ...{
          'estimated': (outer.planRows ?? 0) * outerActual.loops,
          'actual': outerActual.rows * outerActual.loops,
          'factor': o.estimateFactor!,
        },
      },
    );
  }

  void _lossyBitmap(PlanNode node, NodeMetrics m) {
    final lossy = _num(node.properties['Lossy Heap Blocks']);
    final removed = _perLoopTotal(node, 'Rows Removed by Index Recheck');
    if (lossy == null || lossy <= 0 || removed == null || removed <= 0) {
      return;
    }
    final kept = m.totalRows ?? 0;
    _add(
      PlanIssueCode.lossyBitmap,
      node.id,
      _share(m.selfMs) * removed / (removed + kept),
      1,
      {..._time(node, m.selfMs), 'removed': removed, 'setting': 'work_mem'},
    );
  }

  void _heapFetches(PlanNode node, NodeMetrics m) {
    if (node.nodeType != 'Index Only Scan') return;
    // `Heap Fetches` is a total; rows and removed rows are per loop.
    final fetches = _num(node.properties['Heap Fetches']);
    if (fetches == null || fetches <= 0) return;
    final rows =
        (m.totalRows ?? 0) +
        (_perLoopTotal(node, 'Rows Removed by Filter') ?? 0);
    if (rows <= 0) return;
    final pct = math.min(100, fetches / rows * 100).toDouble();
    if (pct <= PlanIssues.heapFetchPercent) return;
    _add(
      PlanIssueCode.excessiveHeapFetches,
      node.id,
      _share(m.selfMs) * pct / 100,
      _confidence(
        pct,
        PlanIssues.heapFetchPercent,
        PlanIssues.heapFetchStrongPercent,
      ),
      {..._time(node, m.selfMs), 'percent': pct},
    );
  }

  void _cache(PlanNode node, NodeMetrics m) {
    final b = m.selfBuffers;
    if (b == null) return;
    final blocks = b.sharedHit + b.sharedRead;
    if (blocks < PlanIssues.cacheMinBlocks) return;
    final readPct = b.sharedRead / blocks * 100;
    final perRow = blocks / math.max(1, m.totalRows ?? 0);
    var fraction = 0.0;
    if (b.sharedRead >= PlanIssues.cacheMinBlocks &&
        readPct > PlanIssues.cacheReadPercent) {
      fraction = readPct / 100;
    }
    if (perRow > PlanIssues.cacheBlocksPerRow) {
      fraction = math.max(fraction, 1 - PlanIssues.cacheBlocksPerRow / perRow);
    }
    if (fraction == 0) return;
    _add(
      PlanIssueCode.poorCachePerformance,
      node.id,
      _share(m.selfMs) * fraction,
      0.75,
      {
        ..._time(node, m.selfMs),
        'percent': readPct,
        'readMb': b.sharedRead * 8 / 1024,
      },
    );
  }

  void _workers(PlanNode node, NodeMetrics m) {
    final planned = node.workersPlanned;
    final launched = node.workersLaunched;
    if (planned == null || launched == null || launched >= planned) return;
    final saved = 1 - (launched + 1) / (planned + 1);
    _add(
      PlanIssueCode.workersMissing,
      node.id,
      _share(m.inclusiveMs) * saved,
      1,
      {
        ..._time(node, m.inclusiveMs),
        'planned': planned,
        'launched': launched,
        'setting': 'max_parallel_workers',
      },
    );
  }

  void _jit() {
    final jitMs = plan.jit?.totalMs;
    final execution = basis;
    if (jitMs == null || execution == null || execution <= 0) return;
    final pct = jitMs / execution * 100;
    if (jitMs < PlanIssues.jitMinMs || pct < PlanIssues.jitPercent) return;
    _add(
      PlanIssueCode.jitOverhead,
      null,
      pct / 100,
      _confidence(pct, PlanIssues.jitPercent, 50),
      {
        'percent': math.min(100, pct),
        'jitMs': jitMs,
        'executionMs': execution,
        'setting': 'jit',
      },
    );
  }

  void _slowPlanning() {
    final planning = plan.planningMs;
    final execution = basis;
    if (planning == null || execution == null) return;
    final total = planning + execution;
    if (total <= 0) return;
    final pct = planning / total * 100;
    if (planning < PlanIssues.planningMinMs ||
        pct < PlanIssues.planningPercent) {
      return;
    }
    _add(
      PlanIssueCode.slowPlanning,
      null,
      pct / 100,
      _confidence(pct, PlanIssues.planningPercent, 50),
      {'percent': pct, 'planningMs': planning, 'executionMs': execution},
    );
  }

  void _triggers() {
    final execution = basis;
    if (plan.triggers.isEmpty || execution == null || execution <= 0) return;
    final ms = metrics.triggerMs;
    final pct = ms / execution * 100;
    if (pct < PlanIssues.triggerPercent) return;
    final slowest = plan.triggers.reduce(
      (a, b) => (b.timeMs ?? 0) > (a.timeMs ?? 0) ? b : a,
    );
    _add(
      PlanIssueCode.triggerTime,
      null,
      pct / 100,
      _confidence(pct, PlanIssues.triggerPercent, 50),
      {
        'percent': math.min(100, pct),
        'ms': ms,
        'triggerName': slowest.name.isEmpty
            ? (slowest.constraintName ?? '')
            : slowest.name,
        'relation': ?slowest.relation,
      },
    );
  }

  static const _enableSettings = {
    'Seq Scan': 'enable_seqscan',
    'Index Scan': 'enable_indexscan',
    'Index Only Scan': 'enable_indexonlyscan',
    'Bitmap Heap Scan': 'enable_bitmapscan',
    'Bitmap Index Scan': 'enable_bitmapscan',
    'Tid Scan': 'enable_tidscan',
    'Tid Range Scan': 'enable_tidscan',
    'Sort': 'enable_sort',
    'Incremental Sort': 'enable_incremental_sort',
    'Nested Loop': 'enable_nestloop',
    'Merge Join': 'enable_mergejoin',
    'Hash Join': 'enable_hashjoin',
    'Materialize': 'enable_material',
    'Memoize': 'enable_memoize',
    'Gather Merge': 'enable_gathermerge',
  };

  void _disabledNodes() {
    for (final node in plan.nodes) {
      if (!node.disabled) continue;
      final m = metrics[node.id];
      double share;
      double? ms;
      if (plan.timed && m.inclusiveMs != null) {
        ms = m.inclusiveMs;
        share = _share(ms);
      } else {
        final rootCost = _realCost(plan.root.totalCost);
        final cost = _realCost(node.totalCost);
        share = rootCost == null || cost == null || rootCost <= 0
            ? 0
            : _clamp01(cost / rootCost);
      }
      _add(PlanIssueCode.disabledNode, node.id, share, 1, {
        'percent': share * 100,
        'ms': ?ms,
        'relation': ?_label(node),
        'setting': ?_disablingSetting(node),
      });
    }
  }

  String? _disablingSetting(PlanNode node) {
    bool isOff(String? v) =>
        v != null &&
        const {'off', 'false', '0', 'no'}.contains(v.toLowerCase());
    final specific = node.nodeType == 'Aggregate' && node.strategy == 'Hashed'
        ? 'enable_hashagg'
        : node.parallelAware && node.nodeType == 'Append'
        ? 'enable_parallel_append'
        : node.parallelAware && node.nodeType == 'Hash'
        ? 'enable_parallel_hash'
        : _enableSettings[node.nodeType];
    if (specific != null && isOff(plan.settings[specific])) return specific;
    for (final e in plan.settings.entries) {
      if (e.key.startsWith('enable_') && isOff(e.value)) return e.key;
    }
    return null;
  }

  static double? _realCost(double? cost) => cost == null
      ? null
      : cost >= PlanNode.disabledCost
      ? cost % PlanNode.disabledCost
      : cost;

  /// The table the node reads or writes, for wording.
  static String? _label(PlanNode node) => node.relation;

  /// A per-loop counter of [node] times its loops.
  static double? _perLoopTotal(PlanNode node, String key) {
    final v = _num(node.properties[key]);
    if (v == null) return null;
    return v * (node.actual?.loops ?? 1);
  }

  static double? _num(Object? v) => v is num ? v.toDouble() : null;

  static double _clamp01(double v) => v.isNaN ? 0 : math.min(1, math.max(0, v));

  /// 0.5 at [threshold], rising linearly to 1 at [strong].
  static double _confidence(double value, double threshold, double strong) =>
      0.5 + 0.5 * _clamp01((value - threshold) / (strong - threshold));

  /// Like [_confidence] on a log scale.
  static double _logConfidence(double value, double threshold, double strong) =>
      _confidence(
        math.log(math.max(value, 1)),
        math.log(threshold),
        math.log(strong),
      );
}

const _identifier = r'(?:"(?:[^"]|"")+"|[A-Za-z_][A-Za-z0-9_$]*)';
final _simpleFilter = RegExp(
  '^\\(?($_identifier(?:\\.$_identifier)?)\\)?(?:::[A-Za-z_][A-Za-z0-9_ ]*)?'
  r' (=|<>|!=|<|<=|>|>=|~~|!~~|~~\*|!~~\*) '
  r"((?:'(?:[^']|'')*'|-?[0-9]+(?:\.[0-9]+)?|true|false|\$[0-9]+)"
  r'(?:::[A-Za-z_][A-Za-z0-9_ ]*(?:\[\])?)?)$',
);

/// The column of a `Filter` that is a single `column op constant`
/// comparison, such as `(status = 'shipped'::text)` or
/// `((o.status)::text = 'x'::text)`, without table qualifier or quotes.
/// `null` for anything else (two columns, `AND`/`OR`, functions...).
String? simpleFilterColumn(Object? filter) {
  if (filter is! String) return null;
  var s = filter.trim();
  if (s.startsWith('(') && s.endsWith(')')) {
    s = s.substring(1, s.length - 1);
  }
  final match = _simpleFilter.firstMatch(s);
  if (match == null) return null;
  final qualified = match.group(1)!;
  final parts = RegExp(_identifier).allMatches(qualified).toList();
  final column = parts.last.group(0)!;
  return column.startsWith('"')
      ? column.substring(1, column.length - 1).replaceAll('""', '"')
      : column;
}
