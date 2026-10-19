// File: dependency_order_test.dart
// Purpose: The dump's topological sort: dependencies first, ties by the
// comparator, cycles cut deterministically and reported.

import 'package:dabase_postgresql/dump.dart';
import 'package:test/test.dart';

DependencyOrder<String> order(
  List<String> nodes,
  Map<String, Set<String>> needs,
) => dependencyOrder(nodes, needs, (a, b) => a.compareTo(b));

void main() {
  test('without edges the comparator decides', () {
    expect(order(['c', 'a', 'b'], {}).order, ['a', 'b', 'c']);
  });

  test('a node comes after everything it needs', () {
    final result = order(
      ['a', 'b', 'c', 'd'],
      {
        'a': {'d'},
        'b': {'a'},
        'c': {'b', 'd'},
      },
    );
    expect(result.order, ['d', 'a', 'b', 'c']);
    expect(result.cycles, isEmpty);
    expect(result.forced, isEmpty);
  });

  test('edges to nodes outside the list are ignored', () {
    expect(
      order(
        ['a', 'b'],
        {
          'a': {'zzz'},
        },
      ).order,
      ['a', 'b'],
    );
  });

  test('a two-node cycle is cut at the smallest node and reported', () {
    final result = order(
      ['view', 'func', 'table'],
      {
        'view': {'func', 'table'},
        'func': {'view'},
      },
    );
    expect(result.order, ['table', 'func', 'view']);
    expect(result.forced, {'func'});
    expect(result.cycles, [
      ['func', 'view'],
    ]);
  });

  test('a self-dependency is a cycle of one', () {
    final result = order(
      ['a', 'b'],
      {
        'a': {'a'},
        'b': {'a'},
      },
    );
    expect(result.order, ['a', 'b']);
    expect(result.cycles, [
      ['a'],
    ]);
  });

  test('two separate cycles and the nodes after them', () {
    final result = order(
      ['a', 'b', 'c', 'd', 'e'],
      {
        'a': {'b'},
        'b': {'a'},
        'c': {'d'},
        'd': {'c'},
        'e': {'a', 'c'},
      },
    );
    expect(result.order.last, 'e');
    expect(result.cycles, hasLength(2));
    expect(result.order.indexOf('e'), 4);
  });

  test('a long chain does not overflow the stack', () {
    final nodes = [for (var i = 0; i < 20000; i++) 'n${'$i'.padLeft(5, '0')}'];
    final needs = {
      for (var i = 1; i < nodes.length; i++) nodes[i]: {nodes[i - 1]},
    };
    final result = order(nodes.reversed.toList(), needs);
    expect(result.order, nodes);
  });
}
