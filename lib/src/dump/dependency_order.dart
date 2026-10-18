// File: dependency_order.dart
// Purpose: A deterministic topological sort for dump ordering (Kahn's
// algorithm with a comparator as the tie-breaker) that never fails: when
// the remaining objects only depend on each other, the smallest one that
// sits in a cycle is emitted next and reported. Cycles (strongly
// connected components) are found with an iterative Tarjan, so deep
// dependency chains can't overflow the stack.

import 'dart:collection';

/// The order [dependencyOrder] chose and the cycles it had to cut.
final class DependencyOrder<T> {
  /// Creates a result.
  const DependencyOrder({
    required this.order,
    this.cycles = const [],
    this.forced = const {},
  });

  /// Every node, each after the nodes it needs (except where a cycle made
  /// that impossible).
  final List<T> order;

  /// Groups of nodes that need each other (components of two or more
  /// nodes, or one node that needs itself), each in [order] order.
  final List<List<T>> cycles;

  /// Nodes emitted before something they need, to cut a cycle.
  final Set<T> forced;
}

/// Orders [nodes] so each comes after the nodes it [needs] (edges to
/// nodes outside [nodes] are ignored). Among nodes that are ready at the
/// same time, the smallest by [compare] comes first, so the order is
/// stable. [compare] must be a total order (0 only for the same node).
DependencyOrder<T> dependencyOrder<T>(
  List<T> nodes,
  Map<T, Set<T>> needs,
  int Function(T a, T b) compare,
) {
  final members = nodes.toSet();
  final needed = <T, Set<T>>{
    for (final n in nodes)
      n: {
        for (final m in needs[n] ?? const <Never>{})
          if (members.contains(m)) m,
      },
  };
  final dependents = <T, List<T>>{for (final n in nodes) n: []};
  for (final MapEntry(key: n, value: ms) in needed.entries) {
    for (final m in ms) {
      dependents[m]!.add(n);
    }
  }
  final components = _components(nodes, needed);
  final cyclic = <T>{
    for (final c in components)
      if (c.length > 1 || needed[c.single]!.contains(c.single)) ...c,
  };

  final remaining = <T, int>{for (final n in nodes) n: needed[n]!.length};
  final ready = SplayTreeSet<T>(compare)
    ..addAll([
      for (final MapEntry(:key, :value) in remaining.entries)
        if (value == 0) key,
    ]);
  final order = <T>[];
  final forced = <T>{};
  final done = <T>{};
  while (order.length < nodes.length) {
    T next;
    if (ready.isNotEmpty) {
      next = ready.first;
      ready.remove(next);
    } else {
      // Stuck: everything left waits on something else left. Cut at the
      // smallest node that is part of a cycle.
      next =
          (remaining.keys.where(cyclic.contains).toList()..sort(compare)).first;
      forced.add(next);
    }
    remaining.remove(next);
    done.add(next);
    order.add(next);
    for (final d in dependents[next]!) {
      if (done.contains(d)) continue;
      final left = remaining[d]! - 1;
      remaining[d] = left;
      if (left == 0) ready.add(d);
    }
  }
  final position = {for (final (i, n) in order.indexed) n: i};
  final cycles = [
    for (final c in components)
      if (c.length > 1 || needed[c.single]!.contains(c.single))
        c.toList()..sort((a, b) => position[a]!.compareTo(position[b]!)),
  ]..sort((a, b) => position[a.first]!.compareTo(position[b.first]!));
  return DependencyOrder(order: order, cycles: cycles, forced: forced);
}

/// Strongly connected components of the graph (iterative Tarjan).
List<List<T>> _components<T>(List<T> nodes, Map<T, Set<T>> needed) {
  var counter = 0;
  final index = <T, int>{};
  final low = <T, int>{};
  final onStack = <T>{};
  final stack = <T>[];
  final out = <List<T>>[];
  for (final root in nodes) {
    if (index.containsKey(root)) continue;
    final work = <(T, Iterator<T>)>[(root, needed[root]!.iterator)];
    index[root] = low[root] = counter++;
    stack.add(root);
    onStack.add(root);
    while (work.isNotEmpty) {
      final (node, edges) = work.last;
      if (edges.moveNext()) {
        final next = edges.current;
        if (!index.containsKey(next)) {
          index[next] = low[next] = counter++;
          stack.add(next);
          onStack.add(next);
          work.add((next, needed[next]!.iterator));
        } else if (onStack.contains(next)) {
          low[node] = _min(low[node]!, index[next]!);
        }
        continue;
      }
      work.removeLast();
      if (work.isNotEmpty) {
        final parent = work.last.$1;
        low[parent] = _min(low[parent]!, low[node]!);
      }
      if (low[node] == index[node]) {
        final component = <T>[];
        T member;
        do {
          member = stack.removeLast();
          onStack.remove(member);
          component.add(member);
        } while (member != node);
        out.add(component);
      }
    }
  }
  return out;
}

int _min(int a, int b) => a < b ? a : b;
