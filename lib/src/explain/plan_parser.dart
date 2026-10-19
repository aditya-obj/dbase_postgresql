// File: plan_parser.dart
// Purpose: Decodes `EXPLAIN (FORMAT JSON)` text into ExplainPlan /
// PlanNode, validating the structure and the types of known keys.

import 'dart:convert';

import 'package:dabase_postgresql/src/explain/explain_plan.dart';

/// Parses [json] into one [ExplainPlan] per array element. See
/// [ExplainPlan.parseAll].
List<ExplainPlan> parseExplainJson(String json) {
  final Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException catch (e) {
    // FormatException.toString() quotes the source; keep only the offset.
    throw FormatException(
      'EXPLAIN output is not valid JSON'
      '${e.offset == null ? '' : ' (at offset ${e.offset})'}',
    );
  }
  final List<Object?> elements;
  if (decoded is List<Object?>) {
    elements = decoded;
  } else if (decoded is Map<String, Object?>) {
    elements = [decoded];
  } else {
    throw const FormatException(
      'EXPLAIN JSON must be an array of plan objects',
    );
  }
  if (elements.isEmpty) {
    throw const FormatException('EXPLAIN JSON contains no plan');
  }
  return List.unmodifiable([
    for (var i = 0; i < elements.length; i++) _parsePlan(elements[i], i),
  ]);
}

ExplainPlan _parsePlan(Object? element, int index) {
  if (element is! Map<String, Object?>) {
    throw FormatException('Plan $index is not a JSON object');
  }
  final rootJson = element['Plan'];
  if (rootJson is! Map<String, Object?>) {
    throw FormatException('Plan $index has no "Plan" object');
  }
  final scan = _Scan();
  final root = _parseNode(rootJson, scan, depth: 0, parentId: null);
  final planning = element['Planning'];
  if (planning is Map<String, Object?> && _hasBufferKey(planning)) {
    scan.hasBuffers = true;
  }
  final triggers = element['Triggers'];
  if (triggers != null && triggers is! List<Object?>) {
    throw const FormatException('"Triggers" must be an array');
  }
  final settings = element['Settings'];
  if (settings != null && settings is! Map<String, Object?>) {
    throw const FormatException('"Settings" must be an object');
  }
  final queryId = element['Query Identifier'];
  if (queryId != null && queryId is! num && queryId is! String) {
    throw const FormatException('"Query Identifier" must be a number');
  }
  return ExplainPlan(
    root: root,
    planningMs: _double(element, 'Planning Time'),
    executionMs: _double(element, 'Execution Time'),
    triggers: [
      for (final t in (triggers as List<Object?>?) ?? const <Object?>[])
        _parseTrigger(t),
    ],
    jit: _parseJit(element['JIT']),
    settings: {
      for (final e in ((settings as Map<String, Object?>?) ?? const {}).entries)
        e.key: '${e.value}',
    },
    queryIdentifier: switch (queryId) {
      final int v => '$v',
      // On the web every JSON number is a double; print it without `.0`.
      final double v when v == v.truncateToDouble() => v.toStringAsFixed(0),
      final Object v => '$v',
      null => null,
    },
    analyzed: scan.analyzed,
    timed: scan.timed,
    hasBuffers: scan.hasBuffers,
    properties: {
      for (final e in element.entries)
        if (e.key != 'Plan') e.key: e.value,
    },
  );
}

/// Flags and the id counter collected while walking the tree.
final class _Scan {
  int nextId = 0;
  bool analyzed = false;
  bool timed = false;
  bool hasBuffers = false;
}

const _bufferKeys = {
  'Shared Hit Blocks': 0,
  'Shared Read Blocks': 1,
  'Shared Dirtied Blocks': 2,
  'Shared Written Blocks': 3,
  'Local Hit Blocks': 4,
  'Local Read Blocks': 5,
  'Local Dirtied Blocks': 6,
  'Local Written Blocks': 7,
  'Temp Read Blocks': 8,
  'Temp Written Blocks': 9,
};

bool _hasBufferKey(Map<String, Object?> map) =>
    _bufferKeys.keys.any(map.containsKey);

