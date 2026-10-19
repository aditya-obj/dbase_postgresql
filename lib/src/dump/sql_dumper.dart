// File: sql_dumper.dart
// Purpose: Runs a plain-SQL dump over one connection, like pg_dump without
// parallelism: one REPEATABLE READ, READ ONLY transaction with pg_dump's
// settings, the bulk catalog read, ACCESS SHARE locks on every dumped
// table, then pre-data, table data read through a cursor in adaptive
// batches and re-encoded as COPY text, sequence values and post-data.
// The caller supplies the connection (DumpConnection) and the output
// (an async write callback); nothing here does I/O itself.
// Notes: COPY TO STDOUT is not used: the dabase driver can't carry it. The
// cursor reads the same snapshot and works behind a transaction pooler,
// since everything happens inside one transaction.

import 'package:dabase_postgresql/src/catalog/catalog_query.dart';
import 'package:dabase_postgresql/src/catalog/catalog_reader.dart';
import 'package:dabase_postgresql/src/catalog/schema_model.dart';
import 'package:dabase_postgresql/src/dump/copy_text.dart';
import 'package:dabase_postgresql/src/dump/dump_options.dart';
import 'package:dabase_postgresql/src/dump/dump_planner.dart';
import 'package:dabase_postgresql/src/dump/dump_writer.dart';
import 'package:dabase_postgresql/src/sql/sql_quoting.dart';

/// What a dump needs from a database connection.
abstract interface class DumpConnection {
  /// Runs one statement and returns all its rows as name-to-text maps.
  /// Must throw rather than return a cut result.
  Future<List<CatalogRow>> query(String sql, [List<String?> parameters]);

  /// Runs one `FETCH` and returns its rows as server text, in column
  /// order. Must never return a cut value: throw instead (a dump fails
  /// rather than corrupt data).
  ///
  /// When the connection keeps fewer rows than the server sent (a memory
  /// cap on the whole batch), return the rows kept, in order, with
  /// [FetchedRows.serverRows] set: the dump steps the cursor back over
  /// the rest and fetches them again in smaller batches.
  Future<FetchedRows> fetch(String sql);
}

/// The rows of one `FETCH`.
final class FetchedRows {
  /// Creates fetched rows.
  const FetchedRows(this.rows, {this.serverRows});

  /// The rows kept, in order, every value whole.
  final List<List<String?>> rows;

  /// How many rows the server sent, when more than [rows] (the rest were
  /// dropped by a memory cap); `null` when [rows] is everything.
  final int? serverRows;

  /// Whether rows were dropped.
  bool get isPartial => switch (serverRows) {
    final sent? => sent > rows.length,
    null => false,
  };
}

/// A single row is larger than the connection can hold in memory: the
/// dump can't include it without cutting it.
final class DumpRowTooLargeException implements Exception {
  /// Creates the exception for `schema.table`.
  const DumpRowTooLargeException(this.table);

  /// `schema.table`.
  final String table;

  @override
  String toString() => 'DumpRowTooLargeException($table)';
}

/// Thrown by [SqlDumper.run] when `isCancelled` said so between batches.
final class DumpCancelledException implements Exception {
  /// Creates the exception.
  const DumpCancelledException();

  @override
  String toString() => 'DumpCancelledException';
}

/// How many rows each `FETCH` asks for. The count adapts after every
/// batch so a batch holds about [targetBytes] of text.
final class DumpBatchSizing {
  /// Creates batch sizing.
  const DumpBatchSizing({
    this.startRows = 1000,
    this.minRows = 10,
    this.maxRows = 20000,
    this.targetBytes = 4 << 20,
  });

  /// Rows asked for first.
  final int startRows;

  /// Fewest rows asked for.
  final int minRows;

  /// Most rows asked for; the connection's row limit must allow it.
  final int maxRows;

  /// Text per batch aimed at.
  final int targetBytes;

  /// The next row count after a batch of [rows] rows and [bytes] of text.
  int next(int rows, int bytes) {
    if (rows <= 0 || bytes <= 0) return maxRows;
    final perRow = bytes / rows;
    return (targetBytes / perRow).floor().clamp(minRows, maxRows);
  }
}

/// Where a dump is.
enum DumpPhase {
  /// Opening the snapshot.
  starting,

  /// Reading the catalog.
  readingCatalog,

  /// Locking the tables.
  locking,

  /// Writing pre-data.
  schema,

  /// Writing table data.
  data,

  /// Writing sequence values and post-data, committing.
  finishing,
}

