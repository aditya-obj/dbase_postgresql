// File: explain_json.dart
// Purpose: Helpers for EXPLAIN tests: load the JSON fixtures (which start
// with `//` provenance comments) and build small plans in code.

import 'dart:convert';
import 'dart:io';

/// The JSON text of `test/explain/fixtures/<name>.json`, without its
/// leading `//` header lines.
String explainFixture(String name) {
  final lines = File('test/explain/fixtures/$name.json').readAsLinesSync();
  return lines.skipWhile((l) => l.startsWith('//')).join('\n');
}

/// A plan node map. [ms] is the per-loop `Actual Total Time`; [rows] the
/// per-loop `Actual Rows`. Leave [loops] null for a plan-only node.
Map<String, Object?> pnode(
  String type, {
  double? cost,
  double? planRows,
  int width = 8,
  double? ms,
  double? rows,
  int? loops,
  String? relationship,
  Map<String, Object?> extra = const {},
  List<Map<String, Object?>> plans = const [],
}) => {
  'Node Type': type,
  'Parent Relationship': ?relationship,
  'Parallel Aware': false,
  if (cost != null) ...{
    'Startup Cost': 0.0,
    'Total Cost': cost,
    'Plan Rows': planRows ?? 1,
    'Plan Width': width,
  },
  if (loops != null) ...{
    'Actual Startup Time': ?(ms == null ? null : 0.0),
    'Actual Total Time': ?ms,
    'Actual Rows': rows ?? 0,
    'Actual Loops': loops,
  },
  ...extra,
  if (plans.isNotEmpty) 'Plans': plans,
};

/// One plan array around [root], as `EXPLAIN (FORMAT JSON)` prints it.
String planJson(
  Map<String, Object?> root, {
  double? planningMs,
  double? executionMs,
  List<Map<String, Object?>>? triggers,
  Map<String, Object?>? jit,
  Map<String, String>? settings,
}) => jsonEncode([
  {
    'Plan': root,
    'Settings': ?settings,
    'Planning Time': ?planningMs,
    'Triggers': ?triggers,
    'JIT': ?jit,
    'Execution Time': ?executionMs,
  },
]);