PlanNode _parseNode(
  Map<String, Object?> json,
  _Scan scan, {
  required int depth,
  required int? parentId,
}) {
  final nodeType = json['Node Type'];
  if (nodeType is! String || nodeType.isEmpty) {
    throw const FormatException('Plan node without a "Node Type"');
  }
  final id = scan.nextId++;

  final loops = _double(json, 'Actual Loops');
  final totalMs = _double(json, 'Actual Total Time');
  NodeActuals? actual;
  if (loops != null) {
    scan.analyzed = true;
    if (totalMs != null) scan.timed = true;
    actual = NodeActuals(
      startupMs: _double(json, 'Actual Startup Time'),
      totalMs: totalMs,
      rows: _double(json, 'Actual Rows') ?? 0,
      loops: loops.round(),
    );
  }

  BufferCounts? buffers;
  if (_hasBufferKey(json)) {
    scan.hasBuffers = true;
    int b(String key) => _double(json, key)?.round() ?? 0;
    buffers = BufferCounts(
      sharedHit: b('Shared Hit Blocks'),
      sharedRead: b('Shared Read Blocks'),
      sharedDirtied: b('Shared Dirtied Blocks'),
      sharedWritten: b('Shared Written Blocks'),
      localHit: b('Local Hit Blocks'),
      localRead: b('Local Read Blocks'),
      localDirtied: b('Local Dirtied Blocks'),
      localWritten: b('Local Written Blocks'),
      tempRead: b('Temp Read Blocks'),
      tempWritten: b('Temp Written Blocks'),
    );
  }

  final plans = json['Plans'];
  if (plans != null && plans is! List<Object?>) {
    throw const FormatException('"Plans" must be an array');
  }
  final children = <PlanNode>[
    for (final child in (plans as List<Object?>?) ?? const <Object?>[])
      if (child is Map<String, Object?>)
        _parseNode(child, scan, depth: depth + 1, parentId: id)
      else
        throw const FormatException('"Plans" must contain objects'),
  ];

  final totalCost = _double(json, 'Total Cost');
  final disabledKey = _bool(json, 'Disabled');
  final bool disabled;
  if (disabledKey != null) {
    disabled = disabledKey;
  } else {
    // PostgreSQL 17 and older: disable_cost is added to the node's cost
    // and inherited by every ancestor, so mark only the lowest node.
    disabled =
        totalCost != null &&
        totalCost >= PlanNode.disabledCost &&
        children.every((c) => (c.totalCost ?? 0) < PlanNode.disabledCost);
  }

  return PlanNode(
    id: id,
    depth: depth,
    parentId: parentId,
    nodeType: nodeType,
    relationship: _string(json, 'Parent Relationship'),
    subplanName: _string(json, 'Subplan Name'),
    relation: _string(json, 'Relation Name'),
    schema: _string(json, 'Schema'),
    alias: _string(json, 'Alias'),
    index: _string(json, 'Index Name'),
    cte: _string(json, 'CTE Name'),
    function: _string(json, 'Function Name'),
    joinType: _string(json, 'Join Type'),
    strategy: _string(json, 'Strategy'),
    operation: _string(json, 'Operation'),
    partialMode: _string(json, 'Partial Mode'),
    scanDirection: _string(json, 'Scan Direction'),
    parallelAware: _bool(json, 'Parallel Aware') ?? false,
    asyncCapable: _bool(json, 'Async Capable') ?? false,
    disabled: disabled,
    startupCost: _double(json, 'Startup Cost'),
    totalCost: totalCost,
    planRows: _double(json, 'Plan Rows'),
    planWidth: _double(json, 'Plan Width')?.round(),
    actual: actual,
    workersPlanned: _double(json, 'Workers Planned')?.round(),
    workersLaunched: _double(json, 'Workers Launched')?.round(),
    buffers: buffers,
    properties: {
      for (final e in json.entries)
        if (e.key != 'Plans') e.key: e.value,
    },
    children: children,
  );
}

TriggerTiming _parseTrigger(Object? json) {
  if (json is! Map<String, Object?>) {
    throw const FormatException('"Triggers" must contain objects');
  }
  return TriggerTiming(
    name: _string(json, 'Trigger Name') ?? '',
    constraintName: _string(json, 'Constraint Name'),
    relation: _string(json, 'Relation'),
    timeMs: _double(json, 'Time'),
    calls: _double(json, 'Calls')?.round() ?? 0,
  );
}

JitSummary? _parseJit(Object? json) {
  if (json == null) return null;
  if (json is! Map<String, Object?>) {
    throw const FormatException('"JIT" must be an object');
  }
  final timing = json['Timing'];
  if (timing != null && timing is! Map<String, Object?>) {
    throw const FormatException('"JIT"."Timing" must be an object');
  }
  return JitSummary(
    functions: _double(json, 'Functions')?.round() ?? 0,
    totalMs: timing == null
        ? null
        : _double(timing as Map<String, Object?>, 'Total'),
  );
}

/// [key] as a double: PostgreSQL 18 prints `1000.00` where 17 printed
/// `1000`, and both decode to `num`.
double? _double(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is num) return value.toDouble();
  throw FormatException('"$key" must be a number');
}

bool? _bool(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is bool) return value;
  throw FormatException('"$key" must be true or false');
}

String? _string(Map<String, Object?> json, String key) {
  final value = json[key];
  if (value == null) return null;
  if (value is String) return value;
  throw FormatException('"$key" must be text');
}
