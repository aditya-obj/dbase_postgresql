// File: pev2_metrics_test.dart
// Purpose: PEV2's PlanService tests for exclusive time (loops, CTEs,
// InitPlans, parallel workers) and parsing, run against ExplainPlan and
// PlanMetrics.
//
// Ported from PEV2 src/services/__tests__/*.spec.ts
// (https://github.com/dalibo/pev2, commit 3cca315) - Copyright (c) 2019,
// Dalibo, PostgreSQL-style license. See THIRD_PARTY_NOTICES. The text
// plans were converted to the FORMAT JSON shape (test/explain/fixtures/).
// PEV2 numbers nodes from 1; ours start at 0.

import 'package:dabase_postgresql/explain.dart';
import 'package:test/test.dart';

import '../support/explain_json.dart';

(ExplainPlan, PlanMetrics) _load(String fixture) {
  final plan = ExplainPlan.parse(explainFixture(fixture));
  return (plan, PlanMetrics.compute(plan));
}

void main() {
  test('02-actual-duration-loops: durations multiply by loops', () {
    final (plan, m) = _load('02-actual-duration-loops');
    final root = plan.root;
    // Materialize: total time × loops − Seq Scan duration.
    const mDuration = 0.008 * 402 - 0.015;
    expect(m[root.children[1].id].selfMs, closeTo(mDuration, 1e-9));
    // Nested Loop: total − (Materialize + its Seq Scan) − outer Seq Scan.
    const nlDuration = 10.198 - (mDuration + 0.015) - 0.058;
    expect(m[root.id].selfMs, closeTo(nlDuration, 1e-9));
  });

  test("03-actual-duration-cte: the CTE's time is not in the root", () {
    final (plan, m) = _load('03-actual-duration-cte');
    expect(m[plan.root.id].selfMs! - 0.002 < 0, isTrue);
  });

  test('04-actual-duration-parallel: loops are divided by workers', () {
    final (plan, m) = _load('04-actual-duration-parallel');
    final sort = plan.root.children[0];
    expect(m[sort.children[0].id].selfMs, closeTo(400.681, 1e-9));
    expect(m[sort.id].selfMs, closeTo(2020.558 - 400.681, 1e-9));
  });

  test('05-parallel-children-loops: workers apply to every descendant', () {
    final (plan, m) = _load('05-parallel-children-loops');
    final bitmapIndexScan = plan.nodes[11]; // PEV2 node #12
    expect(bitmapIndexScan.nodeType, 'Bitmap Index Scan');
    expect(m[11].participants, 4);
    expect(m[11].selfMs, closeTo(285217.30275, 1e-6));
  });

  test('05-parallel-gather-children: Partial GroupAggregate under Gather', () {
    final (plan, m) = _load('05-parallel-gather-children');
    final aggregate = plan.root.children[0].children[0].children[0];
    expect(aggregate.displayName, 'Partial GroupAggregate');
    expect(1.79 - m[aggregate.id].selfMs! < 0.01, isTrue);
  });

  test('05-parallel-launched-workers: only launched workers count', () {
    final (plan, m) = _load('05-parallel-launched-workers');
    final functionScan = plan.nodes[5]; // PEV2 node #6
    expect(functionScan.nodeType, 'Function Scan');
    expect(m[5].participants, 8);
    expect(m[5].selfMs, closeTo(1050, 1e-9));
  });

  test('05-parallel-pg12: Partial Aggregate under Gather (ANALYZE)', () {
    final (plan, m) = _load('05-parallel-pg12-analyze-bitmap');
    final partial = plan.root.children[0].children[0];
    expect(partial.nodeType, 'Aggregate');
    expect(partial.partialMode, 'Partial');
    expect(m[partial.id].participants, 5);
    final bitmapIndexScan = partial.children[0].children[0];
    expect(bitmapIndexScan.nodeType, 'Bitmap Index Scan');
  });

  test('05-parallel-child-without-worker: workers stay on their node', () {
    final (plan, _) = _load('05-parallel-child-without-worker');
    final gather = plan.root.children[0].children[1];
    final bitmapIndexScan = gather.children[0].children[0];
    expect(bitmapIndexScan.nodeType, 'Bitmap Index Scan');
    expect(bitmapIndexScan.properties['Workers'], isNull);
    expect(gather.children[0].properties['Workers'], hasLength(4));
  });

  test('07-bis-no-analyze-workers: plan-only parallel plan', () {
    // PEV2 checks its internal "Workers Planned By Gather"; without
    // ANALYZE we keep one participant and no times.
    final (plan, m) = _load('07-bis-no-analyze-workers');
    final aggregate = plan.root.children[0].children[0];
    expect(aggregate.displayName, 'Partial Aggregate');
    expect(plan.root.children[0].workersPlanned, 12);
    expect(plan.analyzed, isFalse);
    expect(m[aggregate.id].participants, 1);
    expect(m[aggregate.id].selfMs, isNull);
  });

  test('18-fractional-rows: PostgreSQL 18 fractional rows', () {
    final (plan, m) = _load('18-fractional-rows');
    final seqScan = plan.root.children[1].children[0];
    expect(seqScan.nodeType, 'Seq Scan');
    expect(seqScan.actual!.rows, 0.25);
    expect(m[seqScan.id].totalRows, 1);
    expect(plan.hasBuffers, isTrue);
  });

  test('20-insert-modifytable: ModifyTable shows its operation', () {
    final (plan, _) = _load('20-insert-modifytable');
    expect(plan.root.nodeType, 'ModifyTable');
    expect(plan.root.displayName, 'Insert');
    expect(plan.triggers, hasLength(2));
    expect(plan.triggers.first.name, 'foo_system_time_generated_always');
    expect(plan.triggers.first.relation, 'foo');
  });

  test('22-triggers: constraint triggers are parsed', () {
    final (plan, m) = _load('22-triggers-fk');
    expect(plan.triggers, hasLength(7));
    expect(plan.triggers[2].constraintName, 'attachemessageref');
    expect(m.triggerMs, closeTo(163900.503, 1e-6));
  });

  test('15-subquery-scan: Subquery Scan alias', () {
    final (plan, _) = _load('15-subquery-scan');
    expect(plan.root.nodeType, 'Subquery Scan');
    expect(plan.root.alias, 'foo');
    expect(plan.root.target, 'foo');
  });

  group('cte-exclusive-time: sum of self times equals the root time', () {
    for (final name in ['01', '02', '03', '04', '05']) {
      test(name, () {
        final (plan, m) = _load('cte-exclusive-time-$name');
        final rootMs = plan.root.actual!.totalMs!;
        final sum = m.nodes.fold<double>(0, (s, n) => s + n.selfMs!);
        expect(sum, greaterThan(rootMs * 0.99));
        expect(sum, lessThan(rootMs * 1.01));
      });
    }
  });

  test('cte-exclusive-time 05: InitPlan time leaves its user', () {
    final (plan, m) = _load('cte-exclusive-time-05');
    final indexScan = plan.root.children[1];
    expect(indexScan.properties['Index Cond'], r'(id = ANY ($1))');
    expect(m[indexScan.id].selfMs, closeTo(1931.146 - 1736.419, 1e-9));
    // The Result above InitPlan 1 already subtracted it as a child.
    final result = plan.root.children[0];
    expect(m[result.id].selfMs, closeTo(1736.419 - 1727.318, 1e-9));
  });

  test('17-cost-0.00: exclusive cost of a zero-cost node', () {
    final plan = ExplainPlan.parse(
      planJson(pnode('Seq Scan', cost: 0, planRows: 1)),
    );
    expect(PlanMetrics.compute(plan)[0].selfCost, 0);
  });

  test('07-no-analyze: cost without timing', () {
    final plan = ExplainPlan.parse(
      planJson(pnode('Seq Scan', cost: 29.68, planRows: 568)),
    );
    final m = PlanMetrics.compute(plan);
    expect(m[0].selfMs, isNull);
    expect(m[0].selfCost, 29.68);
  });

  test('08-plan-without-cost: timing without cost', () {
    final plan = ExplainPlan.parse(
      planJson(pnode('Seq Scan', ms: 0.181, rows: 645, loops: 1)),
    );
    final m = PlanMetrics.compute(plan);
    expect(m[0].selfMs, 0.181);
    expect(m[0].selfCost, isNull);
  });

  test('plan-service: never executed node time is 0', () {
    final plan = ExplainPlan.parse(
      planJson(pnode('Hash', cost: 6.12, ms: 0, loops: 0)),
    );
    expect(plan.root.actual!.neverExecuted, isTrue);
    expect(PlanMetrics.compute(plan)[0].inclusiveMs, 0);
  });

  test('plan-service: planned rows', () {
    final plan = ExplainPlan.parse(
      planJson(pnode('Seq Scan', cost: 18334, planRows: 1000000)),
    );
    expect(plan.root.planRows, 1000000);
  });

  test('25-enable-parameter: Disabled is read as a boolean', () {
    final plan = ExplainPlan.parse(
      planJson(
        pnode(
          'Seq Scan',
          cost: 21370,
          extra: {'Disabled': true, 'Filter': '((c1 + 0) < 1000000)'},
        ),
        settings: {'enable_seqscan': 'off'},
      ),
    );
    expect(plan.root.disabled, isTrue);
    expect(plan.settings, {'enable_seqscan': 'off'});
  });

  test('24-parallel-aware: Parallel Aware', () {
    final plan = ExplainPlan.parse(
      planJson(pnode('Seq Scan', cost: 333, extra: {'Parallel Aware': true})),
    );
    expect(plan.root.parallelAware, isTrue);
    expect(plan.root.displayName, 'Parallel Seq Scan');
  });
}