/// Progress of a running dump.
final class DumpProgress {
  /// Creates progress.
  const DumpProgress({
    required this.phase,
    this.tablesDone = 0,
    this.tablesTotal = 0,
    this.rows = 0,
    this.bytesWritten = 0,
    this.currentTable,
  });

  /// The current phase.
  final DumpPhase phase;

  /// Tables whose data is finished (or failed).
  final int tablesDone;

  /// Tables with data to write.
  final int tablesTotal;

  /// Rows written so far.
  final int rows;

  /// Characters handed to the write callback so far.
  final int bytesWritten;

  /// `schema.table` being read, if any.
  final String? currentTable;
}

/// Why a table's data was not exported.
enum DumpTableFailure {
  /// Row-level security applies to the exporting role and
  /// [DumpOptions.visibleRowsOnly] is off.
  rowSecurity,
}

/// State of one table's data.
enum DumpTableState {
  /// Not started.
  pending,

  /// Being read.
  running,

  /// Written.
  done,

  /// Not exported ([DumpTableStatus.failure] says why).
  failed,
}

/// One table's data status, reported as it changes.
final class DumpTableStatus {
  /// Creates a status.
  const DumpTableStatus({
    required this.oid,
    required this.schema,
    required this.name,
    required this.state,
    this.rows = 0,
    this.failure,
    this.visibleRowsOnly = false,
  });

  /// `pg_class.oid`.
  final int oid;

  /// Schema name.
  final String schema;

  /// Table name.
  final String name;

  /// Where it is.
  final DumpTableState state;

  /// Rows written so far.
  final int rows;

  /// Why it failed.
  final DumpTableFailure? failure;

  /// Exported with only the rows row-level security shows.
  final bool visibleRowsOnly;

  /// A copy with other values.
  DumpTableStatus copyWith({
    DumpTableState? state,
    int? rows,
    DumpTableFailure? failure,
  }) => DumpTableStatus(
    oid: oid,
    schema: schema,
    name: name,
    state: state ?? this.state,
    rows: rows ?? this.rows,
    failure: failure ?? this.failure,
    visibleRowsOnly: visibleRowsOnly,
  );
}

/// What a finished dump wrote.
final class DumpResult {
  /// Creates a result.
  const DumpResult({
    required this.serverVersion,
    required this.tables,
    required this.rows,
    required this.charactersWritten,
    this.warnings = const [],
    this.skipped = const SkippedObjects(),
    this.objects = 0,
  });

  /// The source server's `server_version`.
  final String serverVersion;

  /// Final status of every table with data.
  final List<DumpTableStatus> tables;

  /// Rows written.
  final int rows;

  /// Characters handed to the write callback.
  final int charactersWritten;

  /// Warnings (planner warnings plus the snapshot's).
  final List<DumpWarning> warnings;

  /// Objects not covered.
  final SkippedObjects skipped;

  /// Pre- and post-data items written.
  final int objects;

  /// Tables whose data is not in the file.
  List<DumpTableStatus> get failedTables => [
    for (final t in tables)
      if (t.state == DumpTableState.failed) t,
  ];
}

/// The statement opening a dump's snapshot.
const dumpBeginSql = 'BEGIN ISOLATION LEVEL REPEATABLE READ, READ ONLY';

/// pg_dump's settings, local to the dump's transaction: names
/// schema-qualified, stable text for dates, intervals, floats and bytea,
/// UTC, row security off (a read that RLS would filter fails instead),
/// a 5 s lock wait and a 2 minute bound per statement (each FETCH).
const dumpSettingsSql =
    "SELECT pg_catalog.set_config('search_path', '', true), "
    "pg_catalog.set_config('lock_timeout', '5000', true), "
    "pg_catalog.set_config('statement_timeout', '120000', true), "
    "pg_catalog.set_config('DateStyle', 'ISO', true), "
    "pg_catalog.set_config('IntervalStyle', 'postgres', true), "
    "pg_catalog.set_config('extra_float_digits', '3', true), "
    "pg_catalog.set_config('row_security', 'off', true), "
    "pg_catalog.set_config('bytea_output', 'hex', true), "
    "pg_catalog.set_config('TimeZone', 'UTC', true)";

/// Name of the cursor a dump reads table data through.
const dumpCursorName = 'dabase_dump';

/// `LOCK TABLE ... IN ACCESS SHARE MODE` statements covering [relations],
/// at most [perStatement] each.
List<String> lockTablesSql(
  List<ListedRelation> relations, {
  int perStatement = 100,
}) => [
  for (var i = 0; i < relations.length; i += perStatement)
    _lockStatement(relations.skip(i).take(perStatement)),
];

