// File: explain.dart
// Purpose: Narrow entrypoint for EXPLAIN (FORMAT JSON) parsing, per-node
// metrics, issue detection and option building.

/// Parse `EXPLAIN (FORMAT JSON)` output, compute self time and cost per
/// node, find the issues worth fixing, and build version-safe `EXPLAIN`
/// options. Pure Dart; no server needed.
library;

export 'src/explain/explain_options.dart' show ExplainOptions;
export 'src/explain/explain_plan.dart'
    show
        BufferCounts,
        ExplainPlan,
        JitSummary,
        NodeActuals,
        PlanNode,
        TriggerTiming;
export 'src/explain/plan_issues.dart'
    show PlanIssue, PlanIssueCode, PlanIssues, simpleFilterColumn;
export 'src/explain/plan_metrics.dart'
    show EstimateDirection, NodeMetrics, PlanMetrics;
