// File: plan_issues_test.dart
// Purpose: Unit tests for PlanIssues.find: one positive and one negative
// case per PlanIssueCode, facts, ranking, the limit, the minimum impact
// and the fast-query cutoff.

import 'package:dabase_postgresql/explain.dart';
import 'package:test/test.dart';

import '../support/explain_json.dart';

List<PlanIssue> _find(String json, {int max = 20}) {
  final plan = ExplainPlan.parse(json);
  return PlanIssues.find(plan, PlanMetrics.compute(plan), max: max);
}

List<PlanIssueCode> _codes(String json) =>
    _find(json).map((i) => i.code).toList();

PlanIssue _only(String json, PlanIssueCode code) =>
    _find(json).singleWhere((i) => i.code == code);

/// A [type] node timed at [ms] ms over [child].
Map<String, Object?> _over(
  String type,
  double ms,
  Map<String, Object?> child, {
  Map<String, Object?> extra = const {},
}) => pnode(type, ms: ms, rows: 1, loops: 1, extra: extra, plans: [child]);

void main() {
  group('dominantNode', () {
    test('a node with at least 40 % of the time', () {
      final issue = _only(
        planJson(
          _over(
            'Sort',
            100,
            pnode('Seq Scan', relationship: 'Outer', ms: 20, rows: 1, loops: 1),
          ),
          executionMs: 100,
        ),
        PlanIssueCode.dominantNode,
      );
      expect(issue.nodeId, 0);
      expect(issue.facts['percent'], 80);
      expect(issue.facts['ms'], 80);
      expect(issue.impact, closeTo(0.8, 1e-9));
      expect(issue.score, closeTo(5 * 0.8 * 0.9, 1e-9));
    });

    test('not below 40 %', () {
      final issues = _find(
        planJson(
          _over(
            'Sort',
            100,
            pnode('Seq Scan', relationship: 'Outer', ms: 65, rows: 1, loops: 1),
          ),
          executionMs: 100,
        ),
      );
      expect(issues.map((i) => (i.code, i.nodeId)), [
        (PlanIssueCode.dominantNode, 1),
      ]);
    });

    test('replaced by a more specific issue on the same node', () {
      final codes = _codes(
        planJson(
          pnode(
            'Seq Scan',
            ms: 100,
            rows: 10,
            loops: 1,
            cost: 1000,
            planRows: 10,
            width: 100,
            extra: {'Rows Removed by Filter': 100000},
          ),
          executionMs: 100,
        ),
      );
      expect(codes, [PlanIssueCode.indexPotential]);
    });
  });

  group('badRowEstimate', () {
    Map<String, Object?> join(double planned, {String parent = 'Hash Join'}) =>
        pnode(
          parent,
          ms: 100,
          rows: 1,
          loops: 1,
          plans: [
            pnode(
              'Seq Scan',
              relationship: 'Outer',
              cost: 10,
              planRows: planned,
              ms: 10,
              rows: 12345,
              loops: 1,
              extra: {'Relation Name': 'orders'},
            ),
            pnode(
              'Hash',
              relationship: 'Inner',
              ms: 5,
              rows: 1,
              loops: 1,
              plans: [
                pnode(
                  'Seq Scan',
                  relationship: 'Outer',
                  ms: 4,
                  rows: 1,
                  loops: 1,
                ),
              ],
            ),
          ],
        );

    test('factor ≥ 10 under a join', () {
      final issue = _only(
        planJson(join(10), executionMs: 100),
        PlanIssueCode.badRowEstimate,
      );
      expect(issue.nodeId, 1);
      expect(issue.facts['estimated'], 10);
      expect(issue.facts['actual'], 12345);
      expect(issue.facts['factor'], closeTo(1234.5, 1e-9));
      expect(issue.facts['percent'], 100);
      expect(issue.facts['relation'], 'orders');
      expect(issue.impact, 1);
      expect(issue.score, closeTo(5, 1e-9));
    });

    test('not for a small factor or a parent that does not decide', () {
      expect(
        _codes(planJson(join(5000), executionMs: 100)),
        isNot(contains(PlanIssueCode.badRowEstimate)),
      );
      expect(
        _codes(planJson(join(10, parent: 'Append'), executionMs: 100)),
        isNot(contains(PlanIssueCode.badRowEstimate)),
      );
    });

    test('looks through Hash to the join', () {
      final plan = pnode(
        'Hash Join',
        ms: 100,
        rows: 1,
        loops: 1,
        plans: [
          pnode('Seq Scan', relationship: 'Outer', ms: 10, rows: 1, loops: 1),
          pnode(
            'Hash',
            relationship: 'Inner',
            ms: 50,
            rows: 1,
            loops: 1,
            plans: [
              pnode(
                'Seq Scan',
                relationship: 'Outer',
                cost: 1,
                planRows: 1,
                ms: 45,
                rows: 50000,
                loops: 1,
              ),
            ],
          ),
        ],
      );
      expect(
        _only(
          planJson(plan, executionMs: 100),
          PlanIssueCode.badRowEstimate,
        ).nodeId,
        3,
      );
    });

    test('only where the error starts, not where it is inherited', () {
      final plan = pnode(
        'Aggregate',
        ms: 100,
        rows: 1,
        loops: 1,
        plans: [
          pnode(
            'Nested Loop',
            relationship: 'Outer',
            cost: 10,
            planRows: 10,
            ms: 90,
            rows: 10000,
            loops: 1,
            plans: [
              pnode(
                'Seq Scan',
                relationship: 'Outer',
                cost: 1,
                planRows: 10,
                ms: 10,
                rows: 10000,
                loops: 1,
              ),
              pnode(
                'Result',
                relationship: 'Inner',
                ms: 0.001,
                rows: 1,
                loops: 10000,
              ),
            ],
          ),
        ],
      );
      final issues = _find(planJson(plan, executionMs: 100))
          .where((i) => i.code == PlanIssueCode.badRowEstimate);
      expect(issues.map((i) => i.nodeId), [2]);
    });
  });

  group('indexPotential', () {
    Map<String, Object?> scan(double removed, double kept, {int width = 100}) =>
        pnode(
          'Seq Scan',
          cost: 1000,
          planRows: kept,
          width: width,
          ms: 90,
          rows: kept,
          loops: 1,
          extra: {
            'Relation Name': 'orders',
            'Filter': "(status = 'shipped'::text)",
            'Rows Removed by Filter': removed,
          },
        );

    test('filter removes most rows of a big table', () {
      final issue = _only(
        planJson(_over('Limit', 100, scan(100000, 10)), executionMs: 100),
        PlanIssueCode.indexPotential,
      );
      expect(issue.nodeId, 1);
      expect(issue.facts['removed'], 100000);
      expect(issue.facts['kept'], 10);
      expect(issue.facts['column'], 'status');
      expect(issue.facts['relation'], 'orders');
      expect(issue.facts['percent'], 90);
      expect(issue.impact, closeTo(0.9 * 100000 / 100010, 1e-9));
    });

    test('removed rows are totals over loops', () {
      final s = scan(3, 1, width: 4000)..['Actual Loops'] = 50000;
      final issue = _only(
        planJson(_over('Limit', 100, s), executionMs: 100),
        PlanIssueCode.indexPotential,
      );
      expect(issue.facts['removed'], 150000);
      expect(issue.facts['kept'], 50000);
    });

    test('not when the filter keeps a third or more', () {
      expect(
        _codes(planJson(_over('Limit', 100, scan(15, 10)), executionMs: 100)),
        isNot(contains(PlanIssueCode.indexPotential)),
      );
    });

    test('not for a table of a few pages', () {
      expect(
        _codes(
          planJson(
            _over('Limit', 100, scan(100, 1, width: 8)),
            executionMs: 100,
          ),
        ),
        isNot(contains(PlanIssueCode.indexPotential)),
      );
    });
  });

  group('poorIndexEfficiency', () {
    Map<String, Object?> scan(double removed) => pnode(
      'Index Scan',
      ms: 50,
      rows: 10,
      loops: 1,
      extra: {
        'Relation Name': 'orders',
        'Index Name': 'orders_created_idx',
        'Filter': "((o.status)::text = 'x'::text)",
        'Rows Removed by Filter': removed,
      },
    );

    test('the filter discards most index rows', () {
      final issue = _only(
        planJson(_over('Sort', 100, scan(90), extra: {}), executionMs: 100),
        PlanIssueCode.poorIndexEfficiency,
      );
      expect(issue.facts['percent'], 90);
      expect(issue.facts['removed'], 90);
      expect(issue.facts['kept'], 10);
      expect(issue.facts['column'], 'status');
      expect(issue.impact, closeTo(0.5 * 0.9, 1e-9));
    });

    test('not when few rows are removed', () {
      expect(
        _codes(planJson(_over('Sort', 100, scan(5)), executionMs: 100)),
        isNot(contains(PlanIssueCode.poorIndexEfficiency)),
      );
    });
  });

  group('sortOnDisk', () {
    test('external merge', () {
      final issue = _only(
        planJson(
          _over(
            'Sort',
            100,
            pnode('Seq Scan', relationship: 'Outer', ms: 20, rows: 1, loops: 1),
            extra: {
              'Sort Method': 'external merge',
              'Sort Space Used': 180000,
              'Sort Space Type': 'Disk',
            },
          ),
          executionMs: 100,
        ),
        PlanIssueCode.sortOnDisk,
      );
      expect(issue.nodeId, 0);
      expect(issue.facts['diskKb'], 180000);
      expect(issue.facts['setting'], 'work_mem');
      expect(issue.score, closeTo(5 * 0.8, 1e-9));
    });

    test('a worker that spilled', () {
      expect(
        _codes(
          planJson(
            _over(
              'Sort',
              100,
              pnode(
                'Seq Scan',
                relationship: 'Outer',
                ms: 20,
                rows: 1,
                loops: 1,
              ),
              extra: {
                'Sort Method': 'quicksort',
                'Sort Space Used': 25,
                'Sort Space Type': 'Memory',
                'Workers': [
                  {
                    'Worker Number': 0,
                    'Sort Method': 'external sort',
                    'Sort Space Used': 4000,
                    'Sort Space Type': 'Disk',
                  },
                ],
              },
            ),
            executionMs: 100,
          ),
        ),
        contains(PlanIssueCode.sortOnDisk),
      );
    });

    test('not in memory', () {
      expect(
        _codes(
          planJson(
            _over(
              'Sort',
              100,
              pnode(
                'Seq Scan',
                relationship: 'Outer',
                ms: 20,
                rows: 1,
                loops: 1,
              ),
              extra: {
                'Sort Method': 'quicksort',
                'Sort Space Used': 25,
                'Sort Space Type': 'Memory',
              },
            ),
            executionMs: 100,
          ),
        ),
        isNot(contains(PlanIssueCode.sortOnDisk)),
      );
    });
  });

  group('hashOnDisk', () {
    String hashJoin(int batches) => planJson(
      pnode(
        'Hash Join',
        ms: 100,
        rows: 1,
        loops: 1,
        plans: [
          pnode('Seq Scan', relationship: 'Outer', ms: 20, rows: 1, loops: 1),
          pnode(
            'Hash',
            relationship: 'Inner',
            ms: 50,
            rows: 1,
            loops: 1,
            extra: {'Hash Batches': batches, 'Original Hash Batches': 1},
            plans: [
              pnode(
                'Seq Scan',
                relationship: 'Outer',
                ms: 10,
                rows: 1,
                loops: 1,
              ),
            ],
          ),
        ],
      ),
      executionMs: 100,
    );

    test('hash batches > 1, with the join time', () {
      final issue = _only(hashJoin(8), PlanIssueCode.hashOnDisk);
      expect(issue.nodeId, 2);
      expect(issue.facts['batches'], 8);
      expect(issue.facts['setting'], 'work_mem');
      expect(issue.impact, closeTo(0.7, 1e-9)); // Hash 40 + join 30
    });

    test('hash aggregate that spilled', () {
      final issue = _only(
        planJson(
          _over(
            'Aggregate',
            100,
            pnode('Seq Scan', relationship: 'Outer', ms: 30, rows: 1, loops: 1),
            extra: {
              'Strategy': 'Hashed',
              'HashAgg Batches': 5,
              'Disk Usage': 1024,
            },
          ),
          executionMs: 100,
        ),
        PlanIssueCode.hashOnDisk,
      );
      expect(issue.facts['batches'], 5);
      expect(issue.facts['diskKb'], 1024);
    });

    test('other nodes that wrote temp files', () {
      final issue = _only(
        planJson(
          _over(
            'Materialize',
            100,
            pnode('Seq Scan', relationship: 'Outer', ms: 30, rows: 1, loops: 1),
            extra: {'Temp Written Blocks': 128},
          ),
          executionMs: 100,
        ),
        PlanIssueCode.hashOnDisk,
      );
      expect(issue.facts['diskKb'], 1024);
    });

    test('not with one batch', () {
      expect(_codes(hashJoin(1)), isNot(contains(PlanIssueCode.hashOnDisk)));
    });
  });

  group('manyLoops', () {
    String loop(int loops) => planJson(
      pnode(
        'Nested Loop',
        ms: 100,
        rows: 1,
        loops: 1,
        plans: [
          pnode(
            'Seq Scan',
            relationship: 'Outer',
            cost: 1,
            planRows: 5,
            ms: 5,
            rows: loops.toDouble(),
            loops: 1,
          ),
          pnode(
            'Index Scan',
            relationship: 'Inner',
            ms: 95 / loops,
            rows: 1,
            loops: loops,
            extra: {'Relation Name': 'items'},
          ),
        ],
      ),
      executionMs: 100,
    );

    test('inner side run thousands of times', () {
      final issue = _only(loop(48000), PlanIssueCode.manyLoops);
      expect(issue.nodeId, 0);
      expect(issue.facts['loops'], 48000);
      expect(issue.facts['ms'], closeTo(95, 1e-9));
      expect(issue.facts['relation'], 'items');
      expect(issue.facts['factor'], 9600);
      expect(issue.facts['estimated'], 5);
      expect(issue.facts['actual'], 48000);
    });

    test('not under 1,000 loops', () {
      expect(_codes(loop(500)), isNot(contains(PlanIssueCode.manyLoops)));
    });
  });

  group('lossyBitmap', () {
    String bitmap(int lossy) => planJson(
      _over(
        'Bitmap Heap Scan',
        100,
        pnode(
          'Bitmap Index Scan',
          relationship: 'Outer',
          ms: 5,
          rows: 1,
          loops: 1,
        ),
        extra: {
          'Relation Name': 'events',
          'Exact Heap Blocks': 100,
          'Lossy Heap Blocks': lossy,
          'Rows Removed by Index Recheck': 12000,
        },
      )..['Actual Rows'] = 1000,
      executionMs: 100,
    );

    test('lossy blocks with rechecked rows', () {
      final issue = _only(bitmap(1200), PlanIssueCode.lossyBitmap);
      expect(issue.facts['removed'], 12000);
      expect(issue.facts['setting'], 'work_mem');
      expect(issue.impact, closeTo(0.95 * 12000 / 13000, 1e-9));
    });

    test('not without lossy blocks', () {
      expect(_codes(bitmap(0)), isNot(contains(PlanIssueCode.lossyBitmap)));
    });
  });

  group('excessiveHeapFetches', () {
    String ios(int fetches, {int loops = 1}) => planJson(
      _over(
        'Aggregate',
        100,
        pnode(
          'Index Only Scan',
          relationship: 'Outer',
          ms: 80 / loops,
          rows: 1000 / loops,
          loops: loops,
          extra: {'Relation Name': 'orders', 'Heap Fetches': fetches},
        ),
      ),
      executionMs: 100,
    );

    test('most rows fetched from the heap', () {
      final issue = _only(ios(850), PlanIssueCode.excessiveHeapFetches);
      expect(issue.nodeId, 1);
      expect(issue.facts['percent'], 85);
      expect(issue.impact, closeTo(0.8 * 0.85, 1e-9));
    });

    test('Heap Fetches is a total, rows are per loop', () {
      final issue = _only(
        ios(850, loops: 10),
        PlanIssueCode.excessiveHeapFetches,
      );
      expect(issue.facts['percent'], closeTo(85, 1e-9));
    });

    test('not for a few fetches', () {
      expect(
        _codes(ios(100)),
        isNot(contains(PlanIssueCode.excessiveHeapFetches)),
      );
    });
  });

  group('poorCachePerformance', () {
    String scan(int hit, int read, {double rows = 1000000}) => planJson(
      _over(
        'Aggregate',
        100,
        pnode(
          'Seq Scan',
          relationship: 'Outer',
          ms: 80,
          rows: rows,
          loops: 1,
          extra: {
            'Relation Name': 'big',
            'Shared Hit Blocks': hit,
            'Shared Read Blocks': read,
          },
        ),
      ),
      executionMs: 100,
    );

    test('most blocks read from disk', () {
      final issue = _only(
        scan(2000, 80000),
        PlanIssueCode.poorCachePerformance,
      );
      expect(issue.facts['readMb'], 625);
      expect(issue.facts['percent'], closeTo(80000 / 82000 * 100, 1e-9));
    });

    test('many blocks per row returned', () {
      expect(
        _codes(scan(50000, 0, rows: 10)),
        contains(PlanIssueCode.poorCachePerformance),
      );
    });

    test('not for a mostly cached scan', () {
      expect(
        _codes(scan(80000, 5000)),
        isNot(contains(PlanIssueCode.poorCachePerformance)),
      );
    });
  });

  group('jitOverhead', () {
    String jit(double ms) => planJson(
      pnode('Seq Scan', ms: 600, rows: 1, loops: 1),
      executionMs: 600,
      jit: {
        'Functions': 10,
        'Timing': {'Total': ms},
      },
    );

    test('compilation took a large share', () {
      final issue = _only(jit(210), PlanIssueCode.jitOverhead);
      expect(issue.nodeId, isNull);
      expect(issue.facts['jitMs'], 210);
      expect(issue.facts['executionMs'], 600);
      expect(issue.facts['percent'], 35);
      expect(issue.facts['setting'], 'jit');
    });

    test('not for a short compilation', () {
      expect(_codes(jit(30)), isNot(contains(PlanIssueCode.jitOverhead)));
    });
  });

  group('workersMissing', () {
    String gather(int launched) => planJson(
      pnode(
        'Gather',
        ms: 100,
        rows: 1,
        loops: 1,
        extra: {'Workers Planned': 4, 'Workers Launched': launched},
        plans: [
          pnode('Seq Scan', relationship: 'Outer', ms: 90, rows: 1, loops: 2),
        ],
      ),
      executionMs: 100,
    );

    test('fewer workers than planned', () {
      final issue = _only(gather(1), PlanIssueCode.workersMissing);
      expect(issue.nodeId, 0);
      expect(issue.facts['planned'], 4);
      expect(issue.facts['launched'], 1);
      expect(issue.facts['planned'], isA<int>());
      expect(issue.impact, closeTo(1 - 2 / 5, 1e-9));
    });

    test('not when all were launched', () {
      expect(_codes(gather(4)), isNot(contains(PlanIssueCode.workersMissing)));
    });
  });

  group('slowPlanning', () {
    test('planning longer than execution, even for a fast execution', () {
      final issue = _only(
        planJson(
          pnode('Seq Scan', ms: 5, rows: 1, loops: 1),
          planningMs: 40,
          executionMs: 5,
        ),
        PlanIssueCode.slowPlanning,
      );
      expect(issue.facts['planningMs'], 40);
      expect(issue.facts['executionMs'], 5);
      expect(issue.facts['percent'], closeTo(40 / 45 * 100, 1e-9));
      // Node checks need 10 ms of execution: no dominantNode here.
      expect(
        _codes(
          planJson(
            pnode('Seq Scan', ms: 5, rows: 1, loops: 1),
            planningMs: 40,
            executionMs: 5,
          ),
        ),
        [PlanIssueCode.slowPlanning],
      );
    });

    test('not for short planning', () {
      expect(
        _codes(
          planJson(
            pnode('Seq Scan', ms: 100, rows: 1, loops: 1),
            planningMs: 5,
            executionMs: 100,
          ),
        ),
        isNot(contains(PlanIssueCode.slowPlanning)),
      );
    });
  });

  group('triggerTime', () {
    test('foreign-key triggers (PEV2 22-triggers plan)', () {
      final issue = _only(
        explainFixture('22-triggers-fk'),
        PlanIssueCode.triggerTime,
      );
      expect(issue.nodeId, isNull);
      expect(issue.facts['ms'], closeTo(163900.503, 1e-6));
      expect(
        issue.facts['percent'],
        closeTo(163900.503 / 381072.164 * 100, 1e-9),
      );
      // That (text) plan has no trigger names: the constraint name is used.
      expect(issue.facts['triggerName'], 'attachemessageref');
    });

    test('names the slowest trigger', () {
      final issue = _only(
        planJson(
          pnode('Seq Scan', ms: 50, rows: 1, loops: 1),
          executionMs: 100,
          triggers: [
            {'Trigger Name': 'a', 'Relation': 'x', 'Time': 10, 'Calls': 1},
            {'Trigger Name': 'b', 'Relation': 'y', 'Time': 30, 'Calls': 1},
          ],
        ),
        PlanIssueCode.triggerTime,
      );
      expect(issue.facts['triggerName'], 'b');
      expect(issue.facts['relation'], 'y');
      expect(issue.facts['ms'], 40);
    });

    test('not for cheap triggers', () {
      expect(
        _codes(
          planJson(
            pnode('Seq Scan', ms: 99, rows: 1, loops: 1),
            executionMs: 100,
            triggers: [
              {'Trigger Name': 'a', 'Relation': 'x', 'Time': 1, 'Calls': 1},
            ],
          ),
        ),
        isNot(contains(PlanIssueCode.triggerTime)),
      );
    });
  });

  group('disabledNode', () {
    test('PostgreSQL 18 Disabled with ANALYZE', () {
      final issue = _only(
        planJson(
          _over(
            'Sort',
            100,
            pnode(
              'Seq Scan',
              relationship: 'Outer',
              ms: 60,
              rows: 1,
              loops: 1,
              extra: {'Disabled': true, 'Relation Name': 't'},
            ),
          ),
          executionMs: 100,
          settings: {'enable_seqscan': 'off', 'work_mem': '4MB'},
        ),
        PlanIssueCode.disabledNode,
      );
      expect(issue.nodeId, 1);
      expect(issue.facts['setting'], 'enable_seqscan');
      expect(issue.facts['relation'], 't');
      expect(issue.facts['percent'], 60);
    });

    test('PostgreSQL 17 disable_cost, plan only', () {
      final issues = _find(
        planJson(
          pnode(
            'Aggregate',
            cost: 10000000500,
            plans: [
              pnode(
                'Seq Scan',
                relationship: 'Outer',
                cost: 10000000470,
                extra: {'Relation Name': 'tenk2'},
              ),
            ],
          ),
          settings: {'enable_seqscan': 'off'},
        ),
      );
      final issue = issues.single;
      expect(issue.code, PlanIssueCode.disabledNode);
      expect(issue.nodeId, 1);
      expect(issue.facts['percent'], closeTo(470 / 500 * 100, 1e-9));
      expect(issue.facts.containsKey('ms'), isFalse);
    });

    test('not when nothing is disabled', () {
      expect(
        _codes(
          planJson(
            pnode(
              'Seq Scan',
              ms: 100,
              rows: 1,
              loops: 1,
              extra: {'Disabled': false},
            ),
            executionMs: 100,
          ),
        ),
        isNot(contains(PlanIssueCode.disabledNode)),
      );
    });
  });

  group('ranking and limits', () {
    // Sort on disk (40 %), hash spill, missing workers, JIT and triggers.
    final busy = planJson(
      pnode(
        'Sort',
        ms: 1000,
        rows: 1,
        loops: 1,
        extra: {'Sort Method': 'external merge', 'Sort Space Type': 'Disk'},
        plans: [
          pnode(
            'Gather',
            relationship: 'Outer',
            ms: 600,
            rows: 1,
            loops: 1,
            extra: {'Workers Planned': 4, 'Workers Launched': 0},
            plans: [
              pnode(
                'Hash Join',
                relationship: 'Outer',
                ms: 600,
                rows: 1,
                loops: 1,
                plans: [
                  pnode(
                    'Seq Scan',
                    relationship: 'Outer',
                    ms: 100,
                    rows: 1,
                    loops: 1,
                  ),
                  pnode(
                    'Hash',
                    relationship: 'Inner',
                    ms: 350,
                    rows: 1,
                    loops: 1,
                    extra: {'Hash Batches': 16},
                    plans: [
                      pnode(
                        'Seq Scan',
                        relationship: 'Outer',
                        ms: 100,
                        rows: 1,
                        loops: 1,
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
      executionMs: 1300,
      jit: {
        'Functions': 3,
        'Timing': {'Total': 200},
      },
      triggers: [
        {'Trigger Name': 't', 'Relation': 'x', 'Time': 300, 'Calls': 1},
      ],
    );

    test('at most 3 by default, ordered by score', () {
      final plan = ExplainPlan.parse(busy);
      final issues = PlanIssues.find(plan, PlanMetrics.compute(plan));
      expect(issues, hasLength(3));
      final scores = issues.map((i) => i.score).toList();
      final sorted = List.of(scores)..sort((a, b) => b.compareTo(a));
      expect(scores, orderedEquals(sorted));
      expect(issues.first.code, PlanIssueCode.workersMissing);
    });

    test('max limits the list; every issue meets the minimum impact', () {
      final all = _find(busy);
      expect(all.length, greaterThan(3));
      expect(all.every((i) => i.impact >= PlanIssues.minImpact), isTrue);
      expect(all.every((i) => i.score >= 0 && i.score <= 5), isTrue);
      expect(_find(busy, max: 1), hasLength(1));
      expect(_find(busy, max: 0), isEmpty);
    });

    test('issues below the minimum impact are dropped', () {
      // A 5 % disk sort.
      expect(
        _codes(
          planJson(
            _over(
              'Sort',
              100,
              pnode(
                'Seq Scan',
                relationship: 'Outer',
                ms: 95,
                rows: 1,
                loops: 1,
              ),
              extra: {
                'Sort Method': 'external merge',
                'Sort Space Type': 'Disk',
              },
            ),
            executionMs: 100,
          ),
        ),
        isNot(contains(PlanIssueCode.sortOnDisk)),
      );
    });

    test('nothing for a fast query', () {
      final fast = planJson(
        _over(
          'Sort',
          8,
          pnode('Seq Scan', relationship: 'Outer', ms: 1, rows: 1, loops: 1),
          extra: {'Sort Method': 'external merge', 'Sort Space Type': 'Disk'},
        ),
        planningMs: 1,
        executionMs: 8,
      );
      expect(_find(fast), isEmpty);
      expect(PlanIssues.fastQueryMs, 10);
    });

    test('without ANALYZE only plan-only checks run', () {
      final planOnly = planJson(
        pnode(
          'Sort',
          cost: 100,
          extra: {'Sort Method': 'external merge', 'Sort Space Type': 'Disk'},
          plans: [
            pnode(
              'Seq Scan',
              relationship: 'Outer',
              cost: 90,
              extra: {'Rows Removed by Filter': 100000},
            ),
          ],
        ),
      );
      expect(_find(planOnly), isEmpty);
    });

    test('without timing, node checks are skipped', () {
      final untimed = planJson(
        pnode(
          'Sort',
          rows: 1,
          loops: 1,
          extra: {'Sort Method': 'external merge', 'Sort Space Type': 'Disk'},
        ),
        executionMs: 100,
      );
      expect(_find(untimed), isEmpty);
    });
  });

  group('simpleFilterColumn', () {
    test('accepts col op const', () {
      expect(simpleFilterColumn("(status = 'shipped'::text)"), 'status');
      expect(simpleFilterColumn('(t.id > 100)'), 'id');
      expect(simpleFilterColumn("((o.status)::text = 'x'::text)"), 'status');
      expect(simpleFilterColumn(r'("Order Id" = $1)'), 'Order Id');
      expect(simpleFilterColumn('(tenk2.thousand = 0)'), 'thousand');
      expect(simpleFilterColumn('(active = true)'), 'active');
      expect(simpleFilterColumn("(name ~~ 'a%'::text)"), 'name');
    });

    test('rejects anything else', () {
      expect(simpleFilterColumn('(v = w.q)'), isNull);
      expect(simpleFilterColumn("((a = 1) AND (b = 'x'::text))"), isNull);
      expect(simpleFilterColumn("(a = 'x' AND b = 'y')"), isNull);
      expect(simpleFilterColumn(r'(lower(name) = $1)'), isNull);
      expect(simpleFilterColumn("(a = ANY ('{1,2}'::integer[]))"), isNull);
      expect(simpleFilterColumn(null), isNull);
      expect(simpleFilterColumn(1), isNull);
    });
  });
}
