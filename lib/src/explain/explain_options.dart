// File: explain_options.dart
// Purpose: Builds the `EXPLAIN (FORMAT JSON, ...)` option list, gated by
// server version and by PostgreSQL's option rules.

/// The options for an `EXPLAIN (FORMAT JSON ...)` run. [toSql] drops the
/// ones the server or the other options don't allow, so any combination is
/// safe to send.
final class ExplainOptions {
  /// Creates options. The defaults are a plain (not executed) explain with
  /// `BUFFERS` and `SETTINGS`.
  const ExplainOptions({
    this.analyze = false,
    this.buffers = true,
    this.verbose = false,
    this.settings = true,
    this.wal = false,
    this.serialize = false,
    this.memory = false,
    this.genericPlan = false,
    this.timing = true,
  });

  /// `ANALYZE`: run the statement and measure it. The caller must wrap the
  /// run in a transaction or savepoint and roll it back.
  final bool analyze;

  /// `BUFFERS`: buffer counters (planning buffers without [analyze]).
  /// Sent explicitly so PostgreSQL 13–17 match 18, where it is on by
  /// default with `ANALYZE`; `BUFFERS OFF` is sent to 18+ when false.
  final bool buffers;

  /// `VERBOSE`: output columns, schemas, per-worker timing, query id.
  final bool verbose;

  /// `SETTINGS` (PostgreSQL 12+): non-default planner settings.
  final bool settings;

  /// `WAL` (PostgreSQL 13+, needs [analyze]): WAL records written.
  final bool wal;

  /// `SERIALIZE` (PostgreSQL 17+, needs [analyze]): the cost of converting
  /// result rows to text.
  final bool serialize;

  /// `MEMORY` (PostgreSQL 17+): planner memory.
  final bool memory;

  /// `GENERIC_PLAN` (PostgreSQL 16+, not with [analyze]): plan `$n`
  /// parameters without values.
  final bool genericPlan;

  /// `TIMING`: per-node timing with [analyze]. When false, `TIMING OFF` is
  /// sent (only with [analyze]).
  final bool timing;

  /// The parenthesised option list for [serverVersionNum], e.g. `(FORMAT
  /// JSON, ANALYZE, BUFFERS, SETTINGS)`. Drops options the server doesn't
  /// know (generic_plan <16, serialize/memory <17), options needing ANALYZE
  /// when not analyzing (wal, serialize, timing off), and genericPlan with
  /// analyze.
  ///
  /// [serverVersionNum] is `server_version_num`, e.g. 170004. Before 13,
  /// `BUFFERS` without `ANALYZE` and `WAL` are dropped too, and `SETTINGS`
  /// before 12.
  String toSql(int serverVersionNum) {
    final v = serverVersionNum;
    final options = <String>[
      'FORMAT JSON',
      if (analyze) 'ANALYZE',
      if (buffers && (analyze || v >= 130000))
        'BUFFERS'
      else if (!buffers && analyze && v >= 180000)
        'BUFFERS OFF',
      if (verbose) 'VERBOSE',
      if (settings && v >= 120000) 'SETTINGS',
      if (wal && analyze && v >= 130000) 'WAL',
      if (serialize && analyze && v >= 170000) 'SERIALIZE',
      if (memory && v >= 170000) 'MEMORY',
      if (genericPlan && !analyze && v >= 160000) 'GENERIC_PLAN',
      if (!timing && analyze) 'TIMING OFF',
    ];
    return '(${options.join(', ')})';
  }

  /// A copy with the given fields replaced.
  ExplainOptions copyWith({
    bool? analyze,
    bool? buffers,
    bool? verbose,
    bool? settings,
    bool? wal,
    bool? serialize,
    bool? memory,
    bool? genericPlan,
    bool? timing,
  }) => ExplainOptions(
    analyze: analyze ?? this.analyze,
    buffers: buffers ?? this.buffers,
    verbose: verbose ?? this.verbose,
    settings: settings ?? this.settings,
    wal: wal ?? this.wal,
    serialize: serialize ?? this.serialize,
    memory: memory ?? this.memory,
    genericPlan: genericPlan ?? this.genericPlan,
    timing: timing ?? this.timing,
  );

  @override
  bool operator ==(Object other) =>
      other is ExplainOptions &&
      other.analyze == analyze &&
      other.buffers == buffers &&
      other.verbose == verbose &&
      other.settings == settings &&
      other.wal == wal &&
      other.serialize == serialize &&
      other.memory == memory &&
      other.genericPlan == genericPlan &&
      other.timing == timing;

  @override
  int get hashCode => Object.hash(
    analyze,
    buffers,
    verbose,
    settings,
    wal,
    serialize,
    memory,
    genericPlan,
    timing,
  );

  @override
  String toString() => 'ExplainOptions${toSql(999999)}';
}
