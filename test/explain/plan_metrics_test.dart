// File: plan_metrics_test.dart
// Purpose: Unit tests for PlanMetrics beyond the PEV2 corpus: participants,
// InitPlan naming on PostgreSQL 17+, self cost, estimate factors, row
// totals, self buffers, trigger and "other" time.

import 'package:dabase_postgresql/explain.dart';
import 'package:test/test.dart';

import '../support/explain_json.dart';

PlanMetrics _metrics(String json) =>
    PlanMetrics.compute(ExplainPlan.parse(json));

void main() {
  test('participants: Gather children, but not InitPlans or SubPlans', () {
    final m = _metrics(
      planJson(
        pnode(
          'Gather',
          ms: 10,
          loops: 1,
          extra: {'Workers Planned': 2, 'Workers Launched': 1},
          plans: [
            pnode(
              'Seq Scan',
              relationship: 'InitPlan',
              ms: 1,
              loops: 1,
              extra: {'Subplan Name': 'InitPlan 1'},
            ),
            pnode(
              'Seq Scan',
              relationship: 'Outer',
              ms: 4,
              loops: 2,
              plans: [
                pnode(
                  'Result',
                  relationship: 'SubPlan',
                  ms: 0.1,
                  loops: 2,
                  extra: {'Subplan Name': 'SubPlan 2'},
                ),
              ],
            ),
          ],
        ),
      ),
    );
    expect(m.nodes.map((n) => n.participants), [1, 1, 2, 2]);
    expect(m[2].inclusiveMs, 4); // 4 ms × 2 loops ÷ 2 participants
  });

  test('participants: Workers Launched 0 means the leader alone', () {
    final m = _metrics(
      planJson(
        pnode(
          'Gather',
          ms: 10,
          loops: 1,
          extra: {'Workers Planned': 2, 'Workers Launched': 0},
          plans: [pnode('Seq Scan', relationship: 'Outer', ms: 9, loops: 1)],
        ),
      ),
    );
    expect(m[1].participants, 1);
    expect(m[1].inclusiveMs, 9);
  });

  group('InitPlan fix', () {
    String plan(String name, String filter) => planJson(
      pnode(
        'Seq Scan',
        ms: 10,
        loops: 1,
        extra: {'Filter': filter},
        plans: [
          pnode(
            'Index Scan',
            relationship: 'InitPlan',
            ms: 6,
            loops: 1,
            extra: {'Subplan Name': name},
          ),
        ],
      ),
    );

    test(r'PostgreSQL 16: InitPlan 1 (returns $0) used as $0', () {
      final m = _metrics(plan(r'InitPlan 1 (returns $0)', r'(x = $0)'));
      expect(m[0].selfMs, 4);
    });

    test('PostgreSQL 17: used as (InitPlan 1).col1', () {
      final m = _metrics(plan('InitPlan 1', '(x = (InitPlan 1).col1)'));
      expect(m[0].selfMs, 4);
    });

    test(r'$1 does not match $10, InitPlan 1 not InitPlan 12', () {
      expect(
        _metrics(plan(r'InitPlan 2 (returns $1)', r'(x = $10)'))[0].selfMs,
        10,
      );
      expect(
        _metrics(plan('InitPlan 1', '(x = (InitPlan 12).col1)'))[0].selfMs,
        10,
      );
    });

    test(r'several returned params: (returns $0,$1)', () {
      final m = _metrics(plan(r'InitPlan 1 (returns $0,$1)', r'(y = $1)'));
      expect(m[0].selfMs, 4);
    });

    test('a node that does not use it keeps its time', () {
      expect(_metrics(plan('InitPlan 1', '(x = 1)'))[0].selfMs, 10);
    });

    test('results are clamped at 0', () {
      final m = _metrics(
        planJson(
          pnode(
            'Seq Scan',
            ms: 3,
            loops: 1,
            extra: {'Filter': r'(x = $0)'},
            plans: [
              pnode(
                'Seq Scan',
                relationship: 'InitPlan',
                ms: 6,
                loops: 1,
                extra: {'Subplan Name': r'InitPlan 1 (returns $0)'},
              ),
            ],
          ),
        ),
      );
      expect(m[0].selfMs, 0);
    });
  });

  test('CTE time is split over the CTE Scans by inclusive time', () {
    final m = _metrics(
      planJson(
        pnode(
          'Append',
          ms: 100,
          loops: 1,
          plans: [
            pnode(
              'Function Scan',
              relationship: 'InitPlan',
              ms: 80,
              loops: 1,
              extra: {'Subplan Name': 'CTE x'},
            ),
            pnode(
              'CTE Scan',
              relationship: 'Member',
              ms: 75,
              loops: 1,
              extra: {'CTE Name': 'x'},
            ),
            pnode(
              'CTE Scan',
              relationship: 'Member',
              ms: 25,
              loops: 1,
              extra: {'CTE Name': 'x'},
            ),
          ],
        ),
      ),
    );
    expect(m[0].selfMs, 0); // 100 − 75 − 25; the CTE is not subtracted here
    expect(m[2].selfMs, closeTo(75 - 80 * 0.75, 1e-9));
    expect(m[3].selfMs, closeTo(25 - 80 * 0.25, 1e-9));
    final sum = m.nodes.fold<double>(0, (s, n) => s + n.selfMs!);
    expect(sum, closeTo(100, 1e-9));
  });

  test('Result subtracts its InitPlans; other nodes do not', () {
    final m = _metrics(
      planJson(
        pnode(
          'Result',
          ms: 5,
          loops: 1,
          plans: [
            pnode(
              'Seq Scan',
              relationship: 'InitPlan',
              ms: 4,
              loops: 1,
              extra: {'Subplan Name': 'InitPlan 1'},
            ),
          ],
        ),
      ),
    );
    expect(m[0].selfMs, 1);
  });

  group('self cost', () {
    test('total minus children, clamped at 0', () {
      final m = _metrics(
        planJson(
          pnode(
            'Limit',
            cost: 5,
            plans: [
              pnode(
                'Sort',
                cost: 120,
                relationship: 'Outer',
                plans: [pnode('Seq Scan', cost: 100, relationship: 'Outer')],
              ),
            ],
          ),
        ),
      );
      expect(m.nodes.map((n) => n.selfCost), [0, 20, 100]);
      expect(m[1].selfCostPercent, closeTo(20 / 120 * 100, 1e-9));
      expect(m[2].selfCostPercent, closeTo(100 / 120 * 100, 1e-9));
    });

    test('PostgreSQL 17 disable_cost is left out', () {
      final m = _metrics(
        planJson(
          pnode(
            'Sort',
            cost: 10000000150,
            plans: [
              pnode('Seq Scan', cost: 10000000100, relationship: 'Outer'),
            ],
          ),
        ),
      );
      expect(m[0].selfCost, closeTo(50, 1e-3));
      expect(m[1].selfCost, closeTo(100, 1e-3));
    });
  });

  group('estimate factor', () {
    EstimateDirection dir(double planned, double actual) => _metrics(
      planJson(
        pnode('Seq Scan', cost: 1, planRows: planned, rows: actual, loops: 1),
      ),
    )[0].direction;
    double? factor(double planned, double actual) => _metrics(
      planJson(
        pnode('Seq Scan', cost: 1, planRows: planned, rows: actual, loops: 1),
      ),
    )[0].estimateFactor;

    test('under, over, exact', () {
      expect(dir(10, 12345), EstimateDirection.under);
      expect(factor(10, 12345), closeTo(1234.5, 1e-9));
      expect(dir(1000, 10), EstimateDirection.over);
      expect(factor(1000, 10), 100);
      expect(dir(50, 50), EstimateDirection.exact);
      expect(factor(50, 50), 1);
    });

    test('0 rows count as 1, so the factor stays finite', () {
      expect(factor(200, 0), 200);
      expect(dir(1, 0), EstimateDirection.exact);
      expect(factor(1, 0.4), 1);
    });

    test('unknown without ANALYZE or Plan Rows', () {
      final plain = _metrics(planJson(pnode('Seq Scan', cost: 1)))[0];
      expect(plain.direction, EstimateDirection.unknown);
      expect(plain.estimateFactor, isNull);
      final noCosts = _metrics(planJson(pnode('Seq Scan', ms: 1, loops: 1)))[0];
      expect(noCosts.direction, EstimateDirection.unknown);
    });
  });

  test('row totals multiply by loops', () {
    final m = _metrics(
      planJson(
        pnode(
          'Index Scan',
          ms: 0.01,
          rows: 3,
          loops: 50000,
          extra: {
            'Rows Removed by Filter': 2,
            'Rows Removed by Index Recheck': 1,
          },
        ),
      ),
    );
    expect(m[0].totalRows, 150000);
    expect(m[0].rowsRemoved, 150000);
    expect(
      _metrics(planJson(pnode('Seq Scan', ms: 1, loops: 1)))[0].rowsRemoved,
      isNull,
    );
  });

  test('self buffers subtract the same children as time', () {
    final m = _metrics(
      planJson(
        pnode(
          'Hash Join',
          ms: 10,
          loops: 1,
          extra: {'Shared Hit Blocks': 100, 'Shared Read Blocks': 50},
          plans: [
            pnode(
              'Seq Scan',
              relationship: 'Outer',
              ms: 4,
              loops: 1,
              extra: {'Shared Hit Blocks': 60, 'Shared Read Blocks': 50},
            ),
            pnode(
              'Seq Scan',
              relationship: 'InitPlan',
              ms: 1,
              loops: 1,
              extra: {'Subplan Name': 'InitPlan 1', 'Shared Hit Blocks': 30},
            ),
          ],
        ),
      ),
    );
    expect(m[0].selfBuffers!.sharedHit, 40);
    expect(m[0].selfBuffers!.sharedRead, 0);
    expect(m[1].selfBuffers!.sharedRead, 50);
    expect(
      _metrics(planJson(pnode('Seq Scan', ms: 1, loops: 1)))[0].selfBuffers,
      isNull,
    );
  });

  group('percentages, triggers and other time', () {
    test('selfPercent is of Execution Time', () {
      final m = _metrics(
        planJson(
          pnode('Seq Scan', ms: 40, loops: 1),
          executionMs: 100,
          triggers: [
            {'Trigger Name': 't1', 'Relation': 'x', 'Time': 30, 'Calls': 1},
            {'Trigger Name': 't2', 'Relation': 'x', 'Time': 10, 'Calls': 1},
          ],
        ),
      );
      expect(m[0].selfPercent, 40);
      expect(m.triggerMs, 40);
      expect(m.otherMs, 20);
    });

    test('falls back to the root inclusive time without SUMMARY', () {
      final m = _metrics(
        planJson(
          pnode(
            'Sort',
            ms: 10,
            loops: 1,
            plans: [pnode('Seq Scan', relationship: 'Outer', ms: 4, loops: 1)],
          ),
        ),
      );
      expect(m[0].selfPercent, 60);
      expect(m[1].selfPercent, 40);
      expect(m.otherMs, isNull);
    });

    test('other time below 5 % is not reported', () {
      final m = _metrics(
        planJson(pnode('Seq Scan', ms: 96, loops: 1), executionMs: 100),
      );
      expect(m.otherMs, isNull);
      expect(m.triggerMs, 0);
    });

    test('nothing time-based without timing', () {
      final m = _metrics(
        planJson(
          pnode('Seq Scan', cost: 10, rows: 5, loops: 1),
          executionMs: 100,
        ),
      );
      expect(m[0].inclusiveMs, isNull);
      expect(m[0].selfMs, isNull);
      expect(m[0].selfPercent, isNull);
      expect(m[0].totalRows, 5);
      expect(m.otherMs, isNull);
    });
  });
}
