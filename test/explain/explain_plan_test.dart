// File: explain_plan_test.dart
// Purpose: Unit tests for ExplainPlan parsing: plan-level keys, node
// fields, display names, targets, PG 17 vs 18 number formats, never
// executed nodes, Disabled detection and malformed input.

import 'package:dabase_postgresql/explain.dart';
import 'package:test/test.dart';

import '../support/explain_json.dart';

String _name(Map<String, Object?> extra, [String type = 'Seq Scan']) =>
    ExplainPlan.parse(planJson(pnode(type, extra: extra))).root.displayName;

void main() {
  group('plan-level keys', () {
    final plan = ExplainPlan.parse(
      planJson(
        pnode('Seq Scan', cost: 10, ms: 1, rows: 5, loops: 1),
        planningMs: 0.5,
        executionMs: 1.5,
        triggers: [
          {
            'Trigger Name': 'RI_ConstraintTrigger_c_1',
            'Constraint Name': 'items_order_fk',
            'Relation': 'items',
            'Time': 0.3,
            'Calls': 5,
          },
        ],
        jit: {
          'Functions': 4,
          'Timing': {
            'Generation': {'Deform': 0.1, 'Total': 0.4},
            'Total': 12.5,
          },
        },
        settings: {'work_mem': '64MB'},
      ),
    );

    test('times, triggers, JIT, settings', () {
      expect(plan.planningMs, 0.5);
      expect(plan.executionMs, 1.5);
      final t = plan.triggers.single;
      expect(t.name, 'RI_ConstraintTrigger_c_1');
      expect(t.constraintName, 'items_order_fk');
      expect(t.relation, 'items');
      expect(t.timeMs, 0.3);
      expect(t.calls, 5);
      expect(plan.jit!.functions, 4);
      expect(plan.jit!.totalMs, 12.5);
      expect(plan.settings, {'work_mem': '64MB'});
      expect(plan.properties.keys, isNot(contains('Plan')));
      expect(plan.properties['Planning Time'], 0.5);
    });

    test('flags', () {
      expect(plan.analyzed, isTrue);
      expect(plan.timed, isTrue);
      expect(plan.hasBuffers, isFalse);
    });

    test('collections are unmodifiable', () {
      expect(() => plan.nodes.add(plan.root), throwsUnsupportedError);
      expect(() => plan.settings['x'] = 'y', throwsUnsupportedError);
      expect(() => plan.root.properties['x'] = 1, throwsUnsupportedError);
    });
  });

  test('parseAll returns every plan; parse the first', () {
    const json =
        '[{"Plan": {"Node Type": "Result"}}, '
        '{"Plan": {"Node Type": "Seq Scan"}}]';
    final plans = ExplainPlan.parseAll(json);
    expect(plans.map((p) => p.root.nodeType), ['Result', 'Seq Scan']);
    expect(ExplainPlan.parse(json).root.nodeType, 'Result');
  });

  test('a single plan object without the array is accepted', () {
    expect(
      ExplainPlan.parse('{"Plan": {"Node Type": "Result"}}').root.nodeType,
      'Result',
    );
  });

  test('Query Identifier is kept as text', () {
    final plan = ExplainPlan.parse(
      '[{"Plan": {"Node Type": "Result"}, '
      '"Query Identifier": -7290196153539186412}]',
    );
    expect(plan.queryIdentifier, '-7290196153539186412');
  });

  group('nodes', () {
    final plan = ExplainPlan.parse(
      planJson(
        pnode(
          'Hash Join',
          cost: 100,
          extra: {'Join Type': 'Inner', 'Hash Cond': '(a.id = b.a_id)'},
          plans: [
            pnode(
              'Seq Scan',
              relationship: 'Outer',
              extra: {'Relation Name': 'a', 'Alias': 'a'},
            ),
            pnode(
              'Hash',
              relationship: 'Inner',
              plans: [
                pnode(
                  'Index Scan',
                  relationship: 'Outer',
                  extra: {
                    'Relation Name': 'b',
                    'Schema': 'public',
                    'Alias': 'b1',
                    'Index Name': 'b_pkey',
                    'Scan Direction': 'Backward',
                    'Custom Future Key': [1, 2],
                  },
                ),
              ],
            ),
          ],
        ),
      ),
    );

    test('pre-order ids, depth and parents', () {
      expect(plan.nodes.map((n) => n.id), [0, 1, 2, 3]);
      expect(plan.nodes.map((n) => n.depth), [0, 1, 1, 2]);
      expect(plan.nodes.map((n) => n.parentId), [null, 0, 0, 2]);
      expect(plan.nodes.map((n) => n.nodeType), [
        'Hash Join',
        'Seq Scan',
        'Hash',
        'Index Scan',
      ]);
    });

    test('fields and unknown keys', () {
      final index = plan.nodes[3];
      expect(index.relationship, 'Outer');
      expect(index.relation, 'b');
      expect(index.schema, 'public');
      expect(index.alias, 'b1');
      expect(index.index, 'b_pkey');
      expect(index.scanDirection, 'Backward');
      expect(index.displayName, 'Index Scan Backward');
      expect(index.properties['Custom Future Key'], [1, 2]);
      expect(plan.root.properties.containsKey('Plans'), isFalse);
      expect(plan.root.properties['Hash Cond'], '(a.id = b.a_id)');
    });

    test('target', () {
      expect(plan.nodes[3].target, 'b_pkey on public.b b1');
      expect(plan.nodes[1].target, 'a');
      expect(plan.nodes[2].target, isNull);
    });
  });

  group('target', () {
    String? target(Map<String, Object?> extra, [String type = 'Seq Scan']) =>
        ExplainPlan.parse(planJson(pnode(type, extra: extra))).root.target;

    test('index on table', () {
      expect(
        target({'Index Name': 'orders_pkey', 'Relation Name': 'orders'}),
        'orders_pkey on orders',
      );
    });
    test('relation with a different alias', () {
      expect(target({'Relation Name': 'orders', 'Alias': 'o'}), 'orders o');
    });
    test('index alone', () {
      expect(
        target({'Index Name': 'orders_pkey'}, 'Bitmap Index Scan'),
        'orders_pkey',
      );
    });
    test('CTE', () {
      expect(target({'CTE Name': 'x', 'Alias': 'x'}, 'CTE Scan'), 'CTE x');
    });
    test('function', () {
      expect(
        target({'Function Name': 'generate_series', 'Alias': 'i'}),
        'generate_series i',
      );
    });
    test('nothing', () {
      expect(target({}, 'Result'), isNull);
    });
  });

  group('displayName', () {
    test('aggregate strategies', () {
      expect(_name({'Strategy': 'Plain'}, 'Aggregate'), 'Aggregate');
      expect(_name({'Strategy': 'Hashed'}, 'Aggregate'), 'HashAggregate');
      expect(_name({'Strategy': 'Sorted'}, 'Aggregate'), 'GroupAggregate');
      expect(_name({'Strategy': 'Mixed'}, 'Aggregate'), 'MixedAggregate');
    });
    test('partial modes', () {
      expect(
        _name({'Strategy': 'Hashed', 'Partial Mode': 'Partial'}, 'Aggregate'),
        'Partial HashAggregate',
      );
      expect(
        _name({'Strategy': 'Plain', 'Partial Mode': 'Finalize'}, 'Aggregate'),
        'Finalize Aggregate',
      );
      expect(
        _name({'Strategy': 'Plain', 'Partial Mode': 'Simple'}, 'Aggregate'),
        'Aggregate',
      );
    });
    test('SetOp', () {
      expect(_name({'Strategy': 'Hashed'}, 'SetOp'), 'HashSetOp');
      expect(_name({'Strategy': 'Sorted'}, 'SetOp'), 'SetOp');
    });
    test('join types', () {
      expect(_name({'Join Type': 'Inner'}, 'Hash Join'), 'Hash Join');
      expect(_name({'Join Type': 'Left'}, 'Hash Join'), 'Hash Left Join');
      expect(
        _name({'Join Type': 'Anti'}, 'Nested Loop'),
        'Nested Loop Anti Join',
      );
      expect(_name({'Join Type': 'Full'}, 'Merge Join'), 'Merge Full Join');
      expect(
        _name({'Join Type': 'Right Semi'}, 'Hash Join'),
        'Hash Right Semi Join',
      );
    });
    test('parallel, async, backward', () {
      expect(
        _name({'Parallel Aware': true, 'Join Type': 'Inner'}, 'Hash Join'),
        'Parallel Hash Join',
      );
      expect(
        _name({'Async Capable': true}, 'Foreign Scan'),
        'Async Foreign Scan',
      );
      expect(_name({'Async Capable': false}, 'Foreign Scan'), 'Foreign Scan');
      expect(
        _name({'Scan Direction': 'Backward'}, 'Index Only Scan'),
        'Index Only Scan Backward',
      );
      expect(_name({'Scan Direction': 'Forward'}, 'Index Scan'), 'Index Scan');
    });
    test('ModifyTable uses the operation', () {
      expect(_name({'Operation': 'Update'}, 'ModifyTable'), 'Update');
      expect(_name({'Operation': 'Merge'}, 'ModifyTable'), 'Merge');
      expect(_name({}, 'ModifyTable'), 'ModifyTable');
    });
  });

  group('PostgreSQL 17 vs 18 number formats', () {
    // 17 prints integral values without decimals, 18 with two.
    const pg17 = '''
[{"Plan": {"Node Type": "Seq Scan", "Parallel Aware": false,
  "Async Capable": false, "Relation Name": "t", "Alias": "t",
  "Startup Cost": 0.00, "Total Cost": 155.00, "Plan Rows": 10000,
  "Plan Width": 4, "Actual Startup Time": 0.010, "Actual Total Time": 0.700,
  "Actual Rows": 1000, "Actual Loops": 1, "Shared Hit Blocks": 45,
  "Shared Read Blocks": 0}, "Planning Time": 0.050, "Triggers": [],
  "Execution Time": 0.900}]''';
    const pg18 = '''
[{"Plan": {"Node Type": "Seq Scan", "Parallel Aware": false,
  "Async Capable": false, "Disabled": false, "Relation Name": "t",
  "Alias": "t", "Startup Cost": 0.00, "Total Cost": 155.00,
  "Plan Rows": 10000, "Plan Width": 4, "Actual Startup Time": 0.010,
  "Actual Total Time": 0.700, "Actual Rows": 1000.00, "Actual Loops": 1,
  "Index Searches": 0, "Shared Hit Blocks": 45, "Shared Read Blocks": 0},
  "Planning Time": 0.050, "Triggers": [], "Execution Time": 0.900}]''';

    test('parse to the same values', () {
      final a = ExplainPlan.parse(pg17).root;
      final b = ExplainPlan.parse(pg18).root;
      expect(a.actual!.rows, 1000.0);
      expect(b.actual!.rows, 1000.0);
      expect(a.actual!.rows, isA<double>());
      expect(a.planRows, b.planRows);
      expect(a.totalCost, b.totalCost);
      expect(a.buffers!.sharedHit, 45);
      expect(b.buffers!.sharedHit, 45);
      expect(b.properties['Index Searches'], 0);
      expect(a.disabled, isFalse);
      expect(b.disabled, isFalse);
    });

    test('fractional rows on 18', () {
      final plan = ExplainPlan.parse(
        pg18.replaceFirst('"Actual Rows": 1000.00', '"Actual Rows": 0.40'),
      );
      expect(plan.root.actual!.rows, 0.4);
    });
  });

  test('never-executed node', () {
    final plan = ExplainPlan.parse(
      planJson(
        pnode(
          'Nested Loop',
          cost: 10,
          ms: 1,
          rows: 0,
          loops: 1,
          plans: [
            pnode('Seq Scan', cost: 1, ms: 0.5, rows: 0, loops: 1),
            pnode('Index Scan', cost: 8, planRows: 1, ms: 0, loops: 0),
          ],
        ),
      ),
    );
    final never = plan.nodes[2];
    expect(never.actual!.neverExecuted, isTrue);
    expect(plan.nodes[1].actual!.neverExecuted, isFalse);
    final m = PlanMetrics.compute(plan);
    expect(m[2].inclusiveMs, 0);
    expect(m[2].selfMs, 0);
    expect(m[2].direction, EstimateDirection.unknown);
    expect(m[2].estimateFactor, isNull);
  });

  group('Disabled', () {
    test('PostgreSQL 18 key', () {
      final plan = ExplainPlan.parse(
        planJson(
          pnode(
            'Sort',
            cost: 100,
            extra: {'Disabled': false},
            plans: [
              pnode('Seq Scan', cost: 50, extra: {'Disabled': true}),
            ],
          ),
        ),
      );
      expect(plan.nodes.map((n) => n.disabled), [false, true]);
    });

    test('PostgreSQL 17 disable_cost marks the lowest node only', () {
      final plan = ExplainPlan.parse(
        planJson(
          pnode(
            'Aggregate',
            cost: 10000023629.70,
            plans: [
              pnode(
                'Nested Loop',
                cost: 10000023213.07,
                plans: [
                  pnode('Seq Scan', cost: 10000000470),
                  pnode('Gather', cost: 421.53),
                ],
              ),
            ],
          ),
        ),
      );
      expect(plan.nodes.map((n) => n.disabled), [false, false, true, false]);
    });

    test('below 1e10 is not disabled', () {
      final plan = ExplainPlan.parse(
        planJson(pnode('Seq Scan', cost: 9000000000)),
      );
      expect(plan.root.disabled, isFalse);
    });
  });

  group('malformed input throws FormatException', () {
    final bad = <String, String>{
      'not JSON': 'Seq Scan on t  (cost=0.00..1.00 rows=1 width=4)',
      'truncated': '[{"Plan": {"Node Type": "Seq Scan"',
      'empty array': '[]',
      'number': '42',
      'array of strings': '["QUERY PLAN"]',
      'no Plan': '[{"Planning Time": 1}]',
      'Plan not an object': '[{"Plan": []}]',
      'no Node Type': '[{"Plan": {"Total Cost": 1}}]',
      'empty Node Type': '[{"Plan": {"Node Type": ""}}]',
      'Plans not an array': '[{"Plan": {"Node Type": "A", "Plans": {}}}]',
      'Plans with a string': '[{"Plan": {"Node Type": "A", "Plans": ["x"]}}]',
      'cost as text': '[{"Plan": {"Node Type": "A", "Total Cost": "1.0"}}]',
      'Parallel Aware as text':
          '[{"Plan": {"Node Type": "A", "Parallel Aware": "false"}}]',
      'Relation Name as number':
          '[{"Plan": {"Node Type": "A", "Relation Name": 1}}]',
      'Triggers not an array': '[{"Plan": {"Node Type": "A"}, "Triggers": {}}]',
      'Settings not an object':
          '[{"Plan": {"Node Type": "A"}, "Settings": []}]',
      'JIT not an object': '[{"Plan": {"Node Type": "A"}, "JIT": 1}]',
    };
    for (final MapEntry(:key, :value) in bad.entries) {
      test(key, () {
        expect(
          () => ExplainPlan.parseAll(value),
          throwsA(isA<FormatException>()),
        );
      });
    }

    test('the message does not repeat the input', () {
      const secret = 'Seq Scan on secret_table';
      expect(
        () => ExplainPlan.parse(secret),
        throwsA(
          isA<FormatException>()
              .having((e) => e.toString(), 'text', isNot(contains('secret')))
              .having((e) => e.source, 'source', isNull),
        ),
      );
    });
  });

  test('ExplainPlan rejects nodes whose ids are not pre-order', () {
    expect(
      () => ExplainPlan(
        root: PlanNode(id: 1, depth: 0, nodeType: 'Result'),
        analyzed: false,
        timed: false,
        hasBuffers: false,
      ),
      throwsArgumentError,
    );
  });
}