String _lockStatement(Iterable<ListedRelation> relations) {
  final names = [for (final r in relations) qualifiedName(r.schema, r.name)];
  return 'LOCK TABLE ${names.join(', ')} IN ACCESS SHARE MODE';
}

/// `DECLARE ... SCROLL CURSOR FOR SELECT <data columns> FROM ONLY t`.
///
/// SCROLL (a sequential scan supports it without materializing) lets a
/// batch cut short by a memory cap be fetched again with `MOVE BACKWARD`.
String declareDumpCursorSql(TableInfo table) {
  final columns = table.dataColumns.map(quoteIdent).join(', ');
  return 'DECLARE $dumpCursorName SCROLL CURSOR FOR '
      'SELECT $columns FROM ONLY ${qualifiedName(table.schema, table.name)}';
}

/// `MOVE BACKWARD n IN dabase_dump`.
String moveBackDumpCursorSql(int rows) =>
    'MOVE BACKWARD $rows IN $dumpCursorName';

/// `FETCH FORWARD n FROM dabase_dump`.
String fetchDumpCursorSql(int rows) =>
    'FETCH FORWARD $rows FROM $dumpCursorName';

/// Runs one dump.
final class SqlDumper {
  /// Creates a dumper writing through [write].
  SqlDumper({
    required this.connection,
    required this.options,
    required this.write,
    this.generator = 'dabase_postgresql',
    this.batch = const DumpBatchSizing(),
    this.onProgress,
    this.onTable,
    this.checkpoint,
    this.isCancelled,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Runs the dump's statements (one session, one transaction).
  final DumpConnection connection;

  /// Receives the dump text in order; awaited, so it can apply back
  /// pressure.
  final Future<void> Function(String chunk) write;
  final DateTime Function() _now;

  /// What to dump.
  final DumpOptions options;

  /// Written into the header (`Written by:`).
  final String generator;

  /// FETCH sizing.
  final DumpBatchSizing batch;

  /// Called on every phase change and after every batch.
  final void Function(DumpProgress progress)? onProgress;

  /// Called whenever a table's data status changes.
  final void Function(DumpTableStatus status)? onTable;

  /// Awaited before each table's data; may throw to stop the dump (low
  /// disk space, say). The transaction is rolled back and the error
  /// rethrown.
  final Future<void> Function()? checkpoint;

  /// Checked between batches; `true` stops the dump with
  /// [DumpCancelledException].
  final bool Function()? isCancelled;

  var _written = 0;
  var _rows = 0;
  var _tablesDone = 0;
  var _tablesTotal = 0;

  /// Runs the dump. On any error the transaction is rolled back (best
  /// effort) and the error rethrown; what was written so far is then an
  /// incomplete file the caller must discard.
  Future<DumpResult> run() async {
    _report(DumpPhase.starting);
    await connection.query(dumpBeginSql);
    try {
      final result = await _dump();
      await connection.query('COMMIT');
      return result;
    } on Object {
      try {
        await connection.query('ROLLBACK');
      } on Object {
        // The original error matters more; a dead connection rolls back
        // on the server by itself.
      }
      rethrow;
    }
  }

  Future<DumpResult> _dump() async {
    await connection.query(dumpSettingsSql);
    final query = connection.query;
    final facts = await CatalogReader.serverFacts(query);
    final reader = CatalogReader(query, serverVersionNum: facts.versionNum);
    _report(DumpPhase.readingCatalog);
    final listing = await reader.listRelations(options.scope);
    _report(DumpPhase.locking);
    for (final sql in lockTablesSql(listing.lockable)) {
      _cancelPoint();
      await connection.query(sql);
    }
    _report(DumpPhase.readingCatalog);
    final model = await reader.read(
      options.scope,
      listing,
      includeGrants: options.includeGrants,
      serverVersion: facts.version,
    );
    final plan = const DumpPlanner().plan(model, options);

    final statuses = {
      for (final t in plan.dataTables)
        t.oid: DumpTableStatus(
          oid: t.oid,
          schema: t.schema,
          name: t.name,
          state: t.rowSecurityActive && !options.visibleRowsOnly
              ? DumpTableState.failed
              : DumpTableState.pending,
          failure: t.rowSecurityActive && !options.visibleRowsOnly
              ? DumpTableFailure.rowSecurity
              : null,
          visibleRowsOnly: t.rowSecurityActive && options.visibleRowsOnly,
        ),
    };
    final visible = [
      for (final s in statuses.values)
        if (s.visibleRowsOnly) '${s.schema}.${s.name}',
    ];
    final warnings = [
      ...plan.warnings,
      if (visible.isNotEmpty)
        DumpWarning(DumpWarningCode.visibleRowsOnly, visible),
      if (facts.inRecovery) const DumpWarning(DumpWarningCode.hotStandby),
    ];
    if (onTable case final report?) statuses.values.forEach(report);
    _tablesTotal = plan.dataTables.length;

    const writer = DumpWriter();
    await _emit(
      writer.start(
        DumpHeader(
          generator: generator,
          serverVersion: facts.version,
          createdUtc: _now().toUtc(),
          content: options.content,
          includeGrants: options.includeGrants,
          visibleRowsOnly: visible.isNotEmpty,
          skipped: plan.skipped,
          warnings: warnings,
          tablesNotExported: [
            for (final s in statuses.values)
              if (s.state == DumpTableState.failed) '${s.schema}.${s.name}',
          ],
        ),
      ),
    );
    _report(DumpPhase.schema);
    for (final item in plan.preData) {
      await _emit(writer.item(item));
    }
    _report(DumpPhase.data);
    for (final table in plan.dataTables) {
      await checkpoint?.call();
      _cancelPoint();
      final status = statuses[table.oid]!;
      if (status.state == DumpTableState.failed) {
        await _emit(
          writer.dataNotExported(
            table,
            'row-level security applies to the exporting role',
          ),
        );
        _tablesDone++;
        _report(DumpPhase.data);
        continue;
      }
      statuses[table.oid] = await _tableData(table, status, writer);
      _tablesDone++;
    }
    _cancelPoint();
    _report(DumpPhase.finishing);
    for (final item in plan.sequenceValues) {
      await _emit(writer.item(item));
    }
    for (final item in plan.postData) {
      await _emit(writer.item(item));
    }
    await _emit(writer.end());
    return DumpResult(
      serverVersion: facts.version,
      tables: statuses.values.toList(),
      rows: _rows,
      charactersWritten: _written,
      warnings: warnings,
      skipped: plan.skipped,
      objects: plan.preData.length + plan.postData.length,
    );
  }

  Future<DumpTableStatus> _tableData(
    TableInfo table,
    DumpTableStatus status,
    DumpWriter writer,
  ) async {
    final label = '${table.schema}.${table.name}';
    var current = status.copyWith(state: DumpTableState.running);
    onTable?.call(current);
    _report(DumpPhase.data, currentTable: label);
    if (status.visibleRowsOnly) {
      await connection.query(
        "SELECT pg_catalog.set_config('row_security', 'on', true)",
      );
    }
    await connection.query(declareDumpCursorSql(table));
    await _emit(
      writer.copyStart(table, visibleRowsOnly: status.visibleRowsOnly),
    );
    var size = batch.startRows;
    var rows = 0;
    while (true) {
      _cancelPoint();
      final fetched = await connection.fetch(fetchDumpCursorSql(size));
      final batchRows = fetched.rows;
      if (fetched.isPartial) {
        // A memory cap dropped the end of the batch: step back over it.
        if (batchRows.isEmpty) throw DumpRowTooLargeException(label);
        final sent = fetched.serverRows ?? batchRows.length;
        await connection.query(moveBackDumpCursorSql(sent - batchRows.length));
      }
      if (batchRows.isEmpty) break;
      final text = StringBuffer();
      for (final row in batchRows) {
        text.write(encodeCopyTextRow(row));
      }
      final chunk = text.toString();
      await _emit(chunk);
      rows += batchRows.length;
      _rows += batchRows.length;
      current = current.copyWith(rows: rows);
      onTable?.call(current);
      _report(DumpPhase.data, currentTable: label);
      if (fetched.isPartial) {
        // Keep the next batch well under what fitted.
        size = (batchRows.length ~/ 2).clamp(1, batch.maxRows);
        continue;
      }
      if (batchRows.length < size) break;
      size = batch.next(batchRows.length, chunk.length);
    }
    await _emit(writer.copyEnd());
    await connection.query('CLOSE $dumpCursorName');
    if (status.visibleRowsOnly) {
      await connection.query(
        "SELECT pg_catalog.set_config('row_security', 'off', true)",
      );
    }
    current = current.copyWith(state: DumpTableState.done);
    onTable?.call(current);
    return current;
  }

  void _cancelPoint() {
    if (isCancelled?.call() ?? false) throw const DumpCancelledException();
  }

  Future<void> _emit(String text) async {
    _written += text.length;
    await write(text);
  }

  void _report(DumpPhase phase, {String? currentTable}) => onProgress?.call(
    DumpProgress(
      phase: phase,
      tablesDone: _tablesDone,
      tablesTotal: _tablesTotal,
      rows: _rows,
      bytesWritten: _written,
      currentTable: currentTable,
    ),
  );
}
